export const PROTOCOL_VERSION = 4;
export const ASSET_VERSION = 'web-chat-v18';

const transfers = new Map();

export function receiveTransferChunk(chunk) {
  if (chunk.protocolVersion !== PROTOCOL_VERSION) {
    throw new Error('protocol_mismatch');
  }
  if (!Number.isInteger(chunk.index) || !Number.isInteger(chunk.total) ||
      chunk.index < 0 || chunk.index >= chunk.total || chunk.total < 1) {
    throw new Error('invalid_transfer_sequence');
  }
  let transfer = transfers.get(chunk.transferId);
  if (!transfer) {
    transfer = { total: chunk.total, chunks: new Array(chunk.total) };
    transfers.set(chunk.transferId, transfer);
  }
  if (transfer.total !== chunk.total) throw new Error('transfer_total_changed');
  if (typeof chunk.data !== 'string') throw new Error('invalid_transfer_data');
  transfer.chunks[chunk.index] = chunk.data;
  for (let index = 0; index < transfer.total; index += 1) {
    if (typeof transfer.chunks[index] !== 'string') return null;
  }
  transfers.delete(chunk.transferId);
  const bytes = [];
  for (const encoded of transfer.chunks) {
    const binary = atob(encoded);
    for (let index = 0; index < binary.length; index += 1) {
      bytes.push(binary.charCodeAt(index));
    }
  }
  return JSON.parse(new TextDecoder().decode(new Uint8Array(bytes)));
}

export function reduceEnvelope(state, envelope) {
  if (envelope.type === 'snapshot') {
    if (envelope.protocolVersion !== PROTOCOL_VERSION ||
        envelope.assetVersion !== ASSET_VERSION) {
      throw new Error('snapshot_version_mismatch');
    }
    if (state && state.renderSessionId === envelope.renderSessionId &&
        Number(envelope.renderRevision) < Number(state.renderRevision)) {
      return state;
    }
    if (state?.renderSessionId === envelope.renderSessionId) {
      const liveById = new Map((state.messages ?? []).map((message) => [message.id, message]));
      return {
        ...envelope,
        media: { ...(state.media ?? {}), ...(envelope.media ?? {}) },
        messages: (envelope.messages ?? []).map((message) => {
          const live = liveById.get(message.id);
          let next = message;
          if (live?.isStreaming && message.isStreaming === true &&
              Number.isInteger(live.streamRevision)) {
            next = {
              ...message,
              content: live.content,
              tokens: live.tokens,
              reasoning: live.reasoning,
              contentSplits: live.contentSplits,
              tools: live.tools,
              translation: live.translation,
              streamRevision: live.streamRevision,
            };
          }
          if (message.translationStreaming === true &&
              live?.patchKind === 'translation' &&
              Number.isInteger(live.streamRevision)) {
            next = {
              ...next,
              patchKind: 'translation',
              translation: live.translation,
              streamRevision: live.streamRevision,
            };
          }
          return next;
        }),
      };
    }
    return envelope;
  }
  if (envelope.type === 'messagePatches') {
    if (!state || envelope.renderSessionId !== state.renderSessionId ||
        envelope.conversationId !== state.conversationId) return state;
    const byId = new Map(envelope.patches.map((patch) => [patch.id, patch]));
    return {
      ...state,
      messages: state.messages.map((message) => {
        const patch = byId.get(message.id);
        if (!patch) return message;
        const revision = patch.streamRevision;
        const currentRevision = message.streamRevision;
        if (Number.isInteger(revision) && message.isStreaming !== true &&
            patch.isStreaming === true) return message;
        if (Number.isInteger(revision) && Number.isInteger(currentRevision) &&
            revision <= currentRevision) return message;
        return { ...message, ...patch };
      }),
    };
  }
  return state;
}

