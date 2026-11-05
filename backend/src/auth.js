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

// token (hex) -> memberId
const sessions = new Map();

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

function createSession(memberId) {
  const token = crypto.randomBytes(32).toString('hex');
  sessions.set(token, memberId);
  return token;
}

function getSessionMember(token) {
  return sessions.get(token) || null;
}

module.exports = {
  DEMO_PASSWORDS,
  hashPassword,
  verifyPassword,
  createSession,
  getSessionMember,
};
