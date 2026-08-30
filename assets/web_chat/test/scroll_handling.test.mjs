import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import {
  ASSET_VERSION,
  PROTOCOL_VERSION,
  buildWithFrameBudget,
  captureAnchor,
  captureInteractionAnchor,
  captureViewport,
  commitPendingMeasurements,
  createAdaptiveStreamPresenter,
  createExpansionCoordinator,
  createFrameCoalescer,
  createRenderCommitCoordinator,
  createRenderGate,
  createVirtualWindowCoordinator,
  createViewportNavigationCoordinator,
  formatCountTemplate,
  formatReasoningElapsed,
  longestStablePrefix,
  mountCodeBlock,
  messageIndexAtOffset,
  normalizeContentInset,
  normalizeMeasuredHeight,
  partitionThinkingSteps,
  receiveTransferChunk,
  reduceEnvelope,
  restoreAnchor,
  restoreInteractionAnchor,
  restoreViewport,
  virtualCoverage,
  virtualOverscan,
  viewportForSavedAnchor,
  verticalGestureIntent,
  visibleRange,
} from '../protocol.mjs';

const rawAppSource = readFileSync(new URL('../app.mjs', import.meta.url), 'utf8');
const appSource = rawAppSource.replace(
  /^import \{[^}]*\}\s*from '\.\/protocol\.mjs';/m,
  '',
);
assert.ok(appSource.length < rawAppSource.length, 'import statement was stripped');

const PROTOCOL_BINDINGS = {
  ASSET_VERSION,
  PROTOCOL_VERSION,
  buildWithFrameBudget,
  captureAnchor,
  captureInteractionAnchor,
  captureViewport,
  commitPendingMeasurements,
  createAdaptiveStreamPresenter,
  createExpansionCoordinator,
  createFrameCoalescer,
  createRenderCommitCoordinator,
  createRenderGate,
  createVirtualWindowCoordinator,
  createViewportNavigationCoordinator,
  formatCountTemplate,
  formatReasoningElapsed,
  longestStablePrefix,
  mountCodeBlock,
  messageIndexAtOffset,
  normalizeContentInset,
  normalizeMeasuredHeight,
  partitionThinkingSteps,
  receiveTransferChunk,
  reduceEnvelope,
  restoreAnchor,
  restoreInteractionAnchor,
  restoreViewport,
  virtualCoverage,
  virtualOverscan,
  viewportForSavedAnchor,
  verticalGestureIntent,
  visibleRange,
};

function makeElementStub() {
  const listeners = new Map();
  return {
    listeners,
    attributes: {},
    style: {},
    dataset: {},
    children: [],
    scrollTop: 0,
    scrollLeft: 0,
    scrollHeight: 10000,
    clientHeight: 700,
    scrollToCalls: [],
    scrollTo(options) {
      if (options && typeof options === 'object') {
        if (Number.isFinite(options.top)) this.scrollTop = options.top;
        if (Number.isFinite(options.left)) this.scrollLeft = options.left;
      }
      this.scrollToCalls.push(options);
    },
    getBoundingClientRect() {
      return {
        top: 0,
        bottom: this.clientHeight,
        height: this.clientHeight,
        left: 0,
        right: 0,
        width: 0,
      };
    },
    setAttribute(name, value) {
      this.attributes[name] = value;
    },
    addEventListener(type, handler, _options) {
      if (!listeners.has(type)) listeners.set(type, []);
      listeners.get(type).push(handler);
    },
    removeEventListener() {},
    replaceChildren() {},
    append() {},
    appendChild() {},
    remove() {},
    querySelectorAll() {
      return [];
    },
    contains() {
      return false;
    },
    classList: {
      add() {},
      remove() {},
      toggle() {},
      contains() {
        return false;
      },
    },
  };
}

function dispatch(el, type, event) {
  for (const handler of (el.listeners.get(type) ?? [])) handler(event);
}

