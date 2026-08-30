import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import {
  captureAnchor,
  captureInteractionAnchor,
  captureViewport,
  buildWithFrameBudget,
  commitPendingMeasurements,
  createAdaptiveStreamPresenter,
  createExpansionCoordinator,
  createFrameCoalescer,
  createRenderCommitCoordinator,
  createVirtualWindowCoordinator,
  createViewportNavigationCoordinator,
  createRenderGate,
  formatCountTemplate,
  formatReasoningElapsed,
  longestStablePrefix,
  mountCodeBlock,
  messageIndexAtOffset,
  verticalGestureIntent,
  normalizeMeasuredHeight,
  normalizeContentInset,
  partitionThinkingSteps,
  receiveTransferChunk,
  reduceEnvelope,
  restoreAnchor,
  restoreInteractionAnchor,
  restoreViewport,
  safeUtf16SliceEnd,
  virtualCoverage,
  virtualOverscan,
  viewportForSavedAnchor,
  visibleRange,
} from '../protocol.mjs';

const appSource = readFileSync(new URL('../app.mjs', import.meta.url), 'utf8');
const styleSource = readFileSync(new URL('../styles.css', import.meta.url), 'utf8');
const htmlSource = readFileSync(new URL('../index.html', import.meta.url), 'utf8');
const markedSource = readFileSync(new URL('../vendor/marked.min.js', import.meta.url), 'utf8');
const purifySource = readFileSync(new URL('../vendor/purify.min.js', import.meta.url), 'utf8');
const highlightSource = readFileSync(new URL('../vendor/highlight.min.js', import.meta.url), 'utf8');
const katexStyleSource = readFileSync(new URL('../vendor/katex.min.css', import.meta.url), 'utf8');

class TestNode {
  constructor(name) {
    this.name = name;
    this.parent = null;
    this.children = [];
  }

  contains(target) {
    return this === target || this.children.some((child) => child.contains(target));
  }

  append(...nodes) {
    for (const node of nodes) {
      if (node === this || node.contains(this)) throw new Error('HierarchyRequestError');
      node.parent?._remove(node);
      this.children.push(node);
      node.parent = this;
    }
  }

  replaceWith(replacement) {
    const parent = this.parent;
    if (!parent) return;
    if (replacement === parent || replacement.contains(parent)) {
      throw new Error('HierarchyRequestError');
    }
    replacement.parent?._remove(replacement);
    const index = parent.children.indexOf(this);
    parent.children[index] = replacement;
    replacement.parent = parent;
    this.parent = null;
  }

  _remove(node) {
    const index = this.children.indexOf(node);
    if (index >= 0) this.children.splice(index, 1);
    node.parent = null;
  }
}

test('transfer chunks reassemble UTF-8 snapshots', () => {
  const payload = { type: 'snapshot', content: '分片消息' };
  const bytes = new TextEncoder().encode(JSON.stringify(payload));
  const chunks = [bytes.slice(0, 5), bytes.slice(5)];
  let result = null;
  for (const [index, chunk] of chunks.entries()) {
    result = receiveTransferChunk({
      protocolVersion: 4,
      transferId: 'utf8-transfer',
      index,
      total: chunks.length,
      data: Buffer.from(chunk).toString('base64'),
    });
  }
  assert.deepEqual(result, payload);
});

test('snapshot reducer rejects an older revision in the same session', () => {
  const current = { type: 'snapshot', protocolVersion: 4, assetVersion: 'web-chat-v18', renderSessionId: 's', renderRevision: 4, messages: [] };
  const older = { ...current, renderRevision: 3, messages: [{ id: 'old' }] };
  assert.equal(reduceEnvelope(current, older), current);
});

test('new snapshots retain resolved opaque media only in the same session', () => {
  const current = {
    type: 'snapshot', protocolVersion: 4, assetVersion: 'web-chat-v18',
    renderSessionId: 's', renderRevision: 4, messages: [],
    media: { 'asset:icon': 'data:image/svg+xml;base64,PHN2Zy8+' },
  };
  const next = { ...current, renderRevision: 5, media: undefined };
  const retained = reduceEnvelope(current, next);
  assert.equal(retained.media['asset:icon'], current.media['asset:icon']);

  const changedSession = { ...next, renderSessionId: 'other' };
  assert.equal(reduceEnvelope(current, changedSession).media, undefined);
});

test('message patches affect only the active render session', () => {
  const state = { renderSessionId: 's', conversationId: 'c', messages: [{ id: 'm', content: 'a' }] };
  const next = reduceEnvelope(state, { type: 'messagePatches', renderSessionId: 's', conversationId: 'c', patches: [{ id: 'm', content: 'b' }] });
  assert.equal(next.messages[0].content, 'b');
  assert.equal(reduceEnvelope(state, { type: 'messagePatches', renderSessionId: 'old', conversationId: 'c', patches: [] }), state);
});

test('message patches reject stale stream revisions without breaking legacy patches', () => {
  const state = {
    renderSessionId: 's',
    conversationId: 'c',
    messages: [{ id: 'm', content: 'new', isStreaming: true, streamRevision: 4 }],
  };
  const stale = reduceEnvelope(state, {
    type: 'messagePatches',
    renderSessionId: 's',
    conversationId: 'c',
    patches: [{ id: 'm', content: 'old', streamRevision: 3 }],
  });
  assert.equal(stale.messages[0].content, 'new');
  const legacy = reduceEnvelope(state, {
    type: 'messagePatches',
    renderSessionId: 's',
    conversationId: 'c',
    patches: [{ id: 'm', content: 'legacy' }],
  });
  assert.equal(legacy.messages[0].content, 'legacy');
  const finished = {
    ...state,
    messages: [{ id: 'm', content: 'final', isStreaming: false }],
  };
  const late = reduceEnvelope(finished, {
    type: 'messagePatches',
    renderSessionId: 's',
    conversationId: 'c',
    patches: [{ id: 'm', content: 'partial', isStreaming: true, streamRevision: 5 }],
  });
  assert.equal(late.messages[0].content, 'final');
});

test('translation patches preserve completed message content and state', () => {
  const state = {
    renderSessionId: 's',
    conversationId: 'c',
    messages: [{ id: 'm', content: 'final answer', isStreaming: false }],
  };
  const next = reduceEnvelope(state, {
    type: 'messagePatches',
    renderSessionId: 's',
    conversationId: 'c',
    patches: [{ id: 'm', patchKind: 'translation', translation: '译文' }],
  });

  assert.equal(next.messages[0].content, 'final answer');
  assert.equal(next.messages[0].isStreaming, false);
  assert.equal(next.messages[0].translation, '译文');
});

test('stream patches can register opaque media without leaking it into messages', () => {
  assert.match(appSource, /const \{ remoteMediaHandles, \.\.\.messagePatch \} = patch/);
  assert.match(appSource, /remoteMediaHandles:[\s\S]*?\.\.\.remoteMediaHandles/);
  assert.match(appSource, /return messagePatch/);
});