export function visibleRange({ heights, scrollTop, viewportHeight, overscan = 700 }) {
  const lower = Math.max(0, scrollTop - overscan);
  const upper = scrollTop + viewportHeight + overscan;
  let offset = 0;
  let start = 0;
  while (start < heights.length && offset + heights[start] < lower) {
    offset += heights[start];
    start += 1;
  }
  let end = start;
  let cursor = offset;
  while (end < heights.length && cursor < upper) {
    cursor += heights[end];
    end += 1;
  }
  return { start, end, top: offset, bottom: heights.slice(end).reduce((a, b) => a + b, 0) };
}

export function virtualOverscan(viewportHeight) {
  const viewport = Number(viewportHeight);
  return Math.max(2400, Number.isFinite(viewport) && viewport > 0 ? viewport * 3 : 0);
}

export function virtualCoverage({
  heights,
  range,
  scrollTop,
  viewportHeight,
  leadingInset = 0,
  trailingInset = 0,
}) {
  const values = Array.isArray(heights) ? heights.map((value) => {
    const height = Number(value);
    return Number.isFinite(height) && height > 0 ? height : 170;
  }) : [];
  const viewport = Math.max(0, Number(viewportHeight) || 0);
  const leading = normalizeContentInset(leadingInset, 0);
  const trailing = normalizeContentInset(trailingInset, 0);
  const start = Math.max(0, Math.min(values.length, Number(range?.start) || 0));
  const end = Math.max(start, Math.min(values.length, Number(range?.end) || 0));
  const renderedTop = leading + values.slice(0, start).reduce((sum, value) => sum + value, 0);
  const renderedBottom = leading + values.slice(0, end).reduce((sum, value) => sum + value, 0);
  const total = leading + trailing + values.reduce((sum, value) => sum + value, 0);
  const maxExtent = Math.max(0, total - viewport);
  const min = start === 0 ? 0 : Math.min(maxExtent, renderedTop);
  const max = end === values.length
    ? maxExtent
    : Math.max(min, Math.min(maxExtent, renderedBottom - viewport));
  const requested = Math.max(0, Math.min(maxExtent, Number(scrollTop) || 0));
  const clamped = Math.max(min, Math.min(max, requested));
  return {
    covered: requested >= min - 1 && requested <= max + 1,
    requested,
    maxExtent,
    min,
    max,
    clamped,
  };
}

export function createVirtualWindowCoordinator({
  schedule = requestAnimationFrame,
  setLoading,
  clamp,
  renderTarget,
  settleTarget,
  onError = null,
  timeoutMs = 2500,
}) {
  let revision = 0;
  let active = false;
  let framePending = false;
  let rendering = false;
  let latest = null;
  const timeout = Number.isFinite(Number(timeoutMs)) && Number(timeoutMs) > 0
    ? Number(timeoutMs)
    : 0;

  const scheduleLatest = () => {
    if (!active || framePending || rendering || latest == null) return;
    framePending = true;
    schedule(() => {
      framePending = false;
      if (!active || latest == null) {
        scheduleLatest();
        return;
      }
      const request = latest;
      rendering = true;
      let timeoutId = null;
      let task;
      try {
        task = Promise.resolve(renderTarget(request.target, request.revision));
      } catch (error) {
        task = Promise.reject(error);
      }
      const guarded = timeout === 0 ? task : Promise.race([
        task,
        new Promise((_, reject) => {
          timeoutId = setTimeout(
            () => reject(new Error('virtual_window_timeout')),
            timeout,
          );
        }),
      ]);
      guarded.then(() => {
        if (timeoutId != null) clearTimeout(timeoutId);
        rendering = false;
        if (!active || request.revision !== revision) {
          scheduleLatest();
          return;
        }
        schedule(() => {
          if (!active || request.revision !== revision) {
            scheduleLatest();
            return;
          }
          try {
            settleTarget(request.hold, request.revision, request.target);
            request.onSettled?.(request.hold, request.revision, request.target);
            active = false;
            latest = null;
            setLoading(false);
          } catch (error) {
            active = false;
            latest = null;
            setLoading(false);
            onError?.(error);
          }
        });
      }).catch((error) => {
        if (timeoutId != null) clearTimeout(timeoutId);
        rendering = false;
        if (!active || request.revision !== revision) {
          scheduleLatest();
          return;
        }
        active = false;
        latest = null;
        setLoading(false);
        onError?.(error);
      });
    });
  };

  return {
    request({ target, hold = target, onSettled = null }) {
      const nextTarget = Math.max(0, Number(target) || 0);
      const nextHold = Math.max(0, Number(hold) || 0);
      const wasActive = active;
      active = true;
      const requestRevision = ++revision;
      latest = {
        target: nextTarget,
        hold: nextHold,
        revision: requestRevision,
        onSettled,
      };
      if (!wasActive) setLoading(true);
      clamp(nextHold);
      scheduleLatest();
      return requestRevision;
    },

    cancel() {
      revision += 1;
      latest = null;
      if (!active) return;
      active = false;
      setLoading(false);
    },

    isCurrent(requestRevision) {
      return active && requestRevision === revision;
    },
    get active() { return active; },
    get target() { return latest?.target ?? null; },
  };
}

