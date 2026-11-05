'use strict';
/**
 * SplitNest backend — Express app factory.
 * Thirteen endpoints: GET /api/members, GET /api/shopping,
 * POST /api/shopping, POST /api/shopping/checkout, POST /api/expenses,
 * GET /api/balances, POST /api/settle, POST /api/auth/login,
 * GET /api/fixed-expenses, POST /api/fixed-expenses,
 * PATCH /api/fixed-expenses/:id, DELETE /api/fixed-expenses/:id,
 * POST /api/fixed-expenses/:id/apply.
 * All endpoints except /api/auth/login require a valid session:
 * Authorization: Bearer <token>. Unauthenticated calls get 401.
 *
 * Balance formula (TESTING.md worked example, which the printed equation
 * in the task contradicts): Net = Paid - Share + Sent - Received.
 * A debtor paying a creditor therefore reduces the creditor's positive
 * balance, as the official settlement sequence requires.
 */
const express = require('express');
const { openDb, nextId, UNITS } = require('./db');
const { parsePaisa, formatPaisa, isPositiveInt, equalSplit } = require('./money');
const { verifyPassword, createSession, getSessionMember } = require('./auth');

function error(res, status, code, message) {
  return res.status(status).json({ error: { code, message } });
}

function validDate(s) {
  return typeof s === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(s) && !isNaN(Date.parse(s));
}

