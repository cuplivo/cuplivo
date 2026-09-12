import test from 'node:test';
import assert from 'node:assert/strict';

import { latestReasoningPreview } from '../protocol.mjs';

test('uses the newest fragment from concatenated summary updates', () => {
  assert.equal(
    latestReasoningPreview('**Planning**Checking constraints**'),
    'Checking constraints',
  );
});

test('uses the last non-empty line or sentence', () => {
  assert.equal(latestReasoningPreview('first step\nsecond step'), 'second step');
  assert.equal(latestReasoningPreview('first step. second step.'), 'second step');
});

test('trims a long preview from the current tail', () => {
  const preview = latestReasoningPreview(
    'A very long accumulated reasoning summary that keeps growing',
    24,
  );
  assert.ok(preview.startsWith('\u2026'));
  assert.ok(preview.endsWith('keeps growing'));
});

test('returns an empty preview for blank input', () => {
  assert.equal(latestReasoningPreview('   \n  '), '');
  assert.equal(latestReasoningPreview(null), '');
});