const ANDROID_UA = [
  'Mozilla/5.0 (Linux; Android 13; Pixel 7 Build/TQ3A.230901.001)',
  'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile',
  'Safari/537.36',
].join(' ');
const IOS_UA = [
  'Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X)',
  'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148',
  'Safari/604.1',
].join(' ');
const DESKTOP_UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/117.0.0.0 Safari/537.36';

function makeRaf() {
  let queue = [];
  let nextId = 1;
  return {
    raf(callback) {
      const id = nextId += 1;
      queue.push({ id, callback });
      return id;
    },
    caf(id) {
      queue = queue.filter((entry) => entry.id !== id);
    },
    pump(max = 4) {
      let count = 0;
      while (queue.length > 0 && count < max) {
        const batch = queue;
        queue = [];
        for (const { callback } of batch) callback(performance.now());
        count += 1;
      }
      return count;
    },
    pending() {
      return queue.length;
    },
  };
}

function loadShell({ userAgent, platform, maxTouchPoints }) {
  const raf = makeRaf();
  const messages = [];
  const elements = new Map([
    ['timeline', makeElementStub()],
    ['chat-background', makeElementStub()],
    ['virtual-window-loader', makeElementStub()],
    ['virtual-window-loader-label', makeElementStub()],
  ]);
  const sandbox = {
    window: {
      addEventListener() {},
      CuplivoChat: {
        postMessage(raw) {
          messages.push(JSON.parse(raw));
        },
      },
    },
    document: {
      getElementById: (id) => elements.get(id) ?? makeElementStub(),
      createElement: () => makeElementStub(),
      querySelectorAll: () => [],
      documentElement: {
        style: {},
        setAttribute() {},
        classList: { add() {}, remove() {}, toggle() {} },
        dataset: {},
      },
      body: { style: {}, dataset: {} },
    },
    navigator: { userAgent, platform, maxTouchPoints },
    requestAnimationFrame: raf.raf,
    cancelAnimationFrame: raf.caf,
    performance,
    console,
    setTimeout,
    clearTimeout,
    setInterval,
    clearInterval,
  };
  // protocol.mjs factories default to the browser's requestAnimationFrame in
  // their own module scope; pin them to the sandbox scheduler so the shell
  // clock is deterministic in the harness.
  Object.assign(sandbox, PROTOCOL_BINDINGS, {
    buildWithFrameBudget: (options) =>
      PROTOCOL_BINDINGS.buildWithFrameBudget({ schedule: raf.raf, ...options }),
    createAdaptiveStreamPresenter: (options) =>
      PROTOCOL_BINDINGS.createAdaptiveStreamPresenter({
        schedule: raf.raf,
        ...options,
      }),
    createFrameCoalescer: (callback, schedule = raf.raf) =>
      PROTOCOL_BINDINGS.createFrameCoalescer(callback, schedule),
    createRenderCommitCoordinator: (options) =>
      PROTOCOL_BINDINGS.createRenderCommitCoordinator({
        schedule: raf.raf,
        cancel: raf.caf,
        ...options,
      }),
    createViewportNavigationCoordinator: (options) =>
      PROTOCOL_BINDINGS.createViewportNavigationCoordinator({
        schedule: raf.raf,
        ...options,
      }),
    createVirtualWindowCoordinator: (options) =>
      PROTOCOL_BINDINGS.createVirtualWindowCoordinator({
        schedule: raf.raf,
        ...options,
      }),
  });
  vm.createContext(sandbox);
  vm.runInContext(appSource, sandbox, { filename: 'app.mjs' });
  return {
    sandbox,
    raf,
    messages,
    timeline: elements.get('timeline'),
    dispatch(type, event) {
      dispatch(elements.get('timeline'), type, event);
    },
  };
}

function touchEvent(type, x, y) {
  return {
    type,
    touches: [{ clientX: x, clientY: y }],
    cancelable: true,
    prevented: false,
    preventDefault() {
      this.prevented = true;
    },
  };
}

function pointerEvent(type, pointerType, x, y) {
  return {
    type,
    pointerType,
    clientX: x,
    clientY: y,
    preventDefault() {
      this.prevented = true;
    },
  };
}