export function buildWithFrameBudget({
  items,
  build,
  schedule = requestAnimationFrame,
  now = () => performance.now(),
  budgetMs = 6,
  shouldContinue = () => true,
}) {
  const source = Array.isArray(items) ? items : [];
  const budget = Number.isFinite(Number(budgetMs)) && Number(budgetMs) > 0
    ? Number(budgetMs)
    : 6;
  return new Promise((resolve, reject) => {
    const results = [];
    let index = 0;
    const runFrame = () => {
      if (!shouldContinue()) {
        reject(new Error('virtual_window_stale'));
        return;
      }
      const startedAt = now();
      let built = 0;
      try {
        while (index < source.length) {
          results.push(build(source[index], index));
          index += 1;
          built += 1;
          if (built > 0 && now() - startedAt >= budget) break;
        }
      } catch (error) {
        reject(error);
        return;
      }
      if (index >= source.length) {
        resolve(results);
      } else {
        schedule(runFrame);
      }
    };
    schedule(runFrame);
  });
}

export function longestStablePrefix(previous, next) {
  const before = Array.isArray(previous) ? previous : [];
  const after = Array.isArray(next) ? next : [];
  let index = 0;
  while (index < before.length && index < after.length &&
      before[index] === after[index]) {
    index += 1;
  }
  return index;
}

export function safeUtf16SliceEnd(text, requestedEnd) {
  const source = String(text ?? '');
  let end = Math.max(0, Math.min(source.length, Math.trunc(Number(requestedEnd) || 0)));
  if (end > 0 && end < source.length) {
    const previous = source.charCodeAt(end - 1);
    const next = source.charCodeAt(end);
    if (previous >= 0xD800 && previous <= 0xDBFF &&
        next >= 0xDC00 && next <= 0xDFFF) end += 1;
  }
  return end;
}

export function createAdaptiveStreamPresenter({
  schedule = requestAnimationFrame,
  now = () => performance.now(),
  commit,
  frameInterval = 32,
  maxLag = 96,
}) {
  const entries = new Map();
  let scheduled = false;

  const scheduleFrame = () => {
    if (scheduled || entries.size === 0) return;
    scheduled = true;
    schedule(runFrame);
  };

  const runFrame = (timestamp) => {
    scheduled = false;
    const currentTime = Number.isFinite(Number(timestamp)) ? Number(timestamp) : now();
    for (const [id, entry] of entries) {
      if (currentTime - entry.lastCommit < frameInterval) continue;
      const backlog = entry.target.length - entry.displayed.length;
      if (backlog <= 0) {
        entries.delete(id);
        continue;
      }
      const remaining = Math.max(1, entry.deadline - currentTime);
      const framesLeft = Math.max(1, Math.ceil(remaining / frameInterval));
      const requestedEnd = entry.displayed.length + Math.ceil(backlog / framesLeft);
      const end = safeUtf16SliceEnd(entry.target, requestedEnd);
      entry.displayed = entry.target.slice(0, end);
      entry.lastCommit = currentTime;
      commit(id, entry.displayed);
      if (entry.displayed === entry.target) entries.delete(id);
    }
    scheduleFrame();
  };

  return {
    update({ id, displayed = '', target = '', final = false }) {
      const key = String(id ?? '');
      if (!key) return;
      const nextTarget = String(target ?? '');
      let entry = entries.get(key);
      const current = entry?.displayed ?? String(displayed ?? '');
      if (final || !nextTarget.startsWith(current)) {
        entries.delete(key);
        commit(key, nextTarget);
        return;
      }
      if (nextTarget === current) return;
      const currentTime = now();
      entry ??= {
        displayed: current,
        target: nextTarget,
        deadline: currentTime + maxLag,
        lastCommit: currentTime - frameInterval,
      };
      entry.target = nextTarget;
      entries.set(key, entry);
      scheduleFrame();
    },

    cancel(id) { entries.delete(String(id ?? '')); },
    clear() { entries.clear(); },
    get pending() { return entries.size; },
  };
}

