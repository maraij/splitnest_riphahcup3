'use strict';
/**
 * Money helpers — all amounts are integer paisa internally.
 * JSON carries amounts as two-decimal strings ("780.00") so no binary
 * floating-point value ever crosses the API boundary.
 */

/** Parse a decimal amount (string or number) into integer paisa, or null. */
function parsePaisa(value) {
  if (value === null || value === undefined) return null;
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) return null;
    value = value.toFixed(2);
  }
  if (typeof value !== 'string') return null;
  const m = /^(-?)(\d+)(?:\.(\d{1,2}))?$/.exec(value.trim());
  if (!m) return null;
  const sign = m[1] === '-' ? -1 : 1;
  const whole = BigInt(m[2]);
  const frac = (m[3] || '').padEnd(2, '0');
  return sign * Number(whole * 100n + BigInt(frac));
}

/** Format integer paisa as a two-decimal string, e.g. -45000 -> "-450.00". */
function formatPaisa(paisa) {
  const sign = paisa < 0 ? '-' : '';
  const abs = Math.abs(paisa);
  return `${sign}${Math.floor(abs / 100)}.${String(abs % 100).padStart(2, '0')}`;
}

function isPositiveInt(n) {
  return Number.isInteger(n) && n > 0;
}

/**
 * Equal split of totalPaisa across memberIds (ascending ID order).
 * Base share = floor(total / n); the remainder paisa are handed out
 * 1-by-1 to the first members in ascending ID order.
 * Examples: 100000/3 -> [33334, 33333, 33333]; 1/3 -> [1, 0, 0];
 * 2/3 -> [1, 1, 0]; 3/3 -> [1, 1, 1].
 */
function equalSplit(totalPaisa, memberIds) {
  const ids = [...memberIds].sort();
  const n = ids.length;
  const base = Math.floor(totalPaisa / n);
  const remainder = totalPaisa - base * n;
  return ids.map((memberId, i) => ({
    member_id: memberId,
    amount_paisa: base + (i < remainder ? 1 : 0),
  }));
}

module.exports = { parsePaisa, formatPaisa, isPositiveInt, equalSplit };
