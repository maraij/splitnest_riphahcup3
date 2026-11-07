'use strict';

/**
 * SplitNest — Cloud Functions skeleton (PRACTICE app).
 *
 * NOT DEPLOYED. See functions/README.md for deploy instructions.
 *
 * What these do (all via the Admin SDK, which bypasses Firestore
 * rules — clients cannot write notifications or the activity log):
 *  - onInvitationCreated: log the invite in the group's activity feed.
 *  - onExpenseCreated: validate the integer-paisa splits sum, log the
 *    expense in the activity feed, notify every OTHER group member.
 *  - onPaymentCreated: log the payment, notify the recipient.
 *  - onPaymentVerified: log the verification, notify the sender.
 *  - monthlySummary (scheduled): on the 1st of each month, total the
 *    previous month's spending per group and notify every member.
 *
 * Scheduled functions REQUIRE the Blaze (pay-as-you-go) plan.
 * onCreate/onUpdate triggers work on the free Spark plan.
 * This project (splitnest-b8071) is on Spark — do not enable the
 * scheduled function until the plan question is decided.
 */

const { initializeApp } = require('firebase-admin/app');
const { getFirestore, FieldValue } = require('firebase-admin/firestore');
const { onDocumentCreated, onDocumentUpdated } = require(
  'firebase-functions/v2/firestore');
const { onSchedule } = require('firebase-functions/v2/scheduler');

initializeApp();
const db = getFirestore();

// Asia/Karachi, matching the household's timezone.
const REGION = 'asia-south1';

/** Read the members map of a group doc: {uid: {role, joinedAt}}. */
async function groupMembers(groupId) {
  const snap = await db.doc(`groups/${groupId}`).get();
  if (!snap.exists) return {};
  return snap.data().members || {};
}

/** Display name for a uid, falling back to the uid itself. */
async function displayName(uid) {
  const snap = await db.doc(`users/${uid}`).get();
  if (snap.exists && snap.data().displayName) {
    return snap.data().displayName;
  }
  return uid;
}

/** Append one line to a group's activity feed (Functions-only). */
async function logActivity(groupId, entry) {
  await db.collection(`groups/${groupId}/activity`).add({
    ...entry,
    createdAt: FieldValue.serverTimestamp(),
  });
}

/** Drop one notification into a user's inbox (Functions-only). */
async function notifyUser(uid, notification) {
  await db.collection(`users/${uid}/notifications`).add({
    ...notification,
    read: false,
    createdAt: FieldValue.serverTimestamp(),
  });
}

/** Format integer paisa as PKR, e.g. 78000 -> "PKR 780.00". */
function formatPkr(paisa) {
  const sign = paisa < 0 ? '-' : '';
  const abs = Math.abs(paisa);
  return `PKR ${sign}${Math.floor(abs / 100)}.${String(abs % 100).padStart(2, '0')}`;
}

// ---------------------------------------------------------------------------
// Invitations
// ---------------------------------------------------------------------------

/**
 * A new invitation was created: log it in the group's activity feed.
 * No notification is sent to the invitee here — they may not have a
 * Firebase Auth account (and therefore no users/{uid} doc) yet. The
 * invite email is sent by the client flow / a later phase; when the
 * invitee accepts, onInvitationAccepted (below) adds them to the
 * group and notifies the inviter.
 */
exports.onInvitationCreated = onDocumentCreated(
  { document: 'invitations/{invitationId}', region: REGION },
  async (event) => {
    const invite = event.data.data();
    const inviterName = await displayName(invite.invitedBy);
    await logActivity(invite.groupId, {
      type: 'invite_sent',
      actorUid: invite.invitedBy,
      actorName: inviterName,
      summary: `${inviterName} invited ${invite.invitedEmail} to ${invite.groupName || 'the group'}`,
      refId: event.params.invitationId,
    });
  },
);

/**
 * An invitation was accepted: add the invitee to the group (members
 * map on the group doc AND the queryable members subcollection) and
 * notify the inviter. The invitee's uid is stored on the invitation
 * doc by the client accept flow as `acceptedBy` before flipping the
 * status — the Function only trusts the status change event.
 */