export function messageIndexAtOffset(heights, scrollTop, fallbackHeight = 170) {
  if (!Array.isArray(heights) || heights.length === 0) return -1;
  const target = Number.isFinite(Number(scrollTop))
    ? Math.max(0, Number(scrollTop))
    : 0;
  const fallback = Number.isFinite(Number(fallbackHeight)) && Number(fallbackHeight) > 0
    ? Number(fallbackHeight)
    : 170;
  let offset = 0;
  for (let index = 0; index < heights.length; index += 1) {
    const rawHeight = Number(heights[index]);
    const height = Number.isFinite(rawHeight) && rawHeight > 0 ? rawHeight : fallback;
    if (target < offset + height) return index;
    offset += height;
  }
  return heights.length - 1;
}

export function normalizeContentInset(value, fallback = 8) {
  return typeof value === 'number' && Number.isFinite(value) && value >= 0
    ? value
    : fallback;
}

export function partitionThinkingSteps(steps, retainedCount = 2) {
  const retained = Number.isInteger(retainedCount) && retainedCount >= 0
    ? retainedCount
    : 2;
  const hiddenCount = Math.max(0, steps.length - retained);
  return {
    collapsed: steps.slice(0, hiddenCount),
    visible: steps.slice(hiddenCount),
  };
}

export function formatCountTemplate(template, count) {
  if (!Number.isInteger(count) || count < 0) {
    throw new Error('invalid_count_template_value');
  }
  const source = String(template ?? '');
  if (!source.includes('{count}')) {
    throw new Error('count_template_placeholder_missing');
  }
  return source.split('{count}').join(String(count));
}

export function normalizeMeasuredHeight(value) {
  const height = Number(value);
  return Number.isFinite(height) && height > 0 ? Math.ceil(height) : null;
}

export function commitPendingMeasurements(committed, pending) {
  if (!(committed instanceof Map) || !(pending instanceof Map)) return false;
  let changed = false;
  for (const [id, rawHeight] of pending) {
    const height = normalizeMeasuredHeight(rawHeight);
    if (height == null || committed.get(id) === height) continue;
    committed.set(id, height);
    changed = true;
  }
  pending.clear();
  return changed;
}

export function verticalGestureIntent({
  startX,
  startY,
  currentX,
  currentY,
  slop = 18,
}) {
  const dx = Number(currentX) - Number(startX);
  const dy = Number(currentY) - Number(startY);
  const threshold = Number.isFinite(Number(slop)) && Number(slop) > 0
    ? Number(slop)
    : 18;
  if (![dx, dy].every(Number.isFinite) || Math.hypot(dx, dy) < threshold) {
    return 'hold';
  }
  return Math.abs(dy) >= Math.abs(dx) ? 'vertical' : 'horizontal';
}

export function mountCodeBlock({ pre, block, header, body }) {
  pre.replaceWith(block);
  body.append(pre);
  block.append(header, body);
}

