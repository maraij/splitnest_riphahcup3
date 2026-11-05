'use strict';
/**
 * Authentication: bcrypt-hashed passwords + in-memory sessions.
 *
 * Passwords are stored HASHED (bcrypt, cost 10) — plain text is never
 * stored in the DB. Demo passwords below are the SEED list only: they
 * are hashed immediately at seed time. These are DEMO passwords for a
 * practice build — change them before any real use (see README.md).
 *
 * Sessions live in memory (token -> memberId) and die with the server.
 */
const bcrypt = require('bcrypt');
const crypto = require('node:crypto');

const BCRYPT_ROUNDS = 10;

const DEMO_PASSWORDS = {
  M01: 'ali123',
  M02: 'ayesha123',
  M03: 'bilal123',
};

// token (hex) -> { memberId, googleEmail }. googleEmail is set only
// for sessions issued via Google sign-in; password sessions have null.
const sessions = new Map();

// Google sign-in (POST /api/auth/google): the ID token is verified
// against Google's tokeninfo endpoint before any session is issued.
// The Web OAuth client id (client_type 3 in google-services.json)
// is the audience the token must carry. The endpoint URL can be
// overridden with GOOGLE_TOKENINFO_URL so tests can point it at a
// local stub instead of Google.
const GOOGLE_WEB_CLIENT_ID =
  '780339874841-o9eaoan4imbo23gjge4s99cah5pqkgpo.apps.googleusercontent.com';
const GOOGLE_TOKENINFO_URL = 'https://oauth2.googleapis.com/tokeninfo';

function hashPassword(password) {
  return bcrypt.hashSync(password, BCRYPT_ROUNDS);
}

function verifyPassword(password, hash) {
  if (typeof password !== 'string' || !hash) return false;
  try {
    return bcrypt.compareSync(password, hash);
  } catch (_) {
    return false;
  }
}

function createSession(memberId, googleEmail = null) {
  const token = crypto.randomBytes(32).toString('hex');
  sessions.set(token, { memberId, googleEmail });
  return token;
}

function getSessionMember(token) {
  const session = sessions.get(token);
  return session ? session.memberId : null;
}

function getSessionInfo(token) {
  return sessions.get(token) || null;
}

/**
 * Verifies a Google ID token against Google's tokeninfo endpoint.
 * Returns { email } on success, null when the token is invalid:
 * wrong audience, wrong issuer, unverified email, expired,
 * unparseable, or the check itself could not be reached. The
 * tokeninfo URL is overridable via GOOGLE_TOKENINFO_URL (tests
 * point it at a local stub).
 */
async function verifyGoogleIdToken(idToken) {
  if (typeof idToken !== 'string' || idToken === '') return null;
  const base =
    process.env.GOOGLE_TOKENINFO_URL || GOOGLE_TOKENINFO_URL;
  let res;
  try {
    res = await fetch(
      `${base}?id_token=${encodeURIComponent(idToken)}`,
    );
  } catch (_) {
    return null;
  }
  if (!res.ok) return null;
  let info;
  try {
    info = await res.json();
  } catch (_) {
    return null;
  }
  if (info.aud !== GOOGLE_WEB_CLIENT_ID) return null;
  if (info.iss !== 'https://accounts.google.com' &&
      info.iss !== 'accounts.google.com') return null;
  if (info.email_verified !== true && info.email_verified !== 'true') {
    return null;
  }
  const exp = Number(info.exp);
  if (!Number.isFinite(exp) || exp * 1000 <= Date.now()) return null;
  if (typeof info.email !== 'string' || !info.email.includes('@')) {
    return null;
  }
  return { email: info.email };
}

module.exports = {
  DEMO_PASSWORDS,
  GOOGLE_WEB_CLIENT_ID,
  hashPassword,
  verifyPassword,
  createSession,
  getSessionMember,
  getSessionInfo,
  verifyGoogleIdToken,
};
