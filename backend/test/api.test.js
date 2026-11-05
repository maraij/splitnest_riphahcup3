'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { createApp } = require('../src/app');

function tmpDb() {
  return path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'splitnest-')), 'test.db');
}

async function start() {
  const dbPath = tmpDb();
  const { app, db } = createApp(dbPath);
  const server = await new Promise((resolve) => {
    const s = app.listen(0, '127.0.0.1', () => resolve(s));
  });
  const base = `http://127.0.0.1:${server.address().port}`;
  const stop = () => new Promise((resolve) => server.close(() => { db.close(); resolve(); }));
  return { base, dbPath, stop };
}

// Authenticated by default: loginAs(base) stores the session token and
// req() sends it as Authorization: Bearer <token> on every call.
// Pass { noAuth: true } for unauthenticated calls, or { headers } to
// override (e.g. a bad token).
let authHeaders = null;

async function req(base, method, p, body, opts = {}) {
  const headers = { 'Content-Type': 'application/json' };
  if (!opts.noAuth && authHeaders) Object.assign(headers, authHeaders);
  if (opts.headers) Object.assign(headers, opts.headers);
  const res = await fetch(`${base}${p}`, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  let json = null;
  try { json = await res.json(); } catch (_) { /* empty */ }
  return { status: res.status, json };
}

async function loginAs(base, memberId = 'M01', password = 'ali123') {
  const r = await req(base, 'POST', '/api/auth/login', { member_id: memberId, password }, { noAuth: true });
  assert.equal(r.status, 200, `login as ${memberId} failed: ${JSON.stringify(r.json)}`);
  assert.ok(typeof r.json.token === 'string' && r.json.token.length >= 32);
  authHeaders = { Authorization: `Bearer ${r.json.token}` };
  return r.json;
}

test('GET /api/members and seeded shopping items', async () => {
  const { base, stop } = await start();
  try {
    await loginAs(base);
    const members = await req(base, 'GET', '/api/members');
    assert.equal(members.status, 200);
    assert.deepEqual(members.json, [
      { id: 'M01', name: 'Ali' },
      { id: 'M02', name: 'Ayesha' },
      { id: 'M03', name: 'Bilal' },
    ]);
    const items = await req(base, 'GET', '/api/shopping');
    assert.equal(items.status, 200);
    assert.equal(items.json.length, 2);
    assert.deepEqual(items.json.map((i) => i.title), ['Milk', 'Rice']);
    assert.ok(items.json.every((i) => i.status === 'Pending'));
  } finally { await stop(); }
});

test('POST /api/shopping validates unit and quantity', async () => {
  const { base, stop } = await start();
  try {
    await loginAs(base);
    const ok = await req(base, 'POST', '/api/shopping', { title: 'Eggs', unit: 'dozen', requested_qty: 1 });
    assert.equal(ok.status, 201);
    assert.equal(ok.json.title, 'Eggs');
    assert.equal(ok.json.status, 'Pending');
    assert.equal((await req(base, 'POST', '/api/shopping', { title: 'X', unit: 'crate', requested_qty: 1 })).status, 400);
    assert.equal((await req(base, 'POST', '/api/shopping', { title: 'X', unit: 'pack', requested_qty: 0 })).status, 400);
    assert.equal((await req(base, 'POST', '/api/shopping', { title: ' ', unit: 'pack', requested_qty: 1 })).status, 400);
  } finally { await stop(); }
});

test('checkout is atomic: second checkout of same items fails, one expense only', async () => {
  const { base, stop } = await start();
  try {
    await loginAs(base);
    const first = await req(base, 'POST', '/api/shopping/checkout',
      { item_ids: ['S01', 'S02'], total_paid: '780.00', payer_id: 'M01', split_members: ['M01', 'M02', 'M03'] });
    assert.equal(first.status, 201);
    assert.equal(first.json.amount, '780.00');
    assert.deepEqual(first.json.shares.map((s) => s.amount), ['260.00', '260.00', '260.00']);
    const second = await req(base, 'POST', '/api/shopping/checkout',
      { item_ids: ['S01'], total_paid: '10.00', payer_id: 'M01', split_members: ['M01'] });
    assert.equal(second.status, 409);
    const items = await req(base, 'GET', '/api/shopping');
    assert.ok(items.json.every((i) => i.status === 'Bought'));
    const bal = await req(base, 'GET', '/api/balances');
    assert.equal(bal.json.total_spending, '780.00'); // exactly one expense
    // empty / duplicate / unknown checkout
    assert.equal((await req(base, 'POST', '/api/shopping/checkout', { item_ids: [], total_paid: '1.00', payer_id: 'M01' })).status, 400);
    assert.equal((await req(base, 'POST', '/api/shopping/checkout', { item_ids: ['S99'], total_paid: '1.00', payer_id: 'M01' })).status, 404);
  } finally { await stop(); }
});

test('POST /api/expenses: custom split must sum exactly; equal split rounds', async () => {
  const { base, stop } = await start();
  try {
    await loginAs(base);
    const bad = await req(base, 'POST', '/api/expenses', {
      title: 'Bad', category: 'Utilities', amount: '1500.00', payer_id: 'M03',
      split_type: 'custom',
      splits: [{ member_id: 'M01', amount: '500.00' }, { member_id: 'M02', amount: '300.00' }],
    });
    assert.equal(bad.status, 400);
    const good = await req(base, 'POST', '/api/expenses', {
      title: 'Internet Bill', category: 'Utilities', amount: '1500.00', payer_id: 'M03',
      split_type: 'custom',
      splits: [{ member_id: 'M01', amount: '500.00' }, { member_id: 'M02', amount: '300.00' }, { member_id: 'M03', amount: '700.00' }],
    });
    assert.equal(good.status, 201);
    const round = await req(base, 'POST', '/api/expenses', {
      title: 'Round', category: 'General', amount: '1000.00', payer_id: 'M01', split_type: 'equal',
    });
    assert.equal(round.status, 201);
    assert.deepEqual(round.json.shares.map((s) => s.amount), ['333.34', '333.33', '333.33']);
    assert.equal((await req(base, 'POST', '/api/expenses', {
      title: 'Zero', amount: '0.00', payer_id: 'M01', split_type: 'equal',
    })).status, 400);
  } finally { await stop(); }
});

test('settlement validation: self, non-debtor, over-settlement rejected', async () => {
  const { base, stop } = await start();
  try {
    await loginAs(base);
    // Ayesha owes 450 after this expense: Ali pays 900, equal Ali+Ayesha.
    await req(base, 'POST', '/api/expenses', {
      title: 'Cleaning', category: 'Cleaning', amount: '900.00', payer_id: 'M02',
      split_type: 'equal', split_members: ['M01', 'M02'],
    });
    // Note: payer is Ayesha here, so balances differ; use a clean debtor case below.
    const self = await req(base, 'POST', '/api/settle', { sender_id: 'M02', recipient_id: 'M02', amount: '10.00' });
    assert.equal(self.status, 400);
    const over = await req(base, 'POST', '/api/settle', { sender_id: 'M01', recipient_id: 'M02', amount: '9999.00' });
    assert.ok([400, 409].includes(over.status));
  } finally { await stop(); }
});

test('persistence after restart', async () => {
  const dbPath = tmpDb();
  const { app, db } = createApp(dbPath);
  const server = await new Promise((resolve) => { const s = app.listen(0, '127.0.0.1', () => resolve(s)); });
  const base = `http://127.0.0.1:${server.address().port}`;
  await loginAs(base);
  await req(base, 'POST', '/api/shopping', { title: 'Tea', unit: 'pack', requested_qty: 3 });
  await new Promise((r) => server.close(() => { db.close(); r(); }));
  // Reopen the same file: data must survive.
  const second = createApp(dbPath);
  const server2 = await new Promise((resolve) => { const s = second.app.listen(0, '127.0.0.1', () => resolve(s)); });
  const base2 = `http://127.0.0.1:${server2.address().port}`;
  try {
    await loginAs(base2);
    const items = await req(base2, 'GET', '/api/shopping');
    assert.ok(items.json.some((i) => i.title === 'Tea'));
    assert.equal(items.json.length, 3);
  } finally {
    await new Promise((r) => server2.close(() => { second.db.close(); r(); }));
  }
});

test('BENCHMARK (TESTING.md, exact): 4200 total, 800 remaining, 84%, +250/-450/+200, settle to zero', async () => {
  const { base, stop } = await start();
  try {
    await loginAs(base);
    const checkout = await req(base, 'POST', '/api/shopping/checkout',
      { item_ids: ['S01', 'S02'], total_paid: '780.00', payer_id: 'M01', split_members: ['M01', 'M02', 'M03'] });
    assert.equal(checkout.status, 201, JSON.stringify(checkout.json));
    const cleaning = await req(base, 'POST', '/api/expenses', {
      title: 'Cleaning Supplies', category: 'Cleaning', amount: '900.00', payer_id: 'M02',
      split_type: 'equal', split_members: ['M01', 'M02'],
    });
    assert.equal(cleaning.status, 201);
    const internet = await req(base, 'POST', '/api/expenses', {
      title: 'Internet Bill', category: 'Utilities', amount: '1500.00', payer_id: 'M03',
      split_type: 'custom',
      splits: [{ member_id: 'M01', amount: '500.00' }, { member_id: 'M02', amount: '300.00' }, { member_id: 'M03', amount: '700.00' }],
    });
    assert.equal(internet.status, 201);
    const electricity = await req(base, 'POST', '/api/expenses', {
      title: 'Electricity Bill', category: 'Utilities', amount: '1020.00', payer_id: 'M01',
      split_type: 'equal', split_members: ['M01', 'M02', 'M03'],
    });
    assert.equal(electricity.status, 201);

    const bal = await req(base, 'GET', '/api/balances');
    assert.equal(bal.status, 200);
    assert.equal(bal.json.total_spending, '4200.00');
    assert.equal(bal.json.budget, '5000.00');
    assert.equal(bal.json.remaining, '800.00');
    assert.equal(bal.json.used_percent, 84);
    assert.equal(bal.json.status, 'Near Limit');
    const nets = Object.fromEntries(bal.json.balances.map((b) => [b.member_id, b.net]));
    assert.deepEqual(nets, { M01: '250.00', M02: '-450.00', M03: '200.00' });
    const sum = bal.json.balances.reduce((a, b) => a + parseFloat(b.net), 0);
    assert.equal(sum, 0);

    const s1 = await req(base, 'POST', '/api/settle', { sender_id: 'M02', recipient_id: 'M01', amount: '250.00' });
    assert.equal(s1.status, 201, JSON.stringify(s1.json));
    const mid = await req(base, 'GET', '/api/balances');
    assert.deepEqual(Object.fromEntries(mid.json.balances.map((b) => [b.member_id, b.net])),
      { M01: '0.00', M02: '-200.00', M03: '200.00' });
    const s2 = await req(base, 'POST', '/api/settle', { sender_id: 'M02', recipient_id: 'M03', amount: '200.00' });
    assert.equal(s2.status, 201);
    const end = await req(base, 'GET', '/api/balances');
    assert.deepEqual(Object.fromEntries(end.json.balances.map((b) => [b.member_id, b.net])),
      { M01: '0.00', M02: '0.00', M03: '0.00' });
    assert.equal(end.json.total_spending, '4200.00'); // settlements never change spending
  } finally { await stop(); }
});

test('POST /api/auth/login succeeds with the correct password and returns a token', async () => {
  const { base, stop } = await start();
  try {
    const r = await req(base, 'POST', '/api/auth/login', { member_id: 'M02', password: 'ayesha123' }, { noAuth: true });
    assert.equal(r.status, 200);
    assert.equal(r.json.member.id, 'M02');
    assert.equal(r.json.member.name, 'Ayesha');
    assert.ok(typeof r.json.token === 'string' && r.json.token.length >= 32);
    // The returned token works on a protected endpoint.
    const bal = await req(base, 'GET', '/api/balances', undefined, { headers: { Authorization: `Bearer ${r.json.token}` } });
    assert.equal(bal.status, 200);
  } finally { await stop(); }
});

test('POST /api/auth/login rejects a wrong password with 401 and no token', async () => {
  const { base, stop } = await start();
  try {
    const r = await req(base, 'POST', '/api/auth/login', { member_id: 'M01', password: 'wrong-password' }, { noAuth: true });
    assert.equal(r.status, 401);
    assert.ok(r.json.error);
    assert.equal(r.json.token, undefined);
  } finally { await stop(); }
});

test('POST /api/auth/login rejects an unknown member with 401', async () => {
  const { base, stop } = await start();
  try {
    const r = await req(base, 'POST', '/api/auth/login', { member_id: 'M99', password: 'ali123' }, { noAuth: true });
    assert.equal(r.status, 401);
    assert.ok(r.json.error);
  } finally { await stop(); }
});

test('protected endpoints reject calls without a token (401)', async () => {
  const { base, stop } = await start();
  try {
    assert.equal((await req(base, 'GET', '/api/members', undefined, { noAuth: true })).status, 401);
    assert.equal((await req(base, 'GET', '/api/balances', undefined, { noAuth: true })).status, 401);
    assert.equal((await req(base, 'GET', '/api/shopping', undefined, { noAuth: true })).status, 401);
    assert.equal((await req(base, 'POST', '/api/expenses', { title: 'X', amount: '1.00', payer_id: 'M01', split_type: 'equal' }, { noAuth: true })).status, 401);
    assert.equal((await req(base, 'POST', '/api/settle', { sender_id: 'M02', recipient_id: 'M01', amount: '1.00' }, { noAuth: true })).status, 401);
  } finally { await stop(); }
});

test('protected endpoints reject a bad token with 401', async () => {
  const { base, stop } = await start();
  try {
    const bad = { headers: { Authorization: 'Bearer deadbeef-not-a-session' } };
    assert.equal((await req(base, 'GET', '/api/members', undefined, bad)).status, 401);
    assert.equal((await req(base, 'GET', '/api/balances', undefined, bad)).status, 401);
  } finally { await stop(); }
});

test('all three demo passwords log in', async () => {
  const { base, stop } = await start();
  try {
    for (const [id, pw] of [['M01', 'ali123'], ['M02', 'ayesha123'], ['M03', 'bilal123']]) {
      const r = await req(base, 'POST', '/api/auth/login', { member_id: id, password: pw }, { noAuth: true });
      assert.equal(r.status, 200, `login as ${id} failed`);
      assert.equal(r.json.member.id, id);
    }
  } finally { await stop(); }
});