exports.onInvitationAccepted = onDocumentUpdated(
  { document: 'invitations/{invitationId}', region: REGION },
  async (event) => {
    const before = event.data.before.data();
    const after = event.data.after.data();
    if (before.status === after.status || after.status !== 'accepted') {
      return; // Not an accept transition.
    }
    const uid = after.acceptedBy;
    if (!uid) return; // Client must set acceptedBy when accepting.
    const groupRef = db.doc(`groups/${after.groupId}`);
    const memberSnap = await db.doc(`users/${uid}`).get();
    const profile = memberSnap.exists ? memberSnap.data() : {};
    await groupRef.update({
      [`members.${uid}`]: {
        role: after.role || 'member',
        joinedAt: FieldValue.serverTimestamp(),
      },
    });
    await groupRef.collection('members').doc(uid).set({
      displayName: profile.displayName || after.invitedEmail,
      photoUrl: profile.photoUrl || null,
      role: after.role || 'member',
      joinedAt: FieldValue.serverTimestamp(),
    });
    await logActivity(after.groupId, {
      type: 'member_joined',
      actorUid: uid,
      actorName: profile.displayName || after.invitedEmail,
      summary: `${profile.displayName || after.invitedEmail} joined the group`,
      refId: event.params.invitationId,
    });
    await notifyUser(after.invitedBy, {
      type: 'invitation',
      groupId: after.groupId,
      title: 'Invite accepted',
      body: `${profile.displayName || after.invitedEmail} joined ${after.groupName || 'your group'}.`,
      data: { invitationId: event.params.invitationId },
    });
  },
);

// ---------------------------------------------------------------------------
// Expenses
// ---------------------------------------------------------------------------

/**
 * A new expense was recorded: validate the integer-paisa invariant,
 * log it, and notify every OTHER group member.
 *
 * The splits-sum invariant (sum(splits) == amountPaisa) cannot be
 * enforced by Firestore rules (no map summation in the rules
 * language), so this Function is the enforcement point: a mismatch
 * is logged to the activity feed as a warning and the expense is
 * left in place (never silently deleted — a human fixes it).
 */
exports.onExpenseCreated = onDocumentCreated(
  { document: 'groups/{groupId}/expenses/{expenseId}', region: REGION },
  async (event) => {
    const { groupId, expenseId } = event.params;
    const expense = event.data.data();
    const payerName = await displayName(expense.paidBy);

    const splitSum = Object.values(expense.splits || {})
      .reduce((sum, v) => sum + (typeof v === 'number' ? v : 0), 0);
    if (splitSum !== expense.amountPaisa) {
      await logActivity(groupId, {
        type: 'expense_added',
        actorUid: expense.createdBy,
        actorName: payerName,
        summary: `WARNING: expense "${expense.title}" splits sum to ${formatPkr(splitSum)} but amount is ${formatPkr(expense.amountPaisa)} — needs a fix`,
        amountPaisa: expense.amountPaisa,
        refId: expenseId,
      });
      return;
    }

    await logActivity(groupId, {
      type: 'expense_added',
      actorUid: expense.createdBy,
      actorName: payerName,
      summary: `${payerName} added ${expense.title} — ${formatPkr(expense.amountPaisa)}`,
      amountPaisa: expense.amountPaisa,
      refId: expenseId,
    });

    const members = await groupMembers(groupId);
    for (const uid of Object.keys(members)) {
      if (uid === expense.createdBy) continue;
      await notifyUser(uid, {
        type: 'expense_added',
        groupId,
        title: `New expense: ${expense.title}`,
        body: `${payerName} added ${expense.title} — ${formatPkr(expense.amountPaisa)}.`,
        data: { expenseId, actorUid: expense.createdBy },
      });
    }
  },
);

/**
 * An expense was deleted (owner/admin only, per rules): log it so
 * the Timeline shows the removal. Firestore has no onDocumentDeleted
 * export wired here yet — add it the same way if deletion audit
 * entries are wanted; the delete itself is already restricted by
 * rules to owner/admin.
 */

// ---------------------------------------------------------------------------
// Payments (settlements)
// ---------------------------------------------------------------------------