export function formatReasoningElapsed(startAt, finishedAt, loading, now = Date.now()) {
  const start = parseTimestamp(startAt);
  if (!Number.isFinite(start)) return '';
  const finished = parseTimestamp(finishedAt);
  const end = Number.isFinite(finished)
    ? finished
    : loading
      ? Number(now)
      : start;
  if (!Number.isFinite(end)) return '';
  return `(${(Math.max(0, end - start) / 1000).toFixed(1)}s)`;
}

function parseTimestamp(value) {
  if (typeof value === 'number') return Number.isFinite(value) ? value : NaN;
  if (typeof value !== 'string' || value.length === 0) return NaN;
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) ? parsed : NaN;
}

export function createExpansionCoordinator() {
  const entries = new Map();
  const requests = new Map();

  function reconcile(key, authoritative) {
    const value = Boolean(authoritative);
    const entry = entries.get(key);
    if (!entry) return null;
    entry.authoritative = value;
    if (entry.inFlight == null && entry.awaitingTarget === value) {
      entry.desired = value;
      entry.awaitingTarget = null;
    }
    if (entry.inFlight == null && entry.awaitingTarget == null &&
        entry.desired === entry.authoritative) {
      entries.delete(key);
      return null;
    }
    return entry;
  }

  function dispatch(entry) {
    const target = entry.desired;
    const requestId = entry.dispatch(target);
    if (typeof requestId !== 'string' || requestId.length === 0) {
      throw new Error('invalid_expansion_request');
    }
    entry.inFlight = { requestId, target };
    requests.set(requestId, entry.key);
  }

  return {
    value(key, authoritative) {
      const entry = reconcile(key, authoritative);
      return entry?.desired ?? Boolean(authoritative);
    },

    toggle({ key, authoritative, dispatch: send }) {
      let entry = reconcile(key, authoritative);
      if (!entry) {
        entry = {
          key,
          authoritative: Boolean(authoritative),
          desired: Boolean(authoritative),
          awaitingTarget: null,
          inFlight: null,
          dispatch: send,
        };
        entries.set(key, entry);
      } else {
        entry.dispatch = send;
      }
      entry.desired = !entry.desired;
      if (entry.awaitingTarget != null) entry.awaitingTarget = null;
      if (entry.inFlight == null) dispatch(entry);
      return entry.desired;
    },

    resolve(requestId, ok) {
      const key = requests.get(requestId);
      if (!key) return false;
      requests.delete(requestId);
      const entry = entries.get(key);
      if (!entry || entry.inFlight?.requestId !== requestId) return false;
      const completedTarget = entry.inFlight.target;
      entry.inFlight = null;
      if (!ok) {
        entry.desired = entry.authoritative;
        entry.awaitingTarget = null;
        entries.delete(key);
        return true;
      }
      if (entry.desired !== completedTarget) {
        dispatch(entry);
      } else if (entry.authoritative === completedTarget) {
        entries.delete(key);
      } else {
        entry.awaitingTarget = completedTarget;
      }
      return true;
    },

    clear() {
      entries.clear();
      requests.clear();
    },

    isPending(key) {
      const entry = entries.get(key);
      return entry?.inFlight != null || entry?.awaitingTarget != null;
    },
  };
}

function messageSlots(container) {
  return [...container.querySelectorAll('[data-message-slot="true"]')];
}

export function captureAnchor(container, { granular = true } = {}) {
  const top = container.getBoundingClientRect().top;
  const bottom = top + Number(container.clientHeight ?? 0);
  if (granular) {
    for (const node of container.querySelectorAll('[data-viewport-anchor-key]')) {
      const rect = node.getBoundingClientRect();
      // Descendants of collapsed chain steps remain queryable, but Chromium
      // reports a zero-sized rectangle for them. Treating one as visible
      // installs an anchor that suddenly becomes real when the step expands.
      if (rect.bottom <= rect.top) continue;
      if (rect.bottom < top || rect.top > bottom) continue;
      const message = node.closest?.('[data-message-slot="true"]');
      const id = message?.dataset?.messageId;
      const key = node.dataset?.viewportAnchorKey;
      if (id && key) {
        return {
          id,
          key,
          offset: rect.top - top,
          messageOffset: message.getBoundingClientRect().top - top,
        };
      }
    }
  }
  for (const node of messageSlots(container)) {
    const rect = node.getBoundingClientRect();
    if (rect.bottom >= top) {
      return { id: node.dataset.messageId, offset: rect.top - top };
    }
  }
  return null;
}