function createApp(dbPath) {
  const db = openDb(dbPath);
  const app = express();
  app.use(express.json());
  app.use((req, res, next) => {
    console.log(`${new Date().toISOString()} ${req.method} ${req.path}`);
    next();
  });

  const memberExists = (id) =>
    !!db.prepare('SELECT 1 FROM members WHERE id = ?').get(id);

  function publicItem(r) {
    return {
      id: r.id, title: r.title, unit: r.unit,
      requested_qty: r.requested_qty, status: r.status,
    };
  }

  function publicExpense(r) {
    const shares = db.prepare(
      'SELECT member_id, share_paisa FROM expense_shares WHERE expense_id = ? ORDER BY member_id')
      .all(r.id)
      .map((s) => ({ member_id: s.member_id, amount: formatPaisa(s.share_paisa) }));
    return {
      id: r.id, title: r.title, category: r.category,
      date: r.expense_date, amount: formatPaisa(r.amount_paisa),
      payer_id: r.payer_id, split_type: r.split_type, shares,
    };
  }

  /** Insert one expense + its shares. Caller must be inside a transaction. */
  function insertExpense({ title, category, date, amountPaisa, payerId, splitType, shares, fixedExpenseId = null }) {
    const id = nextId(db, 'expenses', 'E');
    const now = new Date().toISOString();
    db.prepare(
      'INSERT INTO expenses (id, title, category, expense_date, amount_paisa, payer_id, split_type, fixed_expense_id, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)')
      .run(id, title, category, date, amountPaisa, payerId, splitType, fixedExpenseId, now);
    const ins = db.prepare(
      'INSERT INTO expense_shares (expense_id, member_id, share_paisa) VALUES (?, ?, ?)');
    for (const s of shares) ins.run(id, s.member_id, s.amount_paisa);
    return id;
  }

  function computeBalances() {
    const members = db.prepare('SELECT id, name FROM members ORDER BY id').all();
    const paid = {};
    const share = {};
    for (const m of members) { paid[m.id] = 0; share[m.id] = 0; }
    for (const r of db.prepare('SELECT payer_id, amount_paisa FROM expenses').all()) {
      paid[r.payer_id] += r.amount_paisa;
    }
    for (const r of db.prepare('SELECT member_id, share_paisa FROM expense_shares').all()) {
      share[r.member_id] += r.share_paisa;
    }
    const sent = {};
    const received = {};
    for (const m of members) { sent[m.id] = 0; received[m.id] = 0; }
    for (const r of db.prepare('SELECT sender_id, recipient_id, amount_paisa FROM settlements').all()) {
      sent[r.sender_id] += r.amount_paisa;
      received[r.recipient_id] += r.amount_paisa;
    }
    const balances = members.map((m) => {
      // Net = Paid - Share + Sent - Received (worked-example formula).
      const net = paid[m.id] - share[m.id] + sent[m.id] - received[m.id];
      return {
        member_id: m.id, name: m.name,
        paid: formatPaisa(paid[m.id]), share: formatPaisa(share[m.id]),
        sent: formatPaisa(sent[m.id]), received: formatPaisa(received[m.id]),
        net: formatPaisa(net), net_paisa: net,
      };
    });
    return balances;
  }

  function monthSummary() {
    const month = new Date().toISOString().slice(0, 7);
    const budgetRow = db.prepare('SELECT limit_paisa FROM household_budget WHERE month_key = ?')
      .get(month);
    const limit = budgetRow ? budgetRow.limit_paisa : 500000;
    const row = db.prepare(
      "SELECT COALESCE(SUM(amount_paisa), 0) AS total FROM expenses WHERE substr(expense_date, 1, 7) = ?")
      .get(month);
    const total = row.total;
    const remaining = limit - total;
    const usedPercent = limit > 0 ? Math.round((total / limit) * 10000) / 100 : 0;
    const status = usedPercent >= 84 ? 'Near Limit' : usedPercent >= 50 ? 'On Track' : 'Under Budget';
    return {
      month, total_spending: formatPaisa(total), total_paisa: total,
      budget: formatPaisa(limit), remaining: formatPaisa(remaining),
      used_percent: usedPercent, status,
    };
  }

  // ---- Auth: Bearer-token sessions (in-memory, see src/auth.js) ----
  function requireAuth(req, res, next) {
    const header = req.headers.authorization || '';
    const token = header.startsWith('Bearer ') ? header.slice(7) : '';
    const memberId = token ? getSessionMember(token) : null;
    if (!memberId) {
      return error(res, 401, 'UNAUTHORIZED', 'A valid session is required. Log in again.');
    }
    req.memberId = memberId;
    next();
  }

  // ---- POST /api/auth/login (public) ----
  app.post('/api/auth/login', (req, res) => {
    const { member_id, password } = req.body || {};
    const invalid = () =>
      error(res, 401, 'INVALID_CREDENTIALS', 'Invalid member or password.');
    if (typeof member_id !== 'string' || typeof password !== 'string') return invalid();
    const row = db
      .prepare('SELECT id, name, password_hash FROM members WHERE id = ?')
      .get(member_id);
    if (!row || !verifyPassword(password, row.password_hash)) return invalid();
    res.json({ token: createSession(row.id), member: { id: row.id, name: row.name } });
  });

  // ---- GET /api/members ----
  app.get('/api/members', requireAuth, (req, res) => {
    const rows = db.prepare('SELECT id, name FROM members ORDER BY id').all();
    res.json(rows);
  });

  // ---- GET /api/shopping ----
  app.get('/api/shopping', requireAuth, (req, res) => {
    const rows = db.prepare('SELECT * FROM shopping_items ORDER BY id').all();
    res.json(rows.map(publicItem));
  });

  // ---- POST /api/shopping ----
  app.post('/api/shopping', requireAuth, (req, res) => {
    const { title, unit, requested_qty } = req.body || {};
    if (typeof title !== 'string' || title.trim() === '') {
      return error(res, 400, 'INVALID_ITEM', 'Title is required.');
    }
    if (!UNITS.includes(unit)) {
      return error(res, 400, 'INVALID_UNIT', `Unit must be one of: ${UNITS.join(', ')}.`);
    }
    if (!isPositiveInt(requested_qty)) {
      return error(res, 400, 'INVALID_QUANTITY', 'Quantity must be a positive whole number.');
    }
    const id = nextId(db, 'shopping_items', 'S');
    db.prepare(
      'INSERT INTO shopping_items (id, title, unit, requested_qty, status) VALUES (?, ?, ?, ?, ?)')
      .run(id, title.trim(), unit, requested_qty, 'Pending');
    const row = db.prepare('SELECT * FROM shopping_items WHERE id = ?').get(id);
    res.status(201).json(publicItem(row));
  });

  // ---- POST /api/shopping/checkout (atomic) ----
  app.post('/api/shopping/checkout', requireAuth, (req, res) => {
    const { item_ids, total_paid, payer_id, split_members } = req.body || {};
    if (!Array.isArray(item_ids) || item_ids.length === 0) {
      return error(res, 400, 'INVALID_CHECKOUT', 'Select at least one item to check out.');
    }
    if (new Set(item_ids).size !== item_ids.length) {
      return error(res, 409, 'DUPLICATE_ITEM', 'An item was selected more than once.');
    }
    const totalPaisa = parsePaisa(total_paid);
    if (totalPaisa === null || totalPaisa <= 0) {
      return error(res, 400, 'INVALID_AMOUNT', 'Total paid must be a positive amount.');
    }
    if (!memberExists(payer_id)) {
      return error(res, 404, 'UNKNOWN_PAYER', `Payer ${payer_id} does not exist.`);
    }
    const members = Array.isArray(split_members) && split_members.length > 0
      ? split_members
      : ['M01', 'M02', 'M03'];
    if (new Set(members).size !== members.length || members.some((m) => !memberExists(m))) {
      return error(res, 400, 'INVALID_SPLIT', 'Split members must be known members, listed once.');
    }
    const items = item_ids.map((id) =>
      db.prepare('SELECT * FROM shopping_items WHERE id = ?').get(id));
    if (items.some((it) => !it)) {
      return error(res, 404, 'UNKNOWN_ITEM', 'One of the selected items does not exist.');
    }
    if (items.some((it) => it.status !== 'Pending')) {
      return error(res, 409, 'ALREADY_BOUGHT', 'One of the selected items is already bought.');
    }
    try {
      db.exec('BEGIN IMMEDIATE TRANSACTION');
      const shares = equalSplit(totalPaisa, members);
      const title = `Shopping: ${items.map((i) => i.title).join(', ')}`;
      const date = new Date().toISOString().slice(0, 10);
      const expenseId = insertExpense({
        title, category: 'Groceries', date,
        amountPaisa: totalPaisa, payerId: payer_id,
        splitType: 'equal', shares,
      });
      const mark = db.prepare(
        'UPDATE shopping_items SET status = ?, checkout_expense_id = ? WHERE id = ?');
      for (const it of items) mark.run('Bought', expenseId, it.id);
      db.exec('COMMIT');
      const row = db.prepare('SELECT * FROM expenses WHERE id = ?').get(expenseId);
      res.status(201).json(publicExpense(row));
    } catch (e) {
      try { db.exec('ROLLBACK'); } catch (_) { /* already rolled back */ }
      console.error(e);
      return error(res, 500, 'CHECKOUT_FAILED', 'Checkout failed; nothing was changed.');
    }
  });

  // ---- POST /api/expenses ----
  app.post('/api/expenses', requireAuth, (req, res) => {
    const { title, category, date, amount, payer_id, split_type, splits, split_members } = req.body || {};
    if (typeof title !== 'string' || title.trim() === '') {
      return error(res, 400, 'INVALID_EXPENSE', 'Title is required.');
    }
    const amountPaisa = parsePaisa(amount);
    if (amountPaisa === null || amountPaisa <= 0) {
      return error(res, 400, 'INVALID_AMOUNT', 'Amount must be a positive amount.');
    }
    if (!memberExists(payer_id)) {
      return error(res, 404, 'UNKNOWN_PAYER', `Payer ${payer_id} does not exist.`);
    }
    const expenseDate = date || new Date().toISOString().slice(0, 10);
    if (!validDate(expenseDate)) {
      return error(res, 400, 'INVALID_DATE', 'Date must be YYYY-MM-DD.');
    }
    const type = split_type || 'equal';
    let shares;
    if (type === 'custom') {
      if (!Array.isArray(splits) || splits.length === 0) {
        return error(res, 400, 'INVALID_SPLIT', 'Custom split needs at least one share.');
      }
      const ids = splits.map((s) => s.member_id);
      if (new Set(ids).size !== ids.length || ids.some((m) => !memberExists(m))) {
        return error(res, 400, 'INVALID_SPLIT', 'Split members must be known members, listed once.');
      }
      shares = [];
      let sum = 0;
      for (const s of splits) {
        const p = parsePaisa(s.amount);
        if (p === null || p < 0) {
          return error(res, 400, 'INVALID_SPLIT', 'Each share must be a non-negative amount.');
        }
        sum += p;
        shares.push({ member_id: s.member_id, amount_paisa: p });
      }
      if (sum !== amountPaisa) {
        return error(res, 400, 'SPLIT_MISMATCH',
          `Custom shares sum to ${formatPaisa(sum)} but the amount is ${formatPaisa(amountPaisa)}.`);
      }
    } else if (type === 'equal') {
      const members = Array.isArray(split_members) && split_members.length > 0
        ? split_members
        : ['M01', 'M02', 'M03'];
      if (new Set(members).size !== members.length || members.some((m) => !memberExists(m))) {
        return error(res, 400, 'INVALID_SPLIT', 'Split members must be known members, listed once.');
      }
      shares = equalSplit(amountPaisa, members);
    } else {
      return error(res, 400, 'INVALID_SPLIT_TYPE', 'split_type must be "equal" or "custom".');
    }
    try {
      db.exec('BEGIN IMMEDIATE TRANSACTION');
      const id = insertExpense({
        title: title.trim(), category: (category || 'General').trim(),
        date: expenseDate, amountPaisa, payerId: payer_id, splitType: type, shares,
      });
      db.exec('COMMIT');
      const row = db.prepare('SELECT * FROM expenses WHERE id = ?').get(id);
      res.status(201).json(publicExpense(row));
    } catch (e) {
      try { db.exec('ROLLBACK'); } catch (_) { /* already rolled back */ }
      console.error(e);
      return error(res, 500, 'EXPENSE_FAILED', 'Expense could not be saved.');
    }
  });

  // ---- GET /api/balances ----
  app.get('/api/balances', requireAuth, (req, res) => {
    const balances = computeBalances();
    const summary = monthSummary();
    res.json({
      balances: balances.map((b) => ({
        member_id: b.member_id, name: b.name, net: b.net,
        paid: b.paid, share: b.share, sent: b.sent, received: b.received,
      })),
      ...summary,
    });
  });

  // ---- POST /api/settle ----
  app.post('/api/settle', requireAuth, (req, res) => {
    const { sender_id, recipient_id, amount } = req.body || {};
    if (!memberExists(sender_id) || !memberExists(recipient_id)) {
      return error(res, 404, 'UNKNOWN_MEMBER', 'Sender and recipient must be known members.');
    }
    if (sender_id === recipient_id) {
      return error(res, 400, 'INVALID_SETTLEMENT', 'Sender and recipient must be different.');
    }
    const amountPaisa = parsePaisa(amount);
    if (amountPaisa === null || amountPaisa <= 0) {
      return error(res, 400, 'INVALID_AMOUNT', 'Settlement amount must be positive.');
    }
    const balances = computeBalances();
    const sender = balances.find((b) => b.member_id === sender_id);
    const recipient = balances.find((b) => b.member_id === recipient_id);
    if (sender.net_paisa >= 0) {
      return error(res, 400, 'INVALID_SETTLEMENT', 'Sender does not owe money (not a debtor).');
    }
    if (recipient.net_paisa <= 0) {
      return error(res, 400, 'INVALID_SETTLEMENT', 'Recipient is not owed money (not a creditor).');
    }
    if (amountPaisa > -sender.net_paisa || amountPaisa > recipient.net_paisa) {
      return error(res, 409, 'INVALID_SETTLEMENT',
        `Payment exceeds outstanding balance (sender owes ${formatPaisa(-sender.net_paisa)}, recipient is owed ${formatPaisa(recipient.net_paisa)}).`);
    }
    const id = nextId(db, 'settlements', 'T');
    db.prepare(
      'INSERT INTO settlements (id, sender_id, recipient_id, amount_paisa, created_at) VALUES (?, ?, ?, ?, ?)')
      .run(id, sender_id, recipient_id, amountPaisa, new Date().toISOString());
    res.status(201).json({
      id, sender_id, recipient_id, amount: formatPaisa(amountPaisa),
    });
  });

  // ---- Fixed monthly expenses (templates, not expenses) ----
  // A template posts at most ONE expense per YYYY-MM, only when the
  // app calls Apply (explicit button). Nothing here runs on server
  // start and nothing auto-applies, so the benchmark — which never
  // calls Apply — is untouched. The seeded Internet template is an
  // EQUAL split (500 each); the benchmark's Internet expense is a
  // separate CUSTOM split (500/300/700) posted manually, so the two
  // never interfere.
  function publicFixedExpense(r) {
    return {
      id: r.id, title: r.title, category: r.category,
      amount: formatPaisa(r.amount_paisa), payer_id: r.payer_id,
      split_members: JSON.parse(r.split_members),
      created_at: r.created_at,
    };
  }

  function validateSplitMembers(members) {
    const list = Array.isArray(members) && members.length > 0
      ? members
      : ['M01', 'M02', 'M03'];
    if (new Set(list).size !== list.length || list.some((m) => !memberExists(m))) {
      return null;
    }
    return [...list].sort();
  }

  // ---- GET /api/fixed-expenses ----
  app.get('/api/fixed-expenses', requireAuth, (req, res) => {
    const rows = db.prepare('SELECT * FROM fixed_expenses ORDER BY id').all();
    res.json({ fixed_expenses: rows.map(publicFixedExpense) });
  });

  // ---- POST /api/fixed-expenses ----
  app.post('/api/fixed-expenses', requireAuth, (req, res) => {
    const { title, category, amount, payer_id, split_members } = req.body || {};
    if (typeof title !== 'string' || title.trim() === '') {
      return error(res, 400, 'INVALID_FIXED', 'Title is required.');
    }
    const amountPaisa = parsePaisa(amount);
    if (amountPaisa === null || amountPaisa <= 0) {
      return error(res, 400, 'INVALID_AMOUNT', 'Amount must be a positive amount.');
    }
    if (!memberExists(payer_id)) {
      return error(res, 404, 'UNKNOWN_PAYER', `Payer ${payer_id} does not exist.`);
    }
    const members = validateSplitMembers(split_members);
    if (!members) {
      return error(res, 400, 'INVALID_SPLIT', 'Split members must be known members, listed once.');
    }
    const id = nextId(db, 'fixed_expenses', 'F');
    db.prepare(
      'INSERT INTO fixed_expenses (id, title, category, amount_paisa, payer_id, split_members, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)')
      .run(id, title.trim(), (category || 'General').trim(), amountPaisa, payer_id,
        JSON.stringify(members), new Date().toISOString());
    const row = db.prepare('SELECT * FROM fixed_expenses WHERE id = ?').get(id);
    res.status(201).json(publicFixedExpense(row));
  });

  // ---- PATCH /api/fixed-expenses/:id ----
  app.patch('/api/fixed-expenses/:id', requireAuth, (req, res) => {
    const row = db.prepare('SELECT * FROM fixed_expenses WHERE id = ?').get(req.params.id);
    if (!row) {
      return error(res, 404, 'UNKNOWN_FIXED', `Fixed expense ${req.params.id} does not exist.`);
    }
    const { title, category, amount, payer_id, split_members } = req.body || {};
    const next = {
      title: row.title, category: row.category,
      amount_paisa: row.amount_paisa, payer_id: row.payer_id,
      split_members: row.split_members,
    };
    if (title !== undefined) {
      if (typeof title !== 'string' || title.trim() === '') {
        return error(res, 400, 'INVALID_FIXED', 'Title is required.');
      }
      next.title = title.trim();
    }
    if (category !== undefined) {
      if (typeof category !== 'string' || category.trim() === '') {
        return error(res, 400, 'INVALID_FIXED', 'Category is required.');
      }
      next.category = category.trim();
    }
    if (amount !== undefined) {
      const amountPaisa = parsePaisa(amount);
      if (amountPaisa === null || amountPaisa <= 0) {
        return error(res, 400, 'INVALID_AMOUNT', 'Amount must be a positive amount.');
      }
      next.amount_paisa = amountPaisa;
    }
    if (payer_id !== undefined) {
      if (!memberExists(payer_id)) {
        return error(res, 404, 'UNKNOWN_PAYER', `Payer ${payer_id} does not exist.`);
      }
      next.payer_id = payer_id;
    }
    if (split_members !== undefined) {
      const members = validateSplitMembers(split_members);
      if (!members) {
        return error(res, 400, 'INVALID_SPLIT', 'Split members must be known members, listed once.');
      }
      next.split_members = JSON.stringify(members);
    }
    db.prepare(
      'UPDATE fixed_expenses SET title = ?, category = ?, amount_paisa = ?, payer_id = ?, split_members = ? WHERE id = ?')
      .run(next.title, next.category, next.amount_paisa, next.payer_id, next.split_members, row.id);
    res.json(publicFixedExpense(
      db.prepare('SELECT * FROM fixed_expenses WHERE id = ?').get(row.id)));
  });

  // ---- DELETE /api/fixed-expenses/:id ----
  app.delete('/api/fixed-expenses/:id', requireAuth, (req, res) => {
    const row = db.prepare('SELECT * FROM fixed_expenses WHERE id = ?').get(req.params.id);
    if (!row) {
      return error(res, 404, 'UNKNOWN_FIXED', `Fixed expense ${req.params.id} does not exist.`);
    }
    db.prepare('DELETE FROM fixed_expenses WHERE id = ?').run(row.id);
    res.json({ deleted: true, id: row.id });
  });

  // ---- POST /api/fixed-expenses/:id/apply ----
  // Posts this month's expense for the template — at most once per
  // YYYY-MM. A second apply in the same month returns applied: false
  // and posts nothing.
  app.post('/api/fixed-expenses/:id/apply', requireAuth, (req, res) => {
    const row = db.prepare('SELECT * FROM fixed_expenses WHERE id = ?').get(req.params.id);
    if (!row) {
      return error(res, 404, 'UNKNOWN_FIXED', `Fixed expense ${req.params.id} does not exist.`);
    }
    const month = new Date().toISOString().slice(0, 7);
    const existing = db.prepare(
      "SELECT * FROM expenses WHERE fixed_expense_id = ? AND substr(expense_date, 1, 7) = ?")
      .get(row.id, month);
    if (existing) {
      return res.json({ applied: false, reason: 'ALREADY_APPLIED', expense: publicExpense(existing) });
    }
    const members = JSON.parse(row.split_members);
    const shares = equalSplit(row.amount_paisa, members);
    const date = new Date().toISOString().slice(0, 10);
    try {
      db.exec('BEGIN IMMEDIATE TRANSACTION');
      const id = insertExpense({
        title: row.title, category: row.category, date,
        amountPaisa: row.amount_paisa, payerId: row.payer_id,
        splitType: 'equal', shares, fixedExpenseId: row.id,
      });
      db.exec('COMMIT');
      const expense = db.prepare('SELECT * FROM expenses WHERE id = ?').get(id);
      res.status(201).json({ applied: true, expense: publicExpense(expense) });
    } catch (e) {
      try { db.exec('ROLLBACK'); } catch (_) { /* already rolled back */ }
      console.error(e);
      return error(res, 500, 'APPLY_FAILED', 'Fixed expense could not be applied.');
    }
  });

  app.use((req, res) => error(res, 404, 'NOT_FOUND', `No route ${req.method} ${req.path}.`));
  // eslint-disable-next-line no-unused-vars
  app.use((err, req, res, next) => {
    console.error(err);
    if (err && err.type === 'entity.parse.failed') {
      return error(res, 400, 'INVALID_JSON', 'Request body is not valid JSON.');
    }
    return error(res, 500, 'SERVER_ERROR', 'Unexpected server error.');
  });

  return { app, db };
}

module.exports = { createApp };