/** A payment was recorded: log it and notify the recipient. */
exports.onPaymentCreated = onDocumentCreated(
  { document: 'groups/{groupId}/payments/{paymentId}', region: REGION },
  async (event) => {
    const { groupId, paymentId } = event.params;
    const payment = event.data.data();
    const senderName = await displayName(payment.fromUid);
    const recipientName = await displayName(payment.toUid);
    await logActivity(groupId, {
      type: 'payment_recorded',
      actorUid: payment.fromUid,
      actorName: senderName,
      summary: `${senderName} recorded a payment of ${formatPkr(payment.amountPaisa)} to ${recipientName} (awaiting verification)`,
      amountPaisa: payment.amountPaisa,
      refId: paymentId,
    });
    await notifyUser(payment.toUid, {
      type: 'payment_recorded',
      groupId,
      title: 'Payment recorded',
      body: `${senderName} recorded a payment of ${formatPkr(payment.amountPaisa)} to you. An admin will verify it.`,
      data: { paymentId, actorUid: payment.fromUid },
    });
  },
);

/** A payment moved recorded -> verified: log it, notify the sender. */
exports.onPaymentVerified = onDocumentUpdated(
  { document: 'groups/{groupId}/payments/{paymentId}', region: REGION },
  async (event) => {
    const { groupId, paymentId } = event.params;
    const before = event.data.before.data();
    const after = event.data.after.data();
    if (before.status === after.status || after.status !== 'verified') {
      return; // Not a verification transition.
    }
    const verifierName = await displayName(after.verifiedBy);
    const senderName = await displayName(after.fromUid);
    await logActivity(groupId, {
      type: 'payment_verified',
      actorUid: after.verifiedBy,
      actorName: verifierName,
      summary: `${verifierName} verified ${senderName}'s payment of ${formatPkr(after.amountPaisa)}`,
      amountPaisa: after.amountPaisa,
      refId: paymentId,
    });
    await notifyUser(after.fromUid, {
      type: 'payment_verified',
      groupId,
      title: 'Payment verified',
      body: `${verifierName} verified your payment of ${formatPkr(after.amountPaisa)}.`,
      data: { paymentId, actorUid: after.verifiedBy },
    });
  },
);

// ---------------------------------------------------------------------------
// Scheduled: monthly summary + reminders
// ---------------------------------------------------------------------------

/**
 * Monthly summary — runs 09:00 Asia/Karachi on the 1st of each month.
 * Totals the PREVIOUS month's expenses per group and notifies every
 * member with the total and their own share.
 *
 * REQUIRES THE BLAZE PLAN: scheduled functions do not run on Spark.
 * Deploy this function only after upgrading the project to Blaze
 * (Firebase console → Upgrade). The onCreate/onUpdate triggers above
 * work on Spark and can be deployed without it.
 */
exports.monthlySummary = onSchedule(
  { schedule: '0 9 1 * *', timeZone: 'Asia/Karachi', region: REGION },
  async () => {
    const now = new Date();
    const firstOfThisMonth = new Date(
      Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1));
    const firstOfLastMonth = new Date(Date.UTC(
      now.getUTCFullYear(), now.getUTCMonth() - 1, 1));
    const monthLabel = firstOfLastMonth.toLocaleString('en-GB', {
      month: 'long', year: 'numeric', timeZone: 'Asia/Karachi',
    });

    const groups = await db.collection('groups').get();
    for (const groupDoc of groups.docs) {
      const groupId = groupDoc.id;
      const expenses = await db
        .collection(`groups/${groupId}/expenses`)
        .where('expenseDate', '>=', firstOfLastMonth)
        .where('expenseDate', '<', firstOfThisMonth)
        .get();
      let total = 0;
      const shareByUid = {};
      for (const doc of expenses.docs) {
        const e = doc.data();
        total += e.amountPaisa || 0;
        for (const [uid, share] of Object.entries(e.splits || {})) {
          shareByUid[uid] = (shareByUid[uid] || 0) + share;
        }
      }
      const members = groupDoc.data().members || {};
      for (const uid of Object.keys(members)) {
        const share = shareByUid[uid] || 0;
        await notifyUser(uid, {
          type: 'monthly_summary',
          groupId,
          title: `Monthly summary — ${monthLabel}`,
          body: `Total spending ${formatPkr(total)}. Your share: ${formatPkr(share)}.`,
          data: { month: monthLabel },
        });
      }
      await logActivity(groupId, {
        type: 'monthly_summary',
        actorUid: 'system',
        actorName: 'SplitNest',
        summary: `Monthly summary for ${monthLabel}: total ${formatPkr(total)}`,
        amountPaisa: total,
      });
    }
  },
);