export function restoreAnchor(container, anchor) {
  if (!anchor) return false;
  const message = messageSlots(container)
    .find((item) => item.dataset.messageId === anchor.id);
  if (!message) return false;
  const granular = anchor.key == null
    ? null
    : [...message.querySelectorAll('[data-viewport-anchor-key]')]
      .find((item) => item.dataset?.viewportAnchorKey === anchor.key);
  const node = granular ?? message;
  const offset = granular == null && anchor.key != null
    ? Number(anchor.messageOffset)
    : Number(anchor.offset);
  if (!Number.isFinite(offset)) return false;
  const top = container.getBoundingClientRect().top;
  container.scrollTop += node.getBoundingClientRect().top - top - offset;
  return true;
}

export function captureInteractionAnchor(container, element) {
  const message = element?.closest?.('[data-message-slot="true"]') ??
    element?.closest?.('[data-message-id]');
  const disclosure = element?.closest?.('[data-expansion-key]');
  const messageId = message?.dataset?.messageId;
  const expansionKey = disclosure?.dataset?.expansionKey;
  if (!messageId || !expansionKey) return null;
  const containerTop = Number(container?.getBoundingClientRect?.().top);
  const elementTop = Number(element?.getBoundingClientRect?.().top);
  if (!Number.isFinite(containerTop) || !Number.isFinite(elementTop)) return null;
  return {
    messageId,
    expansionKey,
    offset: elementTop - containerTop,
  };
}

export function restoreInteractionAnchor(container, anchor) {
  if (!anchor) return false;
  const message = messageSlots(container)
    .find((node) => node.dataset?.messageId === anchor.messageId);
  const disclosure = [...(message?.querySelectorAll?.('[data-expansion-key]') ?? [])]
    .find((node) => node.dataset?.expansionKey === anchor.expansionKey);
  const element = disclosure?.querySelector?.('[data-interaction-anchor="true"]') ??
    disclosure?.querySelector?.('.disclosure-header');
  if (!element) return false;
  const containerTop = Number(container.getBoundingClientRect().top);
  const elementTop = Number(element.getBoundingClientRect().top);
  const offset = Number(anchor.offset);
  if (![containerTop, elementTop, offset].every(Number.isFinite)) return false;
  container.scrollTop += elementTop - containerTop - offset;
  return true;
}

export function captureViewport(container, { preserve = true } = {}) {
  const viewportHeight = normalizeContentInset(container.clientHeight, 0);
  if (!preserve) {
    return { scrollTop: 0, viewportHeight, anchor: null };
  }
  const rawScrollTop = Number(container.scrollTop);
  return {
    scrollTop: Number.isFinite(rawScrollTop) ? Math.max(0, rawScrollTop) : 0,
    viewportHeight,
    anchor: captureAnchor(container),
  };
}

export function restoreViewport(container, viewport) {
  if (!viewport || restoreAnchor(container, viewport.anchor)) return;
  const rawScrollTop = Number(viewport.scrollTop);
  const rawScrollHeight = Number(container.scrollHeight);
  const rawClientHeight = Number(container.clientHeight);
  const scrollTop = Number.isFinite(rawScrollTop)
    ? Math.max(0, rawScrollTop)
    : 0;
  const scrollHeight = Number.isFinite(rawScrollHeight)
    ? Math.max(0, rawScrollHeight)
    : 0;
  const clientHeight = Number.isFinite(rawClientHeight)
    ? Math.max(0, rawClientHeight)
    : 0;
  container.scrollTop = Math.min(scrollTop, Math.max(0, scrollHeight - clientHeight));
}

