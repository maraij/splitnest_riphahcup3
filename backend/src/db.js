'use strict';
/**
 * SQLite persistence (Node built-in node:sqlite, file-based).
 * Tables: members, shopping_items, expenses, expense_shares,
 * settlements, household_budget. Integer paisa everywhere.
 */
const { DatabaseSync } = require('node:sqlite');
const fs = require('fs');
const path = require('path');
const { DEMO_PASSWORDS, hashPassword } = require('./auth');

const MEMBERS = [
  { id: 'M01', name: 'Ali' },
  { id: 'M02', name: 'Ayesha' },
  { id: 'M03', name: 'Bilal' },
];
const BUDGET_PAISA = 500000; // PKR 5,000.00
const UNITS = ['pack', 'dozen', 'bottle', 'bag'];

function openDb(dbPath) {
  const dir = path.dirname(dbPath);
  if (dir && dir !== '.') fs.mkdirSync(dir, { recursive: true });
  const db = new DatabaseSync(dbPath);
  db.exec('PRAGMA foreign_keys = ON');
  db.exec(`
    CREATE TABLE IF NOT EXISTS members (
      id TEXT PRIMARY KEY, name TEXT NOT NULL, password_hash TEXT
    );
    CREATE TABLE IF NOT EXISTS shopping_items (
      id TEXT PRIMARY KEY, title TEXT NOT NULL, unit TEXT NOT NULL,
      requested_qty INTEGER NOT NULL CHECK (requested_qty > 0),
      status TEXT NOT NULL DEFAULT 'Pending',
      checkout_expense_id TEXT
    );
    CREATE TABLE IF NOT EXISTS expenses (
      id TEXT PRIMARY KEY, title TEXT NOT NULL, category TEXT NOT NULL,
      expense_date TEXT NOT NULL, amount_paisa INTEGER NOT NULL CHECK (amount_paisa > 0),
      payer_id TEXT NOT NULL REFERENCES members(id), split_type TEXT NOT NULL,
      created_at TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS expense_shares (
      expense_id TEXT NOT NULL REFERENCES expenses(id),
      member_id TEXT NOT NULL REFERENCES members(id),
      share_paisa INTEGER NOT NULL CHECK (share_paisa >= 0),
      UNIQUE (expense_id, member_id)
    );
    CREATE TABLE IF NOT EXISTS settlements (
      id TEXT PRIMARY KEY, sender_id TEXT NOT NULL REFERENCES members(id),
      recipient_id TEXT NOT NULL REFERENCES members(id),
      amount_paisa INTEGER NOT NULL CHECK (amount_paisa > 0),
      created_at TEXT NOT NULL,
      CHECK (sender_id != recipient_id)
    );
    CREATE TABLE IF NOT EXISTS household_budget (
      month_key TEXT PRIMARY KEY, limit_paisa INTEGER NOT NULL CHECK (limit_paisa >= 0)
    );
    CREATE INDEX IF NOT EXISTS idx_expenses_date ON expenses(expense_date);
    CREATE INDEX IF NOT EXISTS idx_shares_member ON expense_shares(member_id);
    CREATE INDEX IF NOT EXISTS idx_shopping_status ON shopping_items(status);
    CREATE INDEX IF NOT EXISTS idx_settlements ON settlements(sender_id, recipient_id);
  `);
  // Migration for DBs created before passwords existed.
  const cols = db
    .prepare('PRAGMA table_info(members)')
    .all()
    .map((c) => c.name);
  if (!cols.includes('password_hash')) {
    db.exec('ALTER TABLE members ADD COLUMN password_hash TEXT');
  }
  seed(db);
  ensurePasswordHashes(db);
  return db;
}

/** Backfill bcrypt hashes for members that have none (old DBs). */
function ensurePasswordHashes(db) {
  const rows = db
    .prepare('SELECT id FROM members WHERE password_hash IS NULL')
    .all();
  const upd = db.prepare('UPDATE members SET password_hash = ? WHERE id = ?');
  for (const r of rows) {
    const pw = DEMO_PASSWORDS[r.id];
    if (pw) upd.run(hashPassword(pw), r.id);
  }
}

/** Seed only on a fresh/empty database; never preload benchmark expenses. */
function seed(db) {
  const count = db.prepare('SELECT COUNT(*) AS c FROM members').get().c;
  if (count > 0) return;
  const ins = db.prepare(
    'INSERT INTO members (id, name, password_hash) VALUES (?, ?, ?)');
  for (const m of MEMBERS) {
    ins.run(m.id, m.name, hashPassword(DEMO_PASSWORDS[m.id]));
  }
  const month = new Date().toISOString().slice(0, 7);
  db.prepare('INSERT INTO household_budget (month_key, limit_paisa) VALUES (?, ?)')
    .run(month, BUDGET_PAISA);
  const item = db.prepare(
    'INSERT INTO shopping_items (id, title, unit, requested_qty, status) VALUES (?, ?, ?, ?, ?)');
  item.run('S01', 'Milk', 'bottle', 2, 'Pending');
  item.run('S02', 'Rice', 'pack', 1, 'Pending');
}

function nextId(db, table, prefix) {
  const row = db.prepare(`SELECT id FROM ${table} ORDER BY id DESC LIMIT 1`).get();
  const n = row ? parseInt(row.id.slice(prefix.length), 10) + 1 : 1;
  return `${prefix}${String(n).padStart(2, '0')}`;
}

module.exports = { openDb, seed, nextId, MEMBERS, BUDGET_PAISA, UNITS };