function viewportMetricsCount(messages) {
  return messages.filter((message) => message.type === 'viewportMetrics').length;
}

test('Android touch never arms the persistent lock nor prevents touchmove', () => {
  const { raf, messages, timeline, dispatch } = loadShell({
    userAgent: ANDROID_UA,
    platform: 'Linux',
    maxTouchPoints: 5,
  });
  dispatch('touchstart', touchEvent('touchstart', 0, 0));
  const move = touchEvent('touchmove', 5, 5);
  dispatch('touchmove', move);
  assert.equal(move.prevented, false);
  timeline.scrollTop = 500;
  dispatch('scroll', { type: 'scroll' });
  raf.pump(4);
  assert.equal(timeline.scrollToCalls.length, 0);
  assert.ok(viewportMetricsCount(messages) >= 1, 'scroll fell through to metrics');
});

test('iOS touch never arms the persistent lock nor prevents touchmove', () => {
  const { raf, messages, timeline, dispatch } = loadShell({
    userAgent: IOS_UA,
    platform: 'iPhone',
    maxTouchPoints: 5,
  });
  dispatch('touchstart', touchEvent('touchstart', 0, 0));
  const move = touchEvent('touchmove', 5, 5);
  dispatch('touchmove', move);
  assert.equal(move.prevented, false);
  timeline.scrollTop = 500;
  dispatch('scroll', { type: 'scroll' });
  raf.pump(4);
  assert.equal(timeline.scrollToCalls.length, 0);
  assert.ok(viewportMetricsCount(messages) >= 1, 'scroll fell through to metrics');
});

test('desktop pointer still arms the lock and touchmove still cancels', () => {
  const { raf, messages, timeline, dispatch } = loadShell({
    userAgent: DESKTOP_UA,
    platform: 'Win32',
    maxTouchPoints: 0,
  });
  dispatch('pointerdown', pointerEvent('pointerdown', 'mouse', 0, 0));
  dispatch('touchstart', touchEvent('touchstart', 0, 0));
  timeline.scrollTop = 500;
  dispatch('scroll', { type: 'scroll' });
  raf.pump(3);
  assert.ok(timeline.scrollToCalls.length >= 1, 'lock restored the armed position');
  assert.equal(viewportMetricsCount(messages), 0, 'locked scroll never reaches metrics');
  const move = touchEvent('touchmove', 5, 5);
  dispatch('touchmove', move);
  assert.equal(move.prevented, true, 'desktop legacy path still cancels touchmove');
  dispatch('pointerup', pointerEvent('pointerup', 'mouse', 5, 5));
  timeline.scrollTop = 700;
  dispatch('scroll', { type: 'scroll' });
  raf.pump(3);
  assert.ok(viewportMetricsCount(messages) >= 1, 'release lets metrics flow again');
});

test('a programmatically-established lock survives mobile touch and is honored', () => {
  const { raf, messages, timeline, dispatch, sandbox } = loadShell({
    userAgent: ANDROID_UA,
    platform: 'Linux',
    maxTouchPoints: 5,
  });
  sandbox.window.CuplivoWeb.stopScrolling('programmatic');
  timeline.scrollTop = 900;
  dispatch('touchstart', touchEvent('touchstart', 0, 0));
  dispatch('scroll', { type: 'scroll' });
  raf.pump(3);
  assert.ok(timeline.scrollToCalls.length >= 1, 'clamp lock is honored on touch');
  assert.equal(viewportMetricsCount(messages), 0, 'locked scroll never reaches metrics');
  timeline.scrollTop = 400;
  const move = touchEvent('touchmove', 6, 6);
  dispatch('touchmove', move);
  assert.equal(move.prevented, false, 'mobile touch never cancels');
  assert.ok(timeline.scrollToCalls.length >= 2, 'mobile touch keeps restoring the clamp');
  assert.equal(timeline.scrollToCalls.at(-1).top, 0, 'clamp position is the armed offset');
});