test('typed appearance maps only the three supported surfaces and clears defaults', () => {
  assert.match(appSource, /const appearanceSurfaces = \{[\s\S]*?userBubble: 'user'[\s\S]*?assistantBubble: 'assistant'[\s\S]*?processCard: 'process'/);
  assert.match(appSource, /\^#\[0-9a-f\]\{6\}/i);
  assert.match(appSource, /rootStyle\.removeProperty\(variable\)/);
  assert.match(appSource, /delete document\.body\.dataset\[dataKey\]/);
  assert.match(appSource, /document\.body\.dataset\.customAppearance = String\(applied\)/);
  assert.match(appSource, /applyAppearance\(\)/);
  assert.doesNotMatch(appSource, /state\?\.appearance[\s\S]{0,160}innerHTML/);

  assert.match(styleSource, /data-style-user-background/);
  assert.match(styleSource, /data-style-assistant-background/);
  assert.match(styleSource, /data-style-process-background/);
  assert.match(styleSource, /\.assistant-text-surface/);
  assert.match(styleSource, /\.chain-card/);
  assert.match(styleSource, /\.message\.is-user \.bubble/);
});

test('same-session streaming snapshots preserve a newer live patch', () => {
  const state = {
    type: 'snapshot', protocolVersion: 4, assetVersion: 'web-chat-v18',
    renderSessionId: 's', conversationId: 'c', renderRevision: 2,
    messages: [{ id: 'm', content: 'new', isStreaming: true, streamRevision: 7 }],
  };
  const next = reduceEnvelope(state, {
    ...state,
    renderRevision: 3,
    messages: [{ id: 'm', content: 'old', isStreaming: true }],
  });
  assert.equal(next.messages[0].content, 'new');
  assert.equal(next.messages[0].streamRevision, 7);
});

test('live translation survives unrelated snapshots until it is finalized', () => {
  const state = {
    type: 'snapshot', protocolVersion: 4, assetVersion: 'web-chat-v18',
    renderSessionId: 's', conversationId: 'c', renderRevision: 2,
    messages: [{
      id: 'm', content: 'answer', isStreaming: false,
      translation: 'new translation', patchKind: 'translation', streamRevision: 4,
    }],
  };
  const whileTranslating = reduceEnvelope(state, {
    ...state,
    renderRevision: 3,
    messages: [{
      id: 'm', content: 'answer', isStreaming: false,
      translation: 'Translating…', translationStreaming: true,
    }],
  });
  assert.equal(whileTranslating.messages[0].translation, 'new translation');

  const finalized = reduceEnvelope(whileTranslating, {
    ...state,
    renderRevision: 4,
    messages: [{
      id: 'm', content: 'answer', isStreaming: false,
      translation: '', translationStreaming: false,
    }],
  });
  assert.equal(finalized.messages[0].translation, '');
  assert.equal(finalized.messages[0].patchKind, undefined);
});

test('heavy Markdown renderers are loaded only when matching content appears', () => {
  assert.doesNotMatch(htmlSource, /<script[^>]+(?:highlight|katex|auto-render|mermaid)/);
  assert.doesNotMatch(htmlSource, /<link[^>]+(?:github|katex)/);
  const imagePolicy = htmlSource.match(/img-src\s+([^;]+)/)?.[1] ?? '';
  assert.doesNotMatch(imagePolicy, /(?:^|\s)http:(?:\s|$)/);
  assert.match(appSource, /function loadScriptOnce/);
  assert.match(appSource, /function loadStyleOnce/);
  assert.match(appSource, /rendererLoads\.get\(key\)/);
  assert.match(appSource, /ensureHighlightRenderer/);
  assert.match(appSource, /ensureMathRenderer/);
  assert.match(appSource, /ensureMermaidRenderer/);
  assert.match(appSource, /renderer_resource_failed/);
  assert.match(appSource, /markdownSourceForRender/);
  assert.match(appSource, /remoteImagePlaceholder/);
  assert.doesNotMatch(katexStyleSource, /\.ttf|\.woff\)/);
});

test('render commit, selection, attachment, and citation bridges stay opaque', () => {
  assert.match(appSource, /type: 'renderCommitted'/);
  assert.match(
    appSource,
    /function renderSafely[\s\S]*?code: 'render_failed'[\s\S]*?capabilityToken:/,
  );
  assert.match(appSource, /role', 'checkbox'/);
  assert.match(appSource, /aria-checked/);
  assert.match(appSource, /window\.getSelection\(\)/);
  assert.match(appSource, /sendAction\('previewImage',[\s\S]*?\{ handle \}/);
  assert.match(appSource, /sendAction\('openAttachment',[\s\S]*?\{ handle \}/);
  assert.match(appSource, /sendAction\('openCitation'/);
  assert.match(appSource, /sendAction\('showCitations'/);
  assert.match(appSource, /createTreeWalker\(root, NodeFilter\.SHOW_TEXT\)/);
  assert.match(appSource, /closest\('code, pre, a, button'\)/);
  assert.doesNotMatch(appSource, /openAttachment[^\n]+reference/);
});

test('virtual range grows with the viewport rather than total messages', () => {
  const range = visibleRange({ heights: new Array(360).fill(100), scrollTop: 12000, viewportHeight: 700, overscan: 300 });
  assert.ok(range.end - range.start < 20);
  assert.equal(range.top, range.start * 100);
});

test('virtual window uses a bounded three-screen overscan', () => {
  assert.equal(virtualOverscan(700), 2400);
  assert.equal(virtualOverscan(1000), 3000);
  const range = visibleRange({
    heights: new Array(360).fill(100),
    scrollTop: 12000,
    viewportHeight: 700,
    overscan: virtualOverscan(700),
  });
  assert.ok(range.end - range.start < 60);
});

test('virtual coverage clamps an uncovered viewport to rendered messages', () => {
  const heights = new Array(100).fill(100);
  const coverage = virtualCoverage({
    heights,
    range: { start: 20, end: 40 },
    scrollTop: 8200,
    viewportHeight: 700,
  });
  assert.equal(coverage.covered, false);
  assert.equal(coverage.min, 2000);
  assert.equal(coverage.max, 3300);
  assert.equal(coverage.requested, 8200);
  assert.equal(coverage.maxExtent, 9300);
  assert.equal(coverage.clamped, 3300);
  assert.equal(virtualCoverage({
    heights,
    range: { start: 20, end: 40 },
    scrollTop: 2500,
    viewportHeight: 700,
  }).covered, true);
});

test('virtual window holds the requested position while rendering and latest target wins', async () => {
  const frames = [];
  const events = [];
  const coordinator = createVirtualWindowCoordinator({
    schedule: (callback) => frames.push(callback),
    setLoading: (value) => events.push(`loading:${value}`),
    clamp: (value) => events.push(`clamp:${value}`),
    renderTarget: async (value) => events.push(`render:${value}`),
    settleTarget: (value) => events.push(`settle:${value}`),
    timeoutMs: 0,
  });
  coordinator.request({ target: 9000 });
  coordinator.request({ target: 1200 });
  assert.deepEqual(events, ['loading:true', 'clamp:9000', 'clamp:1200']);
  assert.equal(frames.length, 1);
  frames.shift()(16);
  await Promise.resolve();
  assert.deepEqual(events, [
    'loading:true', 'clamp:9000', 'clamp:1200', 'render:1200',
  ]);
  assert.equal(frames.length, 1);
  frames.shift()(32);
  assert.deepEqual(events, [
    'loading:true', 'clamp:9000', 'clamp:1200', 'render:1200',
    'settle:1200', 'loading:false',
  ]);
});

test('canceling a virtual window prevents stale completion', async () => {
  const frames = [];
  const events = [];
  let finishRender;
  const coordinator = createVirtualWindowCoordinator({
    schedule: (callback) => frames.push(callback),
    setLoading: (value) => events.push(`loading:${value}`),
    clamp: () => {},
    renderTarget: () => new Promise((resolve) => { finishRender = resolve; }),
    settleTarget: () => events.push('settled'),
  });
  coordinator.request({ target: 9000 });
  frames.shift()(16);
  coordinator.cancel();
  finishRender();
  await Promise.resolve();
  assert.deepEqual(events, ['loading:true', 'loading:false']);
});

test('virtual window timeout stays at the requested position and reports failure', async () => {
  const events = [];
  const coordinator = createVirtualWindowCoordinator({
    schedule: (callback) => callback(),
    setLoading: (value) => events.push(`loading:${value}`),
    clamp: (value) => events.push(`clamp:${value}`),
    renderTarget: () => new Promise(() => {}),
    settleTarget: () => events.push('settled'),
    onError: (error) => events.push(error.message),
    timeoutMs: 5,
  });
  coordinator.request({ target: 9000 });
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.deepEqual(events, [
    'loading:true',
    'clamp:9000',
    'loading:false',
    'virtual_window_timeout',
  ]);
  assert.equal(coordinator.active, false);
});

test('virtual messages build within a per-frame budget and cancel stale work', async () => {
  const frames = [];
  let clock = 0;
  const work = buildWithFrameBudget({
    items: [1, 2, 3, 4, 5],
    schedule: (callback) => frames.push(callback),
    now: () => clock,
    budgetMs: 6,
    build: (value) => {
      clock += 4;
      return value * 2;
    },
  });
  assert.equal(frames.length, 1);
  frames.shift()();
  assert.equal(frames.length, 1);
  frames.shift()();
  assert.equal(frames.length, 1);
  frames.shift()();
  assert.deepEqual(await work, [2, 4, 6, 8, 10]);

  const canceledFrames = [];
  let current = true;
  const canceled = buildWithFrameBudget({
    items: [1, 2],
    schedule: (callback) => canceledFrames.push(callback),
    shouldContinue: () => current,
    build: (value) => value,
  });
  current = false;
  canceledFrames.shift()();
  await assert.rejects(canceled, /virtual_window_stale/);
});

test('adaptive streaming catches up by its deadline and preserves Unicode', () => {
  const frames = [];
  const commits = [];
  let clock = 0;
  const presenter = createAdaptiveStreamPresenter({
    schedule: (callback) => frames.push(callback),
    now: () => clock,
    commit: (id, content) => commits.push([id, content]),
  });
  presenter.update({ id: 'm', displayed: '', target: '你好😀世界' });
  for (const time of [32, 64, 96]) {
    clock = time;
    frames.shift()?.(time);
  }
  assert.equal(commits.at(-1)[1], '你好😀世界');
  for (const [, content] of commits) {
    assert.doesNotMatch(content, /[\uD800-\uDBFF]$/);
  }
});

test('continuous stream updates do not move the original catch-up deadline', () => {
  const frames = [];
  const commits = [];
  let clock = 0;
  const presenter = createAdaptiveStreamPresenter({
    schedule: (callback) => frames.push(callback),
    now: () => clock,
    commit: (_, content) => commits.push(content),
  });
  presenter.update({ id: 'm', target: '第一段较长的初始内容' });
  clock = 20;
  presenter.update({ id: 'm', target: '第一段较长的初始内容和追加内容' });
  clock = 32;
  frames.shift()(clock);
  clock = 48;
  presenter.update({ id: 'm', target: '第一段较长的初始内容和追加内容😀' });
  clock = 64;
  frames.shift()(clock);
  clock = 96;
  frames.shift()?.(clock);
  assert.equal(commits.at(-1), '第一段较长的初始内容和追加内容😀');
});

test('Markdown diff retains the longest unchanged top-level prefix', () => {
  assert.equal(
    longestStablePrefix(
      ['paragraph:first', 'code:stable', 'paragraph:old tail'],
      ['paragraph:first', 'code:stable', 'paragraph:new tail'],
    ),
    2,
  );
  assert.equal(longestStablePrefix(['a'], ['different']), 0);
  assert.equal(longestStablePrefix(null, ['a']), 0);
});

test('streaming rewrites and completion flush immediately', () => {
  const commits = [];
  const presenter = createAdaptiveStreamPresenter({
    schedule: () => {},
    now: () => 0,
    commit: (id, content) => commits.push([id, content]),
  });
  presenter.update({ id: 'm', displayed: 'prefix', target: 'replacement' });
  presenter.update({
    id: 'm', displayed: 'replacement', target: 'replacement final', final: true,
  });
  assert.deepEqual(commits, [
    ['m', 'replacement'],
    ['m', 'replacement final'],
  ]);
  assert.equal(safeUtf16SliceEnd('a😀b', 2), 3);
});

test('frame coalescer runs once for a burst', () => {
  const frames = [];
  let calls = 0;
  const schedule = createFrameCoalescer(() => { calls += 1; }, (callback) => frames.push(callback));
  schedule(); schedule(); schedule();
  assert.equal(frames.length, 1);
  frames[0]();
  assert.equal(calls, 1);
});

test('render gate defers DOM work throughout a gesture and flushes once', () => {
  let calls = 0;
  const gate = createRenderGate(() => { calls += 1; });
  gate.setBlocked(true);
  assert.equal(gate.blocked, true);
  gate.request();
  gate.request();
  assert.equal(calls, 0);
  assert.equal(gate.pending, true);
  gate.setBlocked(false);
  assert.equal(gate.blocked, false);
  assert.equal(calls, 1);
  assert.equal(gate.pending, false);
  gate.setBlocked(false);
  assert.equal(calls, 1);
});

test('viewport navigation renders the destination before settling and unlocks once', () => {
  const frames = [];
  const events = [];
  let blocked = false;
  let renderPending = false;
  const coordinator = createViewportNavigationCoordinator({
    schedule: (callback) => frames.push(callback),
    setRenderBlocked: (value) => {
      blocked = value;
      events.push(value ? 'block' : 'unblock');
      if (!value && renderPending) {
        renderPending = false;
        frames.push(() => events.push('render'));
      }
    },
    requestRender: () => {
      if (blocked) renderPending = true;
      else frames.push(() => events.push('render'));
    },
    settleFrames: 2,
  });

  coordinator.run(
    () => events.push('settle'),
    () => events.push('complete'),
  );
  assert.equal(blocked, true);
  assert.deepEqual(events, ['block', 'unblock', 'block']);

  frames.shift()();
  frames.shift()();
  assert.deepEqual(events, ['block', 'unblock', 'block', 'render', 'settle']);
  assert.equal(blocked, true);

  frames.shift()();
  assert.equal(blocked, false);
  assert.deepEqual(events, [
    'block', 'unblock', 'block', 'render', 'settle', 'settle', 'unblock',
  ]);

  frames.shift()();
  frames.shift()();
  assert.deepEqual(events, [
    'block', 'unblock', 'block', 'render', 'settle', 'settle', 'unblock',
    'render', 'settle', 'complete',
  ]);
});

test('a newer viewport navigation supersedes stale settling frames', () => {
  const frames = [];
  const settled = [];
  const coordinator = createViewportNavigationCoordinator({
    schedule: (callback) => frames.push(callback),
    setRenderBlocked: () => {},
    requestRender: () => {},
    settleFrames: 1,
  });

  coordinator.run(() => settled.push('old'));
  coordinator.run(() => settled.push('new'));
  while (frames.length) frames.shift()();

  assert.deepEqual(settled, ['new', 'new']);
});

test('canceling an inactive viewport navigation does not release a gesture gate', () => {
  let unlocks = 0;
  const coordinator = createViewportNavigationCoordinator({
    schedule: () => {},
    setRenderBlocked: (value) => {
      if (!value) unlocks += 1;
    },
    requestRender: () => {},
  });

  coordinator.cancel();

  assert.equal(unlocks, 0);
});

test('logical message index resolves when no rendered DOM anchor is available', () => {
  assert.equal(messageIndexAtOffset([100, 120, 140], 0), 0);
  assert.equal(messageIndexAtOffset([100, 120, 140], 99), 0);
  assert.equal(messageIndexAtOffset([100, 120, 140], 100), 1);
  assert.equal(messageIndexAtOffset([100, 120, 140], 999), 2);
  assert.equal(messageIndexAtOffset([], 20), -1);
  assert.equal(messageIndexAtOffset([100, Number.NaN, 140], 150), 1);
});

test('offscreen zero-size observations never replace stable message heights', () => {
  assert.equal(normalizeMeasuredHeight(128.2), 129);
  assert.equal(normalizeMeasuredHeight(0), null);
  assert.equal(normalizeMeasuredHeight(-1), null);
  assert.equal(normalizeMeasuredHeight(Number.NaN), null);
  assert.doesNotMatch(styleSource, /content-visibility:\s*auto/);
});

test('measured heights remain staged until one atomic commit', () => {
  const committed = new Map([['a', 120], ['b', 180]]);
  const pending = new Map([['a', 260], ['b', 180], ['c', 90]]);

  assert.equal(committed.get('a'), 120);
  assert.equal(commitPendingMeasurements(committed, pending), true);
  assert.deepEqual([...committed], [['a', 260], ['b', 180], ['c', 90]]);
  assert.equal(pending.size, 0);
  assert.equal(commitPendingMeasurements(committed, pending), false);
});

test('content insets accept finite non-negative values only', () => {
  assert.equal(normalizeContentInset(88), 88);
  assert.equal(normalizeContentInset(-1), 8);
  assert.equal(normalizeContentInset(Number.POSITIVE_INFINITY), 8);
  assert.equal(normalizeContentInset('104'), 8);
  assert.equal(normalizeContentInset(null), 8);
  assert.equal(normalizeContentInset('invalid'), 8);
});

test('reasoning elapsed time mirrors Flutter formatting for live and finished steps', () => {
  const start = '2026-08-25T12:00:00.000Z';
  const finish = '2026-08-25T12:00:01.234Z';
  assert.equal(formatReasoningElapsed(start, finish, false), '(1.2s)');
  assert.equal(formatReasoningElapsed(start, null, true, Date.parse(finish)), '(1.2s)');
  assert.equal(formatReasoningElapsed(start, null, false), '(0.0s)');
  assert.equal(formatReasoningElapsed(null, finish, false), '');
  assert.equal(formatReasoningElapsed('invalid', finish, false), '');
  const replaceIndex = appSource.indexOf('timeline.replaceChildren(fragment)');
  const timerIndex = appSource.indexOf('ensureReasoningElapsedTimer()', replaceIndex);
  assert.ok(replaceIndex >= 0 && timerIndex > replaceIndex);
});

test('controlled expansion coalesces rapid clicks and ignores stale state', () => {
  const sent = [];
  const coordinator = createExpansionCoordinator();
  const dispatch = (target) => {
    const requestId = `r${sent.length + 1}`;
    sent.push({ requestId, target });
    return requestId;
  };

  coordinator.toggle({ key: 'reasoning', authoritative: false, dispatch });
  assert.equal(coordinator.value('reasoning', false), true);
  assert.equal(coordinator.isPending('reasoning'), true);
  coordinator.toggle({ key: 'reasoning', authoritative: false, dispatch });
  assert.equal(coordinator.value('reasoning', false), false);
  assert.deepEqual(sent.map((item) => item.target), [true]);

  coordinator.resolve('r1', true);
  assert.deepEqual(sent.map((item) => item.target), [true, false]);
  assert.equal(coordinator.value('reasoning', true), false);
  coordinator.resolve('r2', true);
  assert.equal(coordinator.value('reasoning', false), false);
  assert.equal(coordinator.isPending('reasoning'), false);
});

test('controlled expansion rolls back after a failed action', () => {
  const coordinator = createExpansionCoordinator();
  coordinator.toggle({
    key: 'reasoning',
    authoritative: false,
    dispatch: () => 'failed-request',
  });
  assert.equal(coordinator.value('reasoning', false), true);
  coordinator.resolve('failed-request', false);
  assert.equal(coordinator.value('reasoning', false), false);
  assert.equal(coordinator.isPending('reasoning'), false);
});

test('anchor capture and restore preserve the message offset', () => {
  const nodes = [
    { dataset: { messageId: 'a' }, getBoundingClientRect: () => ({ top: -20, bottom: -1 }) },
    { dataset: { messageId: 'b' }, getBoundingClientRect: () => ({ top: 18, bottom: 118 }) },
  ];
  const container = {
    scrollTop: 100,
    getBoundingClientRect: () => ({ top: 10 }),
    querySelectorAll: () => nodes,
  };
  const anchor = captureAnchor(container);
  assert.deepEqual(anchor, { id: 'b', offset: 8 });
  nodes[1].getBoundingClientRect = () => ({ top: 24, bottom: 124 });
  assert.equal(restoreAnchor(container, anchor), true);
  assert.equal(container.scrollTop, 106);
});

test('interaction anchors preserve a disclosure header even at the bottom', () => {
  let headerTop = 140;
  const header = {
    getBoundingClientRect: () => ({ top: headerTop, bottom: headerTop + 42 }),
  };
  const disclosure = {
    dataset: { expansionKey: 'm:tool:t1' },
    querySelector: () => header,
  };
  const message = {
    dataset: { messageId: 'm' },
    querySelectorAll: () => [disclosure],
  };
  const container = {
    scrollTop: 400,
    scrollHeight: 1400,
    clientHeight: 600,
    getBoundingClientRect: () => ({ top: 20 }),
    querySelectorAll: () => [message],
  };
  header.closest = (selector) => selector.includes('data-message')
    ? message
    : disclosure;

  const anchor = captureInteractionAnchor(container, header);
  assert.deepEqual(anchor, {
    messageId: 'm',
    expansionKey: 'm:tool:t1',
    offset: 120,
  });
  headerTop = 205;
  assert.equal(restoreInteractionAnchor(container, anchor), true);
  assert.equal(container.scrollTop, 465);

  container.scrollTop = 800;
  const bottomAnchor = captureInteractionAnchor(container, header);
  container.scrollHeight = 1100;
  container.scrollTop = 350;
  assert.equal(restoreInteractionAnchor(container, bottomAnchor), true);
  assert.equal(container.scrollTop, 350);
});

test('granular viewport anchors survive a message-local redraw', () => {
  let blockTop = 24;
  const block = {
    dataset: { viewportAnchorKey: 'm:reasoning:0:block:2' },
    closest: () => message,
    getBoundingClientRect: () => ({ top: blockTop, bottom: blockTop + 80 }),
  };
  const message = {
    dataset: { messageId: 'm', messageSlot: 'true' },
    querySelectorAll: () => [block],
    getBoundingClientRect: () => ({ top: -600, bottom: 900 }),
  };
  const container = {
    scrollTop: 700,
    clientHeight: 600,
    getBoundingClientRect: () => ({ top: 0, bottom: 600 }),
    querySelectorAll: (selector) => selector.includes('viewport')
      ? [block]
      : [message],
  };

  const anchor = captureAnchor(container);
  assert.deepEqual(anchor, {
    id: 'm',
    key: 'm:reasoning:0:block:2',
    offset: 24,
    messageOffset: -600,
  });
  blockTop = 79;
  assert.equal(restoreAnchor(container, anchor), true);
  assert.equal(container.scrollTop, 755);
});

test('granular viewport anchors ignore collapsed zero-size descendants', () => {
  const hidden = {
    dataset: { viewportAnchorKey: 'm:hidden-step' },
    getBoundingClientRect: () => ({ top: 0, bottom: 0 }),
  };
  const visible = {
    dataset: { viewportAnchorKey: 'm:visible-block' },
    closest: () => message,
    getBoundingClientRect: () => ({ top: 32, bottom: 92 }),
  };
  const message = {
    dataset: { messageId: 'm', messageSlot: 'true' },
    getBoundingClientRect: () => ({ top: -400, bottom: 400 }),
  };
  const container = {
    clientHeight: 600,
    getBoundingClientRect: () => ({ top: 0 }),
    querySelectorAll: (selector) => selector.includes('viewport')
      ? [hidden, visible]
      : [message],
  };

  assert.deepEqual(captureAnchor(container), {
    id: 'm',
    key: 'm:visible-block',
    offset: 32,
    messageOffset: -400,
  });
});

test('granular viewport anchors fall back to the captured message offset', () => {
  let messageTop = -500;
  let anchors;
  const message = {
    dataset: { messageId: 'm', messageSlot: 'true' },
    querySelectorAll: () => anchors,
    getBoundingClientRect: () => ({ top: messageTop, bottom: messageTop + 900 }),
  };
  const block = {
    dataset: { viewportAnchorKey: 'm:content:block:3' },
    closest: () => message,
    getBoundingClientRect: () => ({ top: 30, bottom: 110 }),
  };
  anchors = [block];
  const container = {
    scrollTop: 800,
    clientHeight: 600,
    getBoundingClientRect: () => ({ top: 0 }),
    querySelectorAll: (selector) => selector.includes('viewport')
      ? anchors
      : [message],
  };

  const anchor = captureAnchor(container);
  anchors = [];
  messageTop = -440;

  assert.equal(restoreAnchor(container, anchor), true);
  assert.equal(container.scrollTop, 860);
});

test('render commit coordinator does not starve an ACK on same-revision renders', () => {
  const frames = [];
  const canceled = [];
  const commits = [];
  const coordinator = createRenderCommitCoordinator({
    schedule: (callback) => {
      frames.push(callback);
      return frames.length;
    },
    cancel: (frame) => canceled.push(frame),
    commit: (identity) => commits.push(identity.renderRevision),
  });
  const revision1 = {
    renderSessionId: 's',
    conversationId: 'c',
    renderRevision: 1,
  };

  coordinator.request(revision1);
  coordinator.request({ ...revision1 });
  assert.equal(frames.length, 1);
  assert.deepEqual(canceled, []);
  frames.shift()();
  assert.deepEqual(commits, [1]);

  coordinator.request({ ...revision1 });
  assert.equal(frames.length, 0);
  coordinator.request({ ...revision1, renderRevision: 2 });
  assert.equal(frames.length, 1);
  frames.shift()();
  assert.deepEqual(commits, [1, 2]);
});

test('a newer render identity cancels a stale pending ACK', () => {
  let nextFrame = 0;
  const frames = new Map();
  const commits = [];
  const coordinator = createRenderCommitCoordinator({
    schedule: (callback) => {
      const frame = nextFrame += 1;
      frames.set(frame, callback);
      return frame;
    },
    cancel: (frame) => frames.delete(frame),
    commit: (identity) => commits.push([
      identity.renderSessionId,
      identity.conversationId,
      identity.renderRevision,
    ]),
  });

  coordinator.request({
    renderSessionId: 'old-session',
    conversationId: 'old-conversation',
    renderRevision: 3,
  });
  coordinator.request({
    renderSessionId: 'new-session',
    conversationId: 'new-conversation',
    renderRevision: 1,
  });

  assert.equal(frames.size, 1);
  [...frames.values()][0]();
  assert.deepEqual(commits, [['new-session', 'new-conversation', 1]]);
});

test('a conversation switch clears staged layout and render transaction state', () => {
  assert.match(appSource, /const previousConversationId = state\?\.conversationId/);
  const resetStart = appSource.indexOf('if (previousSessionId &&');
  const resetEnd = appSource.indexOf('for (const message of state?.messages', resetStart);
  const resetBody = appSource.slice(resetStart, resetEnd);

  assert.match(resetBody, /previousConversationId !== state\?\.conversationId/);
  assert.match(resetBody, /pendingMeasuredHeights\.clear\(\)/);
  assert.match(resetBody, /cancelInteractionLayout\(\)/);
  assert.match(resetBody, /renderCommitCoordinator\.clear\(\)/);
});

test('virtual rendering keeps the pre-replacement viewport position', () => {
  let nodes = [
    { dataset: { messageId: 'middle' }, getBoundingClientRect: () => ({ top: 10, bottom: 110 }) },
  ];
  const container = {
    scrollTop: 12000,
    scrollHeight: 36000,
    clientHeight: 700,
    getBoundingClientRect: () => ({ top: 0 }),
    querySelectorAll: () => nodes,
  };

  const viewport = captureViewport(container);
  container.scrollTop = 0;
  container.scrollHeight = container.clientHeight;
  nodes = [];

  const range = visibleRange({
    heights: new Array(360).fill(100),
    scrollTop: viewport.scrollTop,
    viewportHeight: viewport.viewportHeight,
    overscan: 300,
  });
  assert.ok(range.start > 0);

  container.scrollHeight = 36000;
  restoreViewport(container, viewport);
  assert.equal(container.scrollTop, 12000);
});

test('viewport restoration prefers anchors and clamps offset fallback', () => {
  const replacement = {
    dataset: { messageId: 'middle' },
    getBoundingClientRect: () => ({ top: 30, bottom: 130 }),
  };
  let nodes = [replacement];
  const container = {
    scrollTop: 0,
    scrollHeight: 900,
    clientHeight: 700,
    getBoundingClientRect: () => ({ top: 10 }),
    querySelectorAll: () => nodes,
  };

  restoreViewport(container, {
    scrollTop: 12000,
    viewportHeight: 700,
    anchor: { id: 'middle', offset: 5 },
  });
  assert.equal(container.scrollTop, 15);

  nodes = [];
  restoreViewport(container, {
    scrollTop: 12000,
    viewportHeight: 700,
    anchor: { id: 'missing', offset: 0 },
  });
  assert.equal(container.scrollTop, 200);
});

test('a new render session starts with a fresh viewport', () => {
  let queried = false;
  const viewport = captureViewport({
    scrollTop: 12000,
    clientHeight: 700,
    querySelectorAll: () => {
      queried = true;
      return [];
    },
  }, { preserve: false });

  assert.deepEqual(viewport, {
    scrollTop: 0,
    viewportHeight: 700,
    anchor: null,
  });
  assert.equal(queried, false);
});

test('a returning conversation seeds its new render session from a message anchor', () => {
  const viewport = viewportForSavedAnchor({
    messageIds: ['m1', 'm2', 'm3', 'm4'],
    heights: [100, 120, 140, 160],
    anchor: { messageId: 'm3', offset: -18 },
    viewportHeight: 700,
  });

  assert.deepEqual(viewport, {
    scrollTop: 238,
    viewportHeight: 700,
    anchor: { id: 'm3', offset: -18 },
  });
  assert.equal(viewportForSavedAnchor({
    messageIds: ['m1'],
    heights: [100],
    anchor: { messageId: 'missing', offset: 0 },
    viewportHeight: 700,
  }), null);
  assert.equal(viewportForSavedAnchor({
    messageIds: ['m1'],
    heights: [100],
    anchor: { messageId: 'm1', offset: Number.NaN },
    viewportHeight: 700,
  }), null);
});

test('mobile shell owns vertical gestures and uses controlled disclosures', () => {
  assert.match(styleSource, /touch-action:\s*pan-y/);
  assert.match(styleSource, /-webkit-overflow-scrolling:\s*touch/);
  assert.doesNotMatch(appSource, /createElement\(['"]details['"]\)/);
  assert.match(appSource, /setReasoningExpanded/);
  assert.match(appSource, /stopScrolling/);
  assert.match(appSource, /pointerdown/);
  assert.match(appSource, /touchstart/);
});

test('pointer down cancels momentum before release while preserving a new drag', () => {
  assert.match(appSource, /let scrollStopLock = false/);
  assert.match(appSource, /function stopScrolling[\s\S]*?scrollStopLock = true/);
  assert.match(appSource, /function releaseScrollStopLock/);
  assert.match(appSource, /scrollStopLock[\s\S]*?requestAnimationFrame/);
  assert.match(appSource, /touchmove[\s\S]*?releaseScrollStopLock\(\)/);
  assert.match(appSource, /touchend[\s\S]*?releaseScrollStopLock\(\)/);
  assert.match(appSource, /touchcancel[\s\S]*?releaseScrollStopLock\(\)/);
  const touchStart = appSource.indexOf("timeline.addEventListener('touchstart'");
  const touchStartBody = appSource.slice(touchStart, touchStart + 500);
  assert.match(touchStartBody, /touchActive = true[\s\S]*?stopScrolling\('touch'\)/);
});

test('touch jitter below the Flutter slop classifies as hold with guarded lock wiring', () => {
  assert.equal(
    verticalGestureIntent({ startX: 100, startY: 100, currentX: 110, currentY: 110 }),
    'hold',
  );
  assert.equal(
    verticalGestureIntent({ startX: 100, startY: 100, currentX: 100, currentY: 118 }),
    'vertical',
  );
  assert.equal(
    verticalGestureIntent({ startX: 100, startY: 100, currentX: 120, currentY: 101 }),
    'horizontal',
  );
  assert.match(appSource, /let touchStartX = null/);
  assert.match(appSource, /let pointerStartX = null/);
  assert.match(appSource, /verticalGestureIntent\(/);
  assert.match(appSource, /event\.preventDefault\(\)/);
  assert.match(appSource, /touchmove'[\s\S]*?passive: false/);
  assert.match(appSource, /intent === 'hold'[\s\S]*?scrollStopLock/);
  assert.match(appSource, /function stopScrolling[\s\S]*?if \(!scrollStopLock\)/);
  assert.match(appSource, /function restoreScrollStopPosition/);
  assert.match(appSource, /let gestureActive = false/);
  assert.match(appSource, /let gestureIntent = 'idle'/);
  assert.match(appSource, /function stopScrolling[\s\S]*?gestureActive[\s\S]*?gestureIntent/);
  assert.match(appSource, /timeline\.addEventListener\('scroll'[\s\S]*?if \(scrollStopLock\)[\s\S]*?return;/);
});

test('mobile touch calls never arm the persistent lock; origins stay explicit', () => {
  assert.match(appSource, /const isIosTouchDevice/);
  assert.match(appSource, /const isAndroidTouchDevice/);
  assert.match(appSource, /const isTouchNativeOwned = isIosTouchDevice \|\| isAndroidTouchDevice/);
  assert.match(appSource, /function stopScrolling\(origin = 'programmatic'\)/);
  assert.match(appSource, /origin === 'touch'[\s\S]*?isTouchNativeOwned[\s\S]*?return;/);
  assert.match(appSource, /function stopScrolling[\s\S]*?scrollStopLock = true/);
  assert.match(appSource, /stopScrolling\(event\.pointerType === 'touch' \? 'touch' : 'pointer'\)/);
  assert.match(appSource, /if \(!isTouchNativeOwned && event\.cancelable\) event\.preventDefault\(\)/);
  assert.match(appSource, /if \(!isTouchNativeOwned && scrollStopLock && event\.cancelable\)/);
  const touchStart = appSource.indexOf("timeline.addEventListener('touchstart'");
  const touchStartBody = appSource.slice(touchStart, touchStart + 500);
  assert.match(touchStartBody, /stopScrolling\('touch'\)/);
});

test('code blocks use the Flutter surface, header, and code-view structure', () => {
  assert.match(appSource, /code-block-header/);
  assert.match(appSource, /code-block-body/);
  assert.match(appSource, /code-block-toggle/);
  assert.match(appSource, /code-block-action/);
  assert.match(appSource, /code-block-pre/);
  assert.match(styleSource, /\.code-block\s*\{/);
  assert.match(styleSource, /\.code-block-header\s*\{/);
  assert.match(styleSource, /\.code-block-body\s*\{/);
  assert.match(styleSource, /\.code-block-pre\s*\{/);
  assert.match(styleSource, /\.code-block-action[\s\S]*?display: grid/);
  assert.match(styleSource, /\.code-block-action[\s\S]*?border: 0/);
  assert.match(styleSource, /code\.hljs\s*\{/);
  assert.match(styleSource, /body\[data-dark="true"\][\s\S]*?\.hljs-keyword/);
  assert.match(styleSource, /font-size:\s*calc\(13px \* var\(--cuplivo-font-scale\)\)/);
  assert.match(styleSource, /\.hljs-deletion[\s\S]*?background: #ffdddd/);
  assert.match(styleSource, /\.hljs-addition[\s\S]*?background: #ddffdd/);
  assert.match(appSource, /function normalizeCodeLanguage/);
  assert.match(appSource, /language: highlightLanguage/);
  assert.match(appSource, /plaintext/);
  assert.match(styleSource, /\.code-block\.is-collapsed/);
  assert.match(appSource, /source\.replace\(\/\(\?:\\r\\n\|\\r\|\\n\)\+\$\//);
});

test('a fenced Python block mounts without creating a DOM ancestry cycle', () => {
  const root = new TestNode('root');
  const pre = new TestNode('pre');
  const block = new TestNode('block');
  const header = new TestNode('header');
  const body = new TestNode('body');
  root.append(pre);

  mountCodeBlock({ pre, block, header, body });

  assert.deepEqual(root.children, [block]);
  assert.deepEqual(block.children, [header, body]);
  assert.deepEqual(body.children, [pre]);
});

test('bundled Markdown and highlighter accept Python f-strings and Unicode', () => {
  const source = 'def greet(name):\n    print(f"Hello, {name}!")\n\ngreet("世界")';
  const fenced = '```python\n' + source + '\n```';
  const sandbox = {};
  vm.createContext(sandbox);
  vm.runInContext(markedSource, sandbox);
  vm.runInContext(highlightSource, sandbox);

  const html = sandbox.marked.parse(fenced);
  assert.match(html, /<pre><code class="language-python">/);
  assert.match(html, /世界/);
  assert.doesNotThrow(() => sandbox.hljs.highlight(source, {
    language: 'python',
    ignoreIllegals: true,
  }));
});

test('virtual DOM replacement captures scroll state first and applies Flutter insets', () => {
  const captureIndex = appSource.indexOf('captureViewport(timeline');
  const themeIndex = appSource.indexOf('applyTheme();', captureIndex);
  const replaceIndex = appSource.indexOf('timeline.replaceChildren(fragment)');
  assert.ok(captureIndex >= 0 && themeIndex > captureIndex && replaceIndex > themeIndex);
  assert.match(appSource, /document\.createDocumentFragment\(\)/);
  assert.match(appSource, /restoreViewport\(timeline, viewport\)/);
  assert.match(styleSource, /overflow-anchor:\s*none/);
  assert.match(styleSource, /padding-block:\s*var\(--cuplivo-content-top-inset\)\s+var\(--cuplivo-content-bottom-inset\)/);
  assert.match(styleSource, /scroll-padding-block:\s*var\(--cuplivo-content-top-inset\)\s+var\(--cuplivo-content-bottom-inset\)/);
});

test('touch and inertial scrolling defer every virtual DOM replacement', () => {
  assert.match(appSource, /touchstart[\s\S]*?setRenderBlocked\(true\)/);
  assert.match(appSource, /function markUserScroll[\s\S]*?setRenderBlocked\(true\)/);
  assert.match(
    appSource,
    /function finishUserScrollWhenIdle[\s\S]*?touchActive \|\| gestureActive/,
  );
  assert.match(appSource, /messagePatches[\s\S]*?handleMessagePatches\(envelope\)/);
  assert.match(appSource, /function updateMountedStreamingContent/);
  assert.match(appSource, /patchStreamingMarkdownRoot/);
  assert.match(appSource, /function handleMediaResult/);
  assert.doesNotMatch(appSource, /payload\.type === 'mediaResult'[\s\S]{0,300}requestRender\(\)/);
  assert.doesNotMatch(appSource, /messagePatches[^\n]*scheduleRender\(\)/);
  assert.match(appSource, /function handleMeasuredHeights[\s\S]*?stageMeasuredHeight/);
  assert.match(appSource, /function reconcileMeasuredHeights[\s\S]*?commitPendingMeasurements/);
  assert.match(appSource, /createFrameCoalescer\(\s*reconcileMeasuredHeights/);
  const measureStart = appSource.indexOf('function handleMeasuredHeights');
  const measureEnd = appSource.indexOf('function reconcileMeasuredHeights', measureStart);
  assert.doesNotMatch(appSource.slice(measureStart, measureEnd), /requestRender\(\)/);
  assert.doesNotMatch(appSource.slice(measureStart, measureEnd), /heights\.set\(/);
  const reconcileEnd = appSource.indexOf('function renderSafely', measureEnd);
  const reconcile = appSource.slice(measureEnd, reconcileEnd);
  const commitIndex = reconcile.indexOf('commitPendingMeasurements');
  const spacerIndex = reconcile.indexOf('topSpacer.style.height');
  const restoreIndex = reconcile.indexOf('restorePreferredViewport', spacerIndex);
  const coverageIndex = reconcile.indexOf('coverageFor', restoreIndex);
  assert.ok(commitIndex >= 0 && spacerIndex > commitIndex);
  assert.ok(restoreIndex > spacerIndex && coverageIndex > restoreIndex);
});

test('layout interactions cancel stale anchors and delayed renderer redraws stay local', () => {
  assert.match(appSource, /let interactionRevision = 0/);
  assert.match(
    appSource,
    /function cancelInteractionLayout[\s\S]*?interactionRevision \+= 1[\s\S]*?pendingInteractionAnchor = null/,
  );
  assert.match(
    appSource,
    /function markUserScroll[\s\S]*?cancelInteractionLayout\(\)/,
  );
  assert.match(appSource, /if \(userScrolling\) markUserScroll\(false\)/);
  assert.match(
    appSource,
    /function queueInteractionLayoutReconcile[\s\S]*?isCurrentInteraction/,
  );
  const rendererStart = appSource.indexOf('function rerenderWhenRendererReady');
  const rendererEnd = appSource.indexOf('function containsMath', rendererStart);
  const rendererBody = appSource.slice(rendererStart, rendererEnd);
  assert.match(rendererBody, /queueRendererRefresh/);
  assert.doesNotMatch(rendererBody, /updateMountedMessage/);
  const mermaidStart = appSource.indexOf('function commitMermaidRender');
  const mermaidEnd = appSource.indexOf('function flushRendererUpdates', mermaidStart);
  assert.match(appSource.slice(mermaidStart, mermaidEnd), /runViewportMutation/);
});

test('thinking step toggle stays above every step and supports collapse', () => {
  const collapseStart = appSource.indexOf('function applyThinkingStepCollapse');
  const collapseEnd = appSource.indexOf('function renderAskUser', collapseStart);
  const collapseBody = appSource.slice(collapseStart, collapseEnd);
  assert.match(collapseBody, /card\.prepend\(toggle\)/);
  assert.match(collapseBody, /collapseThinkingSteps/);
  assert.match(collapseBody, /aria-expanded/);
  assert.doesNotMatch(collapseBody, /show\.remove\(\)/);
  assert.match(collapseBody, /beginLayoutInteraction\(toggle\)/);
  assert.match(collapseBody, /partitionThinkingSteps\(steps\)/);
  assert.match(
    collapseBody,
    /formatCountTemplate\([\s\S]*?t\('expandThinkingSteps'\)[\s\S]*?collapsibleSteps\.length/,
  );
  assert.doesNotMatch(collapseBody, /message\.expandStepsLabel/);
});

test('thinking collapse counts hidden steps independently for every chain card', () => {
  const firstCard = partitionThinkingSteps(['a', 'b', 'c', 'd', 'e']);
  const secondCard = partitionThinkingSteps(['f', 'g', 'h']);
  const boundaryCard = partitionThinkingSteps(['i', 'j']);

  assert.deepEqual(firstCard.collapsed, ['a', 'b', 'c']);
  assert.deepEqual(firstCard.visible, ['d', 'e']);
  assert.deepEqual(secondCard.collapsed, ['f']);
  assert.deepEqual(secondCard.visible, ['g', 'h']);
  assert.deepEqual(boundaryCard.collapsed, []);
  assert.deepEqual(boundaryCard.visible, ['i', 'j']);
  assert.equal(formatCountTemplate('Show {count} more steps', 3), 'Show 3 more steps');
  assert.equal(formatCountTemplate('展开更多 {count} 步', 1), '展开更多 1 步');
});

test('streaming thinking counts track the current card without a message total', () => {
  const steps = ['reasoning', 'tool-1'];
  assert.equal(partitionThinkingSteps(steps).collapsed.length, 0);
  steps.push('tool-2');
  assert.equal(partitionThinkingSteps(steps).collapsed.length, 1);
  steps.push('tool-3', 'tool-4');
  assert.equal(partitionThinkingSteps(steps).collapsed.length, 3);
  assert.throws(() => formatCountTemplate('Missing placeholder', 1));
});

test('HTML preview stays outside the chat shell and Markdown uses an allowlist', () => {
  const sanitizerStart = appSource.indexOf('function sanitizeMarkdownHtml');
  const sanitizerEnd = appSource.indexOf('function markMarkdownViewportAnchors', sanitizerStart);
  const sanitizer = appSource.slice(sanitizerStart, sanitizerEnd);
  assert.match(sanitizer, /ALLOWED_TAGS/);
  assert.match(sanitizer, /ALLOWED_ATTR/);
  assert.match(sanitizer, /ALLOW_DATA_ATTR:\s*false/);
  assert.match(sanitizer, /SANITIZE_NAMED_PROPS:\s*true/);
  assert.doesNotMatch(sanitizer, /USE_PROFILES/);
  assert.match(appSource, /sendAction\('openHtmlPreview', messageId, \{ source \}\)/);
  assert.doesNotMatch(appSource, /createElement\(['"]iframe['"]\)/);
  assert.doesNotMatch(appSource, /\.srcdoc\s*=/);
  assert.match(htmlSource, /frame-src 'none'/);
});

test('bundled DOMPurify version and official bundle digest stay pinned', () => {
  assert.match(purifySource, /DOMPurify 3\.4\.14/);
  assert.equal(
    createHash('sha256').update(purifySource).digest('hex'),
    'c2f26ea4fc0d88141c9aa430eb515ac86fce59418ceebd85fa475b87a8d6c3e6',
  );
});

test('virtual boundaries show a localized loader and use budgeted detached work', () => {
  assert.match(htmlSource, /id="virtual-window-loader"/);
  assert.match(htmlSource, /id="virtual-window-loader-label"/);
  assert.match(styleSource, /#virtual-window-loader\s*\{/);
  assert.match(appSource, /setVirtualWindowLoading/);
  assert.match(appSource, /buildWithFrameBudget/);
  assert.match(appSource, /coverage\.requested/);
  assert.match(appSource, /virtual_window_timeout/);
});

test('stream patches avoid DOM work for offscreen messages and retain stable blocks', () => {
  const handlerStart = appSource.indexOf('function handleMessagePatches');
  const handlerEnd = appSource.indexOf('function handleMediaResult', handlerStart);
  const handler = appSource.slice(handlerStart, handlerEnd);
  const offscreen = handler.indexOf('!mountedSlots.get(id)?.isConnected');
  const offscreenContinue = handler.indexOf('continue;', offscreen);
  const mountedUpdate = handler.indexOf('updateMountedMessage(id)', offscreen);
  assert.ok(offscreen >= 0 && offscreenContinue > offscreen);
  assert.ok(mountedUpdate > offscreenContinue);
  assert.match(appSource, /longestStablePrefix\(previous\?\.signatures, signatures\)/);
  assert.match(appSource, /streamingMarkdownStates\.set/);
});

test('viewport commands use an atomic render-and-settle transaction', () => {
  const commandStart = appSource.indexOf('function handleViewportCommand');
  const commandBody = appSource.slice(commandStart, commandStart + 2200);
  const prepareIndex = commandBody.indexOf('prepareProgrammaticNavigation()');
  const topIndex = commandBody.indexOf("command === 'top'");
  assert.ok(prepareIndex >= 0 && topIndex > prepareIndex);
  assert.match(appSource, /function prepareProgrammaticNavigation[\s\S]*?releaseScrollStopLock\(\)/);
  assert.match(appSource, /function prepareProgrammaticNavigation[\s\S]*?userScrolling = false/);
  assert.match(appSource, /createViewportNavigationCoordinator\(\{[\s\S]*?setRenderBlocked[\s\S]*?requestRender/);
  assert.match(appSource, /function navigateToEdge[\s\S]*?viewportNavigation\.run/);
  assert.match(appSource, /function navigateToEdge[\s\S]*?navigationEdge = edge/);
  assert.match(appSource, /function navigateToEdge\(edge, \{ hold = false \} = \{\}\)/);
  assert.match(appSource, /if \(!hold && navigationEdge === edge\)[\s\S]*?navigationEdge = null/);
  assert.match(appSource, /command === 'holdBottom'[\s\S]*?navigateToEdge\('bottom', \{ hold: true \}\)/);
  assert.match(appSource, /function navigateToEdge[\s\S]*?beginVirtualWindowLoad/);
  assert.match(
    commandBody,
    /command === 'bottom'[\s\S]*?touchActive \|\| gestureActive \|\| pendingInteractionAnchor[\s\S]*?userScrolling && payload\.force !== true/,
  );
  assert.match(appSource, /function handleMeasuredHeights[\s\S]*?enforceNavigationEdge\(\)/);
  assert.match(appSource, /function scrollToMessage[\s\S]*?viewportNavigation\.run/);
  assert.match(appSource, /function scrollToMessage[\s\S]*?beginVirtualWindowLoad/);
  assert.doesNotMatch(commandBody, /behavior:\s*'smooth'/);
  assert.match(appSource, /type: 'viewportMetrics'[\s\S]*?conversationId: renderedConversationId/);
  assert.match(appSource, /const missingSavedAnchor[\s\S]*?messages\.reduce\(\(sum, message\)/);
  assert.doesNotMatch(appSource, /filter\(\(message\) => message\.role === 'user'\)/);
  assert.match(appSource, /messageIndexAtOffset\(messages\.map\(messageHeight\), timeline\.scrollTop\)/);
});

test('assistant background uses a dedicated fixed layer and Flutter mask gradient', () => {
  assert.match(htmlSource, /id="chat-background"/);
  assert.match(appSource, /const backgroundLayer = document\.getElementById\('chat-background'\)/);
  assert.match(appSource, /backgroundLayer\.style\.backgroundImage/);
  assert.match(styleSource, /#chat-background\s*\{[^}]*position:\s*fixed/);
  assert.match(styleSource, /#chat-background::after\s*\{[^}]*rgba\(0,\s*0,\s*0,\s*\.04\)/);
  assert.match(styleSource, /linear-gradient\([^;]*--cuplivo-background-mask-top[^;]*--cuplivo-background-mask-bottom/);
  assert.match(appSource, /backgroundOwner/);
  assert.match(styleSource, /data-background-owner="flutter"/);
});

test('message composition follows Flutter visual grouping', () => {
  assert.match(appSource, /assistant-text-surface/);
  assert.match(appSource, /chain-card/);
  assert.match(appSource, /attachments/);
  assert.match(appSource, /renderSuggestions/);
  assert.doesNotMatch(appSource, /fragment\.append\(suggestions\)/);
  const messageIndex = appSource.indexOf('slot.append(renderMessage');
  const dividerIndex = appSource.indexOf('slot.append(divider)', messageIndex);
  assert.ok(messageIndex >= 0 && dividerIndex > messageIndex);
  assert.match(styleSource, /\.assistant-text-surface/);
  assert.match(styleSource, /\.chain-card/);
  assert.match(styleSource, /\.attachments/);
  assert.match(appSource, /dataset\.viewportAnchorKey/);
  assert.match(appSource, /markMarkdownViewportAnchors/);
  assert.match(appSource, /type: 'viewportInteraction'/);
  assert.match(appSource, /viewportGroupKey}:code:\$\{codeIndex\}/);
});

test('message toolbar renders bundled Lucide icons instead of text actions', () => {
  assert.match(styleSource, /vendor\/fonts\/lucide\.woff2/);
  assert.match(appSource, /function renderMessageActions/);
  assert.match(appSource, /iconButton\(icon, actionLabel\(action\)/);
  assert.match(appSource, /more:\s*'more'/);
});

test('message surfaces cover Flutter default, frosted, and solid styles', () => {
  assert.match(styleSource, /data-background-style="defaultStyle"/);
  assert.match(styleSource, /data-background-style="frosted"/);
  assert.match(styleSource, /backdrop-filter:\s*blur\(14px\)/);
  assert.match(styleSource, /data-background-style="solid"/);
  assert.match(styleSource, /\.message\.is-user \.bubble\s*\{[^}]*max-width:\s*75%/);
});
