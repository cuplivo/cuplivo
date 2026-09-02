import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

import {
  extractMathSpans,
  restoreMathText,
  stableMathSlotKey,
} from '../protocol.mjs';

const require = createRequire(import.meta.url);
const { marked } = require('../vendor/marked.min.js');

const SM = [
  '$$',
  '\\mathcal{L}_{\\mathrm{SM}} = -\\frac{1}{4}G^a_{\\mu\\nu}G^{a\\mu\\nu} + \\sum_f \\bar{\\psi}_f\\left(i\\gamma^\\mu D_\\mu\\right)\\psi_f - \\left(y_e\\,\\bar{L}_L\\,\\phi\\, e_R\\right)',
  '$$',
].join('\n');

const CHAT = [
  '$$',
  '\\begin{array}{l}\\textcolor{gray}{X}\\ \\ \\fcolorbox{#9e9e9e}{#f5f5f5}{\\text{A}}\\\\[10pt]\\textcolor{blue}{Y}\\ \\ \\fcolorbox{#42a5f5}{#e3f2fd}{\\text{B}}\\\\[10pt]\\end{array}',
  '$$',
].join('\n');

const markedOpts = { gfm: true, breaks: true };

test('standard model: no underscores turned into <em>, span survives', () => {
  const { source, slots } = extractMathSpans(SM);
  assert.ok(slotKeys(source).length === 1, 'one slot expected');
  const html = marked.parse(source, markedOpts);
  assert.ok(!html.includes('<em>'), `marked must not italicize the math: ${html}`);
  assert.ok(restoreMathText(source, slots).includes('\\bar{\\psi}_f'));
  assert.ok(restoreMathText(source, slots).includes('(\\phi^\\dagger\\phi)') ||
      restoreMathText(source, slots).includes('\\mathrm{SM}'));
});

test('array chat: \\\\[10pt] row breaks survive the whole pipeline', () => {
  const { source, slots } = extractMathSpans(CHAT);
  const html = marked.parse(source, markedOpts);
  assert.ok(!html.includes('\\[10pt]'), 'marked must not halve the row break');
  const restored = restoreMathText(source, slots);
  assert.ok(restored.includes('\\\\[10pt]') || restored.includes('\\[10pt]'));
  // The slotted source must keep the raw backslashes until restore.
  assert.ok(source.includes(stableMathSlotKey(CHAT)));
});

test('inline \\(...\\) and \\[...\\] delimiters survive', () => {
  const input = 'inline \\(a_1+b_2\\) and \\[E=mc^2\\] done';
  const { source, slots } = extractMathSpans(input);
  assert.ok(!source.includes('\\(a_1'), 'inline delimiter must be slotted');
  assert.ok(!source.includes('\\[E=mc'), 'display delimiter must be slotted');
  const restored = restoreMathText(source, slots);
  assert.equal(restored, input);
});

test('fenced code blocks are never slotted', () => {
  const input = 'text\n```\n$$not math$$\n```\nend';
  const { source, slots } = extractMathSpans(input);
  assert.equal(slots.size, 0, 'math inside fences must stay untouched');
  assert.equal(source, input);
});

test('unclosed spans pass through untouched', () => {
  const input = 'tail $$unclosed';
  const { source, slots } = extractMathSpans(input);
  assert.equal(slots.size, 0);
  assert.equal(source, input);
});

test('single dollar only pairs when dollarMath is on', () => {
  const input = 'a $x + y$ b';
  const off = extractMathSpans(input, { dollarMath: false });
  assert.equal(off.slots.size, 0);
  const on = extractMathSpans(input, { dollarMath: true });
  assert.equal(on.slots.size, 1);
  assert.equal(restoreMathText(on.source, on.slots), input);
});

test('slots are deterministic and repeatable', () => {
  const a = extractMathSpans(SM);
  const b = extractMathSpans(SM);
  assert.equal(a.source, b.source);
  assert.equal(stableMathSlotKey(SM), stableMathSlotKey(SM));
});

test('restore is idempotent and order-safe', () => {
  const input = '$$a \\frac{b}{c}$$ then $$d + e$$';
  const { source, slots } = extractMathSpans(input);
  const restored = restoreMathText(source, slots);
  assert.equal(restored, input);
  assert.equal(restoreMathText(restored, new Map()), restored);
});

function slotKeys(source) {
  return /m:[0-9a-f]{8}/g[Symbol.match](source) ?? [];
}