export function viewportForSavedAnchor({
  messageIds,
  heights,
  anchor,
  viewportHeight,
}) {
  const messageId = anchor?.messageId;
  const offset = Number(anchor?.offset);
  if (typeof messageId !== 'string' || messageId.length === 0 ||
      !Number.isFinite(offset) || !Array.isArray(messageIds) ||
      !Array.isArray(heights) || messageIds.length !== heights.length) {
    return null;
  }
  const index = messageIds.indexOf(messageId);
  if (index < 0) return null;
  const scrollTop = heights.slice(0, index).reduce((sum, value) => {
    const height = Number(value);
    return sum + (Number.isFinite(height) && height > 0 ? height : 0);
  }, 0) - offset;
  return {
    scrollTop: Math.max(0, scrollTop),
    viewportHeight: normalizeContentInset(viewportHeight, 0),
    anchor: { id: messageId, offset },
  };
}

export function createFrameCoalescer(callback, schedule = requestAnimationFrame) {
  let pending = false;
  return () => {
    if (pending) return;
    pending = true;
    schedule(() => {
      pending = false;
      callback();
    });
  };
}

export function createRenderCommitCoordinator({
  schedule = requestAnimationFrame,
  cancel = cancelAnimationFrame,
  commit,
}) {
  let frame = 0;
  let pendingKey = null;
  let pendingIdentity = null;
  let committedKey = null;

  const identityKey = (identity) => [
    identity?.renderSessionId ?? '',
    identity?.conversationId ?? '',
    Number(identity?.renderRevision),
  ].join('\u0000');

  return {
    request(identity) {
      const key = identityKey(identity);
      if (key === pendingKey || key === committedKey) return false;
      if (frame) cancel(frame);
      pendingKey = key;
      pendingIdentity = { ...identity };
      frame = schedule(() => {
        frame = 0;
        const currentKey = pendingKey;
        const currentIdentity = pendingIdentity;
        pendingKey = null;
        pendingIdentity = null;
        committedKey = currentKey;
        commit(currentIdentity);
      });
      return true;
    },

    clear() {
      if (frame) cancel(frame);
      frame = 0;
      pendingKey = null;
      pendingIdentity = null;
      committedKey = null;
    },

    get pending() { return pendingIdentity != null; },
  };
}

export function createRenderGate(dispatch) {
  let blocked = false;
  let pending = false;
  return {
    request() {
      if (blocked) {
        pending = true;
        return;
      }
      dispatch();
    },

    setBlocked(value) {
      const next = Boolean(value);
      if (blocked === next) return;
      blocked = next;
      if (!blocked && pending) {
        pending = false;
        dispatch();
      }
    },

    get blocked() { return blocked; },
    get pending() { return pending; },
  };
}

export function createViewportNavigationCoordinator({
  schedule = requestAnimationFrame,
  setRenderBlocked,
  requestRender,
  settleFrames = 3,
}) {
  let revision = 0;
  let active = false;
  const frameCount = Number.isInteger(settleFrames) && settleFrames > 0
    ? settleFrames
    : 3;

  return {
    run(settle, onComplete = null) {
      const request = ++revision;
      active = true;
      setRenderBlocked(true);
      requestRender();
      // Flush exactly one destination render, then keep incidental measurement
      // and snapshot renders deferred until the target has settled.
      setRenderBlocked(false);
      setRenderBlocked(true);
      let remaining = frameCount;
      const settleNextFrame = () => {
        if (request !== revision) return;
        settle();
        remaining -= 1;
        if (remaining > 0) {
          schedule(settleNextFrame);
          return;
        }
        setRenderBlocked(false);
        requestRender();
        schedule(() => {
          if (request !== revision) return;
          settle();
          active = false;
          onComplete?.();
        });
      };
      schedule(settleNextFrame);
      return request;
    },

    cancel() {
      revision += 1;
      if (!active) return;
      active = false;
      setRenderBlocked(false);
    },
  };
}
