'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { parsePaisa, formatPaisa, equalSplit } = require('../src/money');

test('parse/format paisa round-trips', () => {
  assert.equal(parsePaisa('780.00'), 78000);
  assert.equal(parsePaisa('0.01'), 1);
  assert.equal(parsePaisa(1000), 100000);
  assert.equal(parsePaisa('1000.005'), null); // more than 2 decimals
  assert.equal(parsePaisa('abc'), null);
  assert.equal(parsePaisa('-450.00'), -45000);
  assert.equal(formatPaisa(78000), '780.00');
  assert.equal(formatPaisa(-45000), '-450.00');
  assert.equal(formatPaisa(1), '0.01');
});

test('equal split 1000.00 / 3 -> 333.34 / 333.33 / 333.33', () => {
  const shares = equalSplit(100000, ['M01', 'M02', 'M03']);
  assert.deepEqual(shares.map((s) => s.amount_paisa), [33334, 33333, 33333]);
  assert.equal(shares.reduce((a, s) => a + s.amount_paisa, 0), 100000);
});

test('equal split exact rounding cases from TESTING.md', () => {
  assert.deepEqual(equalSplit(1, ['M01', 'M02', 'M03']).map((s) => s.amount_paisa), [1, 0, 0]);
  assert.deepEqual(equalSplit(2, ['M01', 'M02', 'M03']).map((s) => s.amount_paisa), [1, 1, 0]);
  assert.deepEqual(equalSplit(3, ['M01', 'M02', 'M03']).map((s) => s.amount_paisa), [1, 1, 1]);
  assert.deepEqual(equalSplit(90000, ['M01', 'M02']).map((s) => s.amount_paisa), [45000, 45000]);
});

test('equal split is order-independent of input order (ascending ID)', () => {
  const shares = equalSplit(100000, ['M03', 'M01', 'M02']);
  assert.deepEqual(shares.map((s) => s.member_id), ['M01', 'M02', 'M03']);
  assert.equal(shares[0].amount_paisa, 33334);
});
