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
  createFontFaceRegistrator,
  createFontFaceTracker,
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
  normalizeMeasuredHeight,
  normalizeContentInset,
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
} from './protocol.mjs';

const timeline = document.getElementById('timeline');
const backgroundLayer = document.getElementById('chat-background');
const virtualWindowLoader = document.getElementById('virtual-window-loader');
const virtualWindowLoaderLabel = document.getElementById('virtual-window-loader-label');
const PRINT_MODE = new URL(document.location.href).searchParams.get('mode') === 'print';
if (PRINT_MODE) document.body.classList.add('print-mode');
const maxHtmlPreviewCodeUnits = 1024 * 1024;
let state = null;
let requestSequence = 0;
const heights = new Map();
const pendingMeasuredHeights = new Map();
const pendingActions = new Map();
const pendingMedia = new Set();
const fontFaceTracker = createFontFaceTracker();
const fontRegistrator = createFontFaceRegistrator(fontFaceTracker);
const localExpansions = new Map();
const mountedSlots = new Map();
const presentedStreamContent = new Map();
const pendingMountedUpdates = new Set();
const markdownHtmlCache = new Map();
const streamingMarkdownStates = new WeakMap();
const staticMarkdownStates = new WeakMap();
const streamStructureSignatureCache = new WeakMap();
const expansionCoordinator = createExpansionCoordinator();
const disclosureAnimations = new WeakMap();
let resizeObserver = null;
let userScrolling = false;
let userScrollTimer = null;
let renderedRange = { start: -1, end: -1 };
let topSpacer = null;
let bottomSpacer = null;
let touchStartX = null;
let touchStartY = null;
let touchActive = false;
let pointerStartX = null;
let pointerStartY = null;
// Mobile touch devices own panning inside the platform WebView. On iOS,
// preventDefault() during the early touchmoves makes WebKit classify the
// gesture as non-scrolling so the page can never be dragged afterwards; on
// Android, Flutter's gesture arena dispatches the native touch stream only
// after the vertical recognizer wins, so arming the persistent lock from
// touch fights the live Chromium pan and reads as a "jelly" kick. Only
// touch-origin stopScrolling calls ('touch') are exempt on mobile
// touch devices; programmatic/pointer/bridge calls keep locking.
const isIosTouchDevice = /iP(hone|od|ad)/.test(navigator.userAgent) ||
  (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
const isAndroidTouchDevice = /Android/i.test(navigator.userAgent);
const isTouchNativeOwned = isIosTouchDevice || isAndroidTouchDevice;
let scrollStopLock = false;
let scrollStopFrame = 0;
let scrollStopTop = 0;
let scrollStopLeft = 0;
let gestureActive = false;
let gestureIntent = 'idle';
let renderedSessionId = null;
let renderedConversationId = null;
let reasoningElapsedTimer = null;
let navigationCursorId = null;
let navigationEdge = null;
let forcedViewport = null;
let virtualPrefetchFrame = 0;
let virtualPrefetchTarget = null;
let virtualPrefetchActive = false;
let virtualPrefetchRevision = 0;
let virtualPruneTimer = null;
let virtualWindowLoading = false;
let lastTimelineScrollTop = 0;
let programmaticNavigationActive = false;
let measuredHeightsPending = false;
let pendingInteractionAnchor = null;
let interactionMeasureFrame = 0;
let interactionRevision = 0;
let interactionExpiryTimer = null;
let bottomHoldTimer = null;
let initialBottomPin = false;
const rendererLoads = new Map();
const readyRenderers = new Set();
const pendingRendererRenders = new Map();
const pendingRendererRefreshes = new Map();
const pendingMermaidCommits = new Map();
let rendererRefreshFrame = 0;

const bridge = {
  post(message) {
    const encoded = JSON.stringify(message);
    if (window.chrome?.webview) window.chrome.webview.postMessage(encoded);
    else window.CuplivoChat?.postMessage(encoded);
  },
};
const renderCommitCoordinator = createRenderCommitCoordinator({
  commit: (identity) => {
    if (!state || state.renderSessionId !== identity.renderSessionId ||
        state.conversationId !== identity.conversationId ||
        state.renderRevision !== identity.renderRevision) return;
    bridge.post({
      type: 'renderCommitted',
      renderSessionId: identity.renderSessionId,
      conversationId: identity.conversationId,
      renderRevision: identity.renderRevision,
      capabilityToken: state.capabilityToken,
    });
  },
});
const safeProtocolDiagnostics = new Set([
  'protocol_mismatch',
  'invalid_transfer_sequence',
  'transfer_total_changed',
  'invalid_transfer_data',
  'snapshot_version_mismatch',
  'invalid_expansion_request',
]);
const transparentRemoteImage =
  'data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==';

function safeDiagnosticCode(error, fallback) {
  return safeProtocolDiagnostics.has(error?.message) ? error.message : fallback;
}

function t(key) { return state?.strings?.[key] ?? ''; }
function messageHeight(message) { return heights.get(message.id) ?? 170; }
function isMediaHandle(value) {
  return value?.startsWith('local:') || value?.startsWith('asset:') ||
    value?.startsWith('remote:');
}

function remoteImagePlaceholder(handle) {
  return `${transparentRemoteImage}#cuplivo-remote=${encodeURIComponent(handle)}`;
}

function remoteHandleFromPlaceholder(source) {
  const marker = '#cuplivo-remote=';
  const index = String(source ?? '').indexOf(marker);
  if (index < 0) return null;
  try {
    const handle = decodeURIComponent(String(source).slice(index + marker.length));
    return handle.startsWith('remote:') ? handle : null;
  } catch {
    return null;
  }
}

function markdownSourceForRender(content) {
  const replace = (match, prefix, url) => {
    const handle = state?.remoteMediaHandles?.[url];
    return handle ? `${prefix}${remoteImagePlaceholder(handle)}` : match;
  };
  return String(content ?? '')
    .replace(/(!\[[^\]]*\]\(\s*<?)(http:\/\/[^\s>)]+)/gi, replace)
    .replace(/(<img\b[^>]*\bsrc\s*=\s*["'])(http:\/\/[^"']+)/gi, replace);
}

function rendererAssetUrl(relativePath) {
  return new URL(relativePath, document.baseURI).toString();
}

function reportRendererResourceFailure(renderer) {
  bridge.post({
    type: 'diagnostic',
    code: 'renderer_resource_failed',
    renderer,
  });
}

function loadScriptOnce(key, relativePath) {
  const existing = rendererLoads.get(key);
  if (existing) return existing;
  const promise = new Promise((resolve, reject) => {
    const script = document.createElement('script');
    script.src = rendererAssetUrl(relativePath);
    script.async = true;
    script.addEventListener('load', resolve, { once: true });
    script.addEventListener('error', () => reject(new Error(key)), { once: true });
    document.head.append(script);
  });
  rendererLoads.set(key, promise);
  return promise;
}

function loadStyleOnce(key, relativePath) {
  const existing = rendererLoads.get(key);
  if (existing) return existing;
  const promise = new Promise((resolve, reject) => {
    const link = document.createElement('link');
    link.rel = 'stylesheet';
    link.href = rendererAssetUrl(relativePath);
    link.addEventListener('load', resolve, { once: true });
    link.addEventListener('error', () => reject(new Error(key)), { once: true });
    const appStyles = document.querySelector('link[href="styles.css"]');
    if (appStyles) appStyles.before(link);
    else document.head.append(link);
  });
  rendererLoads.set(key, promise);
  return promise;
}

function rendererPromise(renderer, load) {
  const key = `renderer:${renderer}`;
  const existing = rendererLoads.get(key);
  if (existing) return existing;
  const promise = load().catch((error) => {
    reportRendererResourceFailure(renderer);
    throw error;
  });
  rendererLoads.set(key, promise);
  return promise;
}

function ensureHighlightRenderer() {
  return rendererPromise('highlight', async () => {
    await Promise.all([
      loadStyleOnce('style:highlight', 'vendor/github.min.css'),
      loadScriptOnce('script:highlight', 'vendor/highlight.min.js'),
    ]);
    if (!window.hljs) throw new Error('highlight_unavailable');
    readyRenderers.add('highlight');
  });
}

function ensureMathRenderer() {
  return rendererPromise('math', async () => {
    await Promise.all([
      loadStyleOnce('style:katex', 'vendor/katex.min.css'),
      loadScriptOnce('script:katex', 'vendor/katex.min.js'),
    ]);
    await loadScriptOnce('script:katex-auto-render', 'vendor/auto-render.min.js');
    if (!window.renderMathInElement) throw new Error('math_unavailable');
    readyRenderers.add('math');
  });
}

function ensureMermaidRenderer() {
  return rendererPromise('mermaid', async () => {
    const isWindowsCache = new URL(document.location.href).searchParams.get('platform') === 'windows';
    await loadScriptOnce(
      'script:mermaid',
      isWindowsCache ? 'mermaid.min.js' : '../mermaid.min.js',
    );
    if (!window.mermaid) throw new Error('mermaid_unavailable');
    readyRenderers.add('mermaid');
  });
}

function rerenderWhenRendererReady(renderer, promise, root) {
  const metadata = staticMarkdownStates.get(root);
  const key = `${renderer}:${metadata?.renderSessionId ?? 'session'}:` +
    `${metadata?.messageId ?? 'timeline'}:${metadata?.anchorKey ?? 'root'}`;
  if (pendingRendererRenders.has(key)) {
    pendingRendererRenders.set(key, root);
    return;
  }
  pendingRendererRenders.set(key, root);
  promise.then(() => {
    const latestRoot = pendingRendererRenders.get(key);
    pendingRendererRenders.delete(key);
    if (latestRoot) queueRendererRefresh(latestRoot);
  }, () => pendingRendererRenders.delete(key));
}

function rendererUpdatesBlocked() {
  return touchActive || userScrolling || virtualWindowLoading;
}

function scheduleRendererUpdateFlush() {
  if (rendererRefreshFrame || rendererUpdatesBlocked()) return;
  rendererRefreshFrame = requestAnimationFrame(() => {
    rendererRefreshFrame = 0;
    flushRendererUpdates();
  });
}

function queueRendererRefresh(root) {
  const metadata = staticMarkdownStates.get(root);
  if (!metadata) return;
  pendingRendererRefreshes.set(root, metadata);
  scheduleRendererUpdateFlush();
}

function runViewportMutation(messageId, mutate) {
  const viewport = captureViewport(timeline);
  mutate();
  restorePreferredViewport(viewport);
  const slot = mountedSlots.get(messageId);
  if (slot?.isConnected) {
    stageMeasuredHeight(messageId, slot.getBoundingClientRect().height);
    scheduleMeasuredHeightReconcile();
  }
  sendViewportMetrics();
}

function refreshStaticMarkdownRoot(root, metadata) {
  if (!root.isConnected || metadata.renderSessionId !== state?.renderSessionId) {
    return false;
  }
  const replacement = markdownNode(
    metadata.source,
    false,
    metadata.kind,
    metadata.messageId,
    metadata.anchorKey,
  );
  if (root.dataset.contentBlockKey) {
    replacement.dataset.contentBlockKey = root.dataset.contentBlockKey;
  }
  runViewportMutation(metadata.messageId, () => root.replaceWith(replacement));
  return true;
}

function commitMermaidRender(pre, wrapper, messageId, renderSessionId) {
  if (!pre.isConnected || renderSessionId !== state?.renderSessionId) return false;
  if (pre.dataset.viewportAnchorKey) {
    wrapper.dataset.viewportAnchorKey = pre.dataset.viewportAnchorKey;
  }
  runViewportMutation(messageId, () => pre.replaceWith(wrapper));
  return true;
}

function flushRendererUpdates() {
  if (rendererUpdatesBlocked()) return;
  for (const [root, metadata] of pendingRendererRefreshes) {
    if (metadata.renderSessionId !== state?.renderSessionId) {
      pendingRendererRefreshes.delete(root);
      continue;
    }
    if (!root.isConnected) {
      pendingRendererRefreshes.delete(root);
      continue;
    }
    pendingRendererRefreshes.delete(root);
    refreshStaticMarkdownRoot(root, metadata);
  }
  for (const [pre, pending] of pendingMermaidCommits) {
    if (pending.renderSessionId !== state?.renderSessionId) {
      pendingMermaidCommits.delete(pre);
      continue;
    }
    if (!pre.isConnected) {
      pendingMermaidCommits.delete(pre);
      continue;
    }
    pendingMermaidCommits.delete(pre);
    commitMermaidRender(
      pre,
      pending.wrapper,
      pending.messageId,
      pending.renderSessionId,
    );
  }
}

function containsMath(root) {
  const text = [];
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  let node;
  while ((node = walker.nextNode())) {
    if (!node.parentElement?.closest('code, pre')) text.push(node.textContent ?? '');
  }
  const source = text.join('\n');
  if (/\$\$[\s\S]*?\$\$|\\\[[\s\S]*?\\\]|\\\([\s\S]*?\\\)/.test(source)) return true;
  return state.display?.dollarMath === true && /(^|[^\\$])\$[^\n$]+\$/.test(source);
}

const appearanceSurfaces = {
  userBubble: 'user',
  assistantBubble: 'assistant',
  processCard: 'process',
};
const appearanceFields = {
  backgroundColor: { suffix: 'background', kind: 'color' },
  textColor: { suffix: 'text', kind: 'color' },
  accentColor: { suffix: 'accent', kind: 'color', processOnly: true },
  borderColor: { suffix: 'border-color', kind: 'color' },
  borderWidth: { suffix: 'border-width', kind: 'number', min: 0, max: 4, unit: 'px' },
  cornerRadius: { suffix: 'corner-radius', kind: 'number', min: 0, max: 48, unit: 'px' },
  paddingHorizontal: { suffix: 'padding-x', kind: 'number', min: 0, max: 32, unit: 'px' },
  paddingVertical: { suffix: 'padding-y', kind: 'number', min: 0, max: 32, unit: 'px' },
  shadowElevation: { suffix: 'shadow', kind: 'shadow', min: 0, max: 24 },
  maxWidthPercent: { suffix: 'max-width', kind: 'number', min: 40, max: 100, unit: '%', bubbleOnly: true },
};

function appearanceDataKey(surface, suffix) {
  return `style${surface[0].toUpperCase()}${surface.slice(1)}${suffix
    .split('-')
    .map((part) => `${part[0].toUpperCase()}${part.slice(1)}`)
    .join('')}`;
}

function appearanceCssValue(spec, value) {
  if (spec.kind === 'color') {
    return typeof value === 'string' && /^#[0-9a-f]{6}(?:[0-9a-f]{2})?$/i.test(value)
      ? value
      : null;
  }
  if (typeof value !== 'number' || !Number.isFinite(value) ||
      value < spec.min || value > spec.max) return null;
  if (spec.kind === 'shadow') {
    if (value === 0) return 'none';
    const y = Number((value * 0.5).toFixed(2));
    const blur = Number((value * 1.5).toFixed(2));
    const alpha = Number(Math.min(0.28, 0.08 + value * 0.008).toFixed(3));
    return `0 ${y}px ${blur}px rgba(0, 0, 0, ${alpha})`;
  }
  return `${value}${spec.unit}`;
}

function applyAppearance() {
  const rootStyle = document.documentElement.style;
  let applied = false;
  for (const [snapshotSurface, cssSurface] of Object.entries(appearanceSurfaces)) {
    const surface = state?.appearance?.[snapshotSurface];
    for (const [field, spec] of Object.entries(appearanceFields)) {
      const variable = `--cuplivo-style-${cssSurface}-${spec.suffix}`;
      const dataKey = appearanceDataKey(cssSurface, spec.suffix);
      rootStyle.removeProperty(variable);
      delete document.body.dataset[dataKey];
      if (!surface || typeof surface !== 'object' || Array.isArray(surface)) continue;
      if (spec.processOnly && snapshotSurface !== 'processCard') continue;
      if (spec.bubbleOnly && snapshotSurface === 'processCard') continue;
      const cssValue = appearanceCssValue(spec, surface[field]);
      if (cssValue == null) continue;
      rootStyle.setProperty(variable, cssValue);
      document.body.dataset[dataKey] = 'true';
      applied = true;
    }
  }
  document.body.dataset.customAppearance = String(applied);
}

function applyTheme() {
  if (!state) return;
  document.documentElement.lang = state.locale || 'en';
  document.documentElement.dir = state.textDirection === 'rtl' ? 'rtl' : 'ltr';
  for (const [name, value] of Object.entries(state.theme ?? {})) {
    document.documentElement.style.setProperty(`--cuplivo-${name}`, value);
  }
  document.documentElement.style.setProperty('--cuplivo-font-scale', String(state.fontScale ?? 1));
  const insets = state.display?.contentInsets ?? {};
  document.documentElement.style.setProperty(
    '--cuplivo-content-top-inset',
    `${normalizeContentInset(insets.top)}px`,
  );
  document.documentElement.style.setProperty(
    '--cuplivo-content-bottom-inset',
    `${normalizeContentInset(insets.bottom)}px`,
  );
  document.body.dataset.backgroundStyle = state.display?.backgroundStyle ?? 'defaultStyle';
  document.body.dataset.dark = String(Boolean(state.display?.isDark));
  const backgroundOwner = state.display?.backgroundOwner === 'flutter'
    ? 'flutter'
    : 'web';
  document.body.dataset.backgroundOwner = backgroundOwner;
  timeline.setAttribute('aria-label', t('timeline'));
  const background = state.assistant?.background;
  const source = state.media?.[background] ?? background ?? '';
  const isColor = source.startsWith('#');
  const isImage = /^(data:|https?:)/i.test(source);
  if (backgroundOwner === 'web') {
    backgroundLayer.style.backgroundColor = isColor ? source : 'transparent';
    backgroundLayer.style.backgroundImage = isImage
      ? `url("${source.replaceAll('"', '%22')}")`
      : 'none';
    document.body.dataset.hasBackground = String(isColor || isImage);
    if (isMediaHandle(background) && !state.media?.[background]) requestMedia(background);
  } else {
    backgroundLayer.style.backgroundColor = 'transparent';
    backgroundLayer.style.backgroundImage = 'none';
    document.body.dataset.hasBackground = 'false';
  }
  applyAppearance();
  applyFonts();
}

// Must match WebChatFontFace.appFaceFamily / codeFaceFamily in
// lib/features/home/webview/web_chat_snapshot.dart; the print contract test
// keeps the two sides in sync.
const FACE_FAMILIES = ['Cuplivo WebApp Font', 'Cuplivo WebCode Font'];

function applyFonts() {
  if (!state) return;
  applyFontFamily(
    '--cuplivo-app-font',
    state.display?.appFont,
    '--cuplivo-default-app-font',
    FACE_FAMILIES[0],
  );
  applyFontFamily(
    '--cuplivo-code-font',
    state.display?.codeFont,
    '--cuplivo-default-code-font',
    FACE_FAMILIES[1],
  );
}

function applyFontFamily(variable, font, chainVariable, faceFamily) {
  if (!font?.family) {
    fontFaceTracker.expect(null, faceFamily);
    document.documentElement.style.removeProperty(variable);
    return;
  }
  if (font.handle) {
    fontFaceTracker.expect(font.handle, font.family);
    const outcome = fontFaceTracker.begin(
      font.handle,
      font.family,
      state.media?.[font.handle],
    );
    if (!outcome.tracked) {
      if (outcome.cached) {
        registerFontFaces(font.handle, [font.family], state.media[font.handle]);
      } else {
        requestMedia(font.handle);
      }
    }
  } else {
    fontFaceTracker.expect(null, faceFamily);
  }
  document.documentElement.style.setProperty(
    variable,
    `'${font.family}', var(${chainVariable})`,
  );
}

function registerFontFaces(handle, families, dataUrl) {
  fontRegistrator.register({
    fonts: document.fonts,
    load: (family, url) => new FontFace(family, `url("${url}")`).load(),
    handle,
    families,
    dataUrl,
  });
}

function sendAction(action, messageId = null, payload = {}) {
  if (!state) return null;
  if ((action === 'loadMoreBefore' || action === 'loadMoreAfter') &&
      [...pendingActions.values()].includes(action)) return null;
  const requestId = `${state.renderSessionId}:${Date.now()}:${requestSequence += 1}`;
  pendingActions.set(requestId, action);
  bridge.post({
    type: 'action', requestId, action, messageId, payload,
    protocolVersion: PROTOCOL_VERSION,
    renderSessionId: state.renderSessionId,
    conversationId: state.conversationId,
    actionEpoch: state.actionEpoch,
    capabilityToken: state.capabilityToken,
  });
  return requestId;
}

function requestMedia(handle) {
  if (!state || !isMediaHandle(handle) || pendingMedia.has(handle)) return;
  pendingMedia.add(handle);
  bridge.post({
    type: 'mediaRequest', handle,
    renderSessionId: state.renderSessionId,
    conversationId: state.conversationId,
    capabilityToken: state.capabilityToken,
  });
}

function actionLabel(action) {
  if (action === 'speak' && state?.display?.ttsActive === true) return t('stop');
  return t({
    copy: 'copy', edit: 'edit', resend: 'resend', regenerate: 'regenerate',
    quote: 'quote', translate: 'translate', speak: 'speak', share: 'share',
    fork: 'fork', select: 'select', delete: 'delete', multiAI: 'multiAI',
    more: 'more',
  }[action]);
}

const iconCodepoints = Object.freeze({
  copy: 57502,
  more: 57526,
  regenerate: 57669,
  speak: 57771,
  stop: 57475,
  translate: 57598,
  edit: 57849,
  resend: 57669,
  previous: 57454,
  next: 57455,
  bot: 57787,
  user: 57759,
  reasoning: 58310,
  tool: 57777,
  sparkle: 58386,
});

function iconNode(name, className = 'lucide-icon') {
  const node = document.createElement('span');
  node.className = className;
  node.setAttribute('aria-hidden', 'true');
  node.textContent = String.fromCodePoint(iconCodepoints[name] ?? iconCodepoints.sparkle);
  return node;
}

function iconButton(name, label, onClick, className = 'icon-action') {
  const node = button(label, onClick, className);
  node.title = label;
  node.replaceChildren(iconNode(name));
  return node;
}

function button(label, onClick, className = 'action') {
  const node = document.createElement('button');
  node.type = 'button';
  node.className = className;
  node.textContent = label;
  node.setAttribute('aria-label', label);
  node.addEventListener('click', onClick);
  return node;
}

function localExpansion(key, defaultValue) {
  if (!localExpansions.has(key)) {
    localExpansions.set(key, Boolean(defaultValue));
  }
  return localExpansions.get(key);
}

function updateDisclosure(root, header, body, expanded, onLayoutSettled = null) {
  const previous = header.getAttribute('aria-expanded') === 'true';
  root.classList.toggle('is-expanded', expanded);
  header.setAttribute('aria-expanded', String(expanded));
  disclosureAnimations.get(body)?.cancel();
  if (!root.isConnected || previous === expanded) {
    body.hidden = !expanded;
    onLayoutSettled?.();
    return;
  }
  body.hidden = false;
  if (typeof body.animate !== 'function' ||
      window.matchMedia?.('(prefers-reduced-motion: reduce)')?.matches) {
    body.hidden = !expanded;
    onLayoutSettled?.();
    return;
  }
  const animation = body.animate(
    expanded
      ? [{ opacity: 0, transform: 'translateY(-4px)' }, { opacity: 1, transform: 'translateY(0)' }]
      : [{ opacity: 1, transform: 'translateY(0)' }, { opacity: 0, transform: 'translateY(-4px)' }],
    { duration: 180, easing: 'ease-out' },
  );
  disclosureAnimations.set(body, animation);
  animation.finished.then(() => {
    if (disclosureAnimations.get(body) !== animation) return;
    disclosureAnimations.delete(body);
    body.hidden = header.getAttribute('aria-expanded') !== 'true';
    onLayoutSettled?.();
  }).catch((error) => {
    if (error?.name !== 'AbortError') {
      bridge.post({ type: 'diagnostic', code: 'disclosure_animation_failed' });
    }
  });
}

function disclosure({
  key,
  label,
  body,
  expanded,
  className,
  icon = null,
  detailNode = null,
  onToggle,
}) {
  const root = document.createElement('section');
  root.className = `disclosure ${className}`;
  root.dataset.expansionKey = key;
  const header = button(label, () => {
    const previous = header.getAttribute('aria-expanded') === 'true';
    const interactionAnchor = beginLayoutInteraction(header);
    try {
      const requested = !previous;
      const resolved = onToggle?.(requested) ?? requested;
      updateInteractionControl(
        interactionAnchor,
        expansionCoordinator.isPending(key),
      );
      const layoutSettled = () => queueInteractionLayoutReconcile(
        interactionAnchor,
        true,
      );
      updateDisclosure(
        root,
        header,
        body,
        Boolean(resolved),
        layoutSettled,
      );
      queueInteractionLayoutReconcile(interactionAnchor);
    } catch (error) {
      const rollbackSettled = () => queueInteractionLayoutReconcile(
        interactionAnchor,
        true,
      );
      updateDisclosure(root, header, body, previous, rollbackSettled);
      queueInteractionLayoutReconcile(interactionAnchor);
      bridge.post({
        type: 'diagnostic',
        code: safeDiagnosticCode(error, 'disclosure_toggle_failed'),
      });
    }
  }, 'disclosure-header');
  header.dataset.interactionAnchor = 'true';
  header.dataset.viewportAnchorKey = `${key}:header`;
  const title = document.createElement('span');
  title.className = 'disclosure-title';
  title.textContent = label;
  const leading = icon ? iconNode(icon, 'disclosure-icon') : null;
  const chevron = iconNode('next', 'disclosure-chevron');
  header.replaceChildren(...[leading, title, detailNode, chevron].filter(Boolean));
  root.append(header, body);
  updateDisclosure(root, header, body, Boolean(expanded));
  return root;
}

function stableTextKey(prefix, source) {
  let hash = 2166136261;
  for (let index = 0; index < source.length; index += 1) {
    hash ^= source.charCodeAt(index);
    hash = Math.imul(hash, 16777619);
  }
  return `${prefix}:${(hash >>> 0).toString(16)}`;
}

function sanitizeMarkdownHtml(html) {
  return window.DOMPurify.sanitize(html, {
    ALLOWED_TAGS: [
      'a', 'abbr', 'b', 'blockquote', 'br', 'code', 'del', 'details', 'div',
      'em', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'hr', 'i', 'img', 'kbd',
      'li', 'mark', 'ol', 'p', 'pre', 's', 'small', 'span', 'strong', 'sub',
      'summary', 'sup', 'table', 'tbody', 'td', 'th', 'thead', 'tr', 'u', 'ul',
    ],
    ALLOWED_ATTR: [
      'alt', 'class', 'colspan', 'dir', 'height', 'href', 'lang', 'loading',
      'referrerpolicy', 'rel', 'rowspan', 'scope', 'src', 'start', 'target',
      'title', 'width',
    ],
    ALLOW_ARIA_ATTR: false,
    ALLOW_DATA_ATTR: false,
    FORBID_TAGS: [
      'style', 'form', 'object', 'embed', 'iframe', 'script', 'template',
      'textarea', 'title', 'xmp', 'noembed', 'noframes', 'noscript',
    ],
    FORBID_ATTR: ['style', 'srcset'],
    SANITIZE_NAMED_PROPS: true,
  });
}

function markMarkdownViewportAnchors(root, anchorKey) {
  if (!anchorKey) return;
  const children = [...root.children];
  if (children.length === 0) {
    root.dataset.viewportAnchorKey = `${anchorKey}:root`;
    return;
  }
  delete root.dataset.viewportAnchorKey;
  for (const [index, child] of children.entries()) {
    child.dataset.viewportAnchorKey = `${anchorKey}:block:${index}`;
  }
}

function patchStreamingMarkdownRoot(root, source, kind) {
  const markdownEnabled = kind === 'user' ? state.display?.userMarkdown !== false :
    kind === 'reasoning' ? state.display?.reasoningMarkdown !== false :
    state.display?.assistantMarkdown !== false;
  if (!markdownEnabled) {
    streamingMarkdownStates.delete(root);
    root.textContent = source;
    root.style.whiteSpace = 'pre-wrap';
    return;
  }
  const renderSource = markdownSourceForRender(source);
  const tokens = window.marked.lexer(renderSource, { gfm: true, breaks: true });
  const signatures = tokens.map((token) => `${token.type}\u0000${token.raw ?? ''}`);
  const previous = streamingMarkdownStates.get(root);
  const prefix = longestStablePrefix(previous?.signatures, signatures);
  for (const group of previous?.groups.slice(prefix) ?? []) {
    for (const node of group) node.remove();
  }
  const groups = previous?.groups.slice(0, prefix) ?? [];
  const fragment = document.createDocumentFragment();
  for (let index = prefix; index < tokens.length; index += 1) {
    const container = document.createElement('div');
    container.dataset.viewportGroupKey =
      `${root.dataset.viewportGroupKey}:token:${index}`;
    container.innerHTML = sanitizeMarkdownHtml(
      window.marked.parser([tokens[index]], { gfm: true, breaks: true }),
    );
    enhanceMarkdown(container, true, root.dataset.messageId || null);
    const nodes = [...container.childNodes];
    fragment.append(...nodes);
    groups.push(nodes);
  }
  root.append(fragment);
  markMarkdownViewportAnchors(root, root.dataset.viewportGroupKey);
  streamingMarkdownStates.set(root, {
    signatures,
    groups,
    source: renderSource,
    kind,
  });
}

function markdownNode(
  content,
  streaming = false,
  kind = 'assistant',
  messageId = null,
  anchorKey = null,
) {
  const root = document.createElement('div');
  root.className = 'markdown';
  if (messageId) root.dataset.messageId = messageId;
  const source = content ?? '';
  const resolvedAnchorKey = anchorKey ??
    `${messageId ?? 'timeline'}:${stableTextKey(`markdown:${kind}`, source)}`;
  root.dataset.viewportGroupKey = resolvedAnchorKey;
  const markdownEnabled = kind === 'user' ? state.display?.userMarkdown !== false :
    kind === 'reasoning' ? state.display?.reasoningMarkdown !== false :
    state.display?.assistantMarkdown !== false;
  if (!markdownEnabled) {
    root.textContent = source;
    root.style.whiteSpace = 'pre-wrap';
    markMarkdownViewportAnchors(root, resolvedAnchorKey);
    return root;
  }
  try {
    if (streaming) {
      patchStreamingMarkdownRoot(root, source, kind);
      return root;
    }
    const cacheKey = !streaming && source.length <= 64 * 1024
      ? stableTextKey(`markdown:${kind}`, source)
      : null;
    const cached = cacheKey == null ? null : markdownHtmlCache.get(cacheKey);
    let sanitized = cached?.source === source ? cached.html : null;
    if (sanitized == null) {
      const html = window.marked.parse(markdownSourceForRender(source), {
        gfm: true,
        breaks: true,
      });
      sanitized = sanitizeMarkdownHtml(html);
      if (cacheKey != null) {
        markdownHtmlCache.set(cacheKey, { source, html: sanitized });
        if (markdownHtmlCache.size > 64) {
          markdownHtmlCache.delete(markdownHtmlCache.keys().next().value);
        }
      }
    } else {
      markdownHtmlCache.delete(cacheKey);
      markdownHtmlCache.set(cacheKey, cached);
    }
    root.innerHTML = sanitized;
    staticMarkdownStates.set(root, {
      source,
      kind,
      messageId,
      anchorKey: resolvedAnchorKey,
      renderSessionId: state?.renderSessionId,
    });
    enhanceMarkdown(root, streaming, messageId);
    markMarkdownViewportAnchors(root, resolvedAnchorKey);
  } catch (error) {
    bridge.post({ type: 'diagnostic', code: 'markdown_block_failed' });
    root.className = 'block-error';
    root.textContent = t('unsupportedBlock');
    markMarkdownViewportAnchors(root, resolvedAnchorKey);
  }
  return root;
}

function normalizeCodeLanguage(language) {
  const normalized = language.trim().toLowerCase();
  return ({
    js: 'javascript',
    ts: 'typescript',
    sh: 'bash',
    zsh: 'bash',
    shell: 'bash',
    yml: 'yaml',
    py: 'python',
    rb: 'ruby',
    rs: 'rust',
    kt: 'kotlin',
    'c++': 'cpp',
    'c#': 'csharp',
    md: 'markdown',
    text: 'plaintext',
    txt: 'plaintext',
    plain: 'plaintext',
    plaintext: 'plaintext',
  }[normalized] ?? normalized) || 'plaintext';
}

function enhanceMarkdown(root, streaming, messageId = null) {
  enhanceRawCitations(root, messageId);
  for (const link of root.querySelectorAll('a[href]')) {
    const href = link.getAttribute('href');
    const citation = parseCitationLink(link.textContent, href);
    link.removeAttribute('href');
    link.setAttribute('role', citation ? 'button' : 'link');
    link.tabIndex = 0;
    const open = (event) => {
      event.preventDefault();
      if (citation && messageId) {
        sendAction('openCitation', messageId, {
          citationId: citation.id,
          index: citation.index,
        });
        return;
      }
      bridge.post({
        type: 'externalLink',
        url: href,
        renderSessionId: state.renderSessionId,
        conversationId: state.conversationId,
        capabilityToken: state.capabilityToken,
      });
    };
    if (citation) {
      link.className = 'citation-marker';
      link.textContent = citation.index;
      link.setAttribute('aria-label', `${t('sources')} ${citation.index}`.trim());
    }
    link.addEventListener('click', open);
    link.addEventListener('keydown', (event) => { if (event.key === 'Enter') open(event); });
  }
  for (const image of root.querySelectorAll('img')) {
    image.referrerPolicy = 'no-referrer';
    const source = image.getAttribute('src') ?? '';
    const handle = state.remoteMediaHandles?.[source] ??
      remoteHandleFromPlaceholder(source);
    if (handle) image.dataset.mediaHandle = handle;
    const resolved = handle ? state.media?.[handle] : null;
    if (resolved) {
      image.src = resolved;
    } else if (/^http:\/\//i.test(source)) {
      image.removeAttribute('src');
      if (handle) requestMedia(handle);
      else bridge.post({ type: 'diagnostic', code: 'http_media_handle_missing' });
    } else if (handle && remoteHandleFromPlaceholder(source)) {
      requestMedia(handle);
    }
    if (handle && messageId) {
      image.tabIndex = 0;
      image.setAttribute('role', 'button');
      const preview = (event) => {
        event?.preventDefault();
        event?.stopPropagation();
        sendAction('previewImage', messageId, { handle });
      };
      image.addEventListener('click', preview);
      image.addEventListener('keydown', (event) => {
        if (event.key === 'Enter' || event.key === ' ') {
          preview(event);
        }
      });
    }
  }
  for (const [codeIndex, code] of [...root.querySelectorAll('pre > code')].entries()) {
    const language = [...code.classList].find((name) => name.startsWith('language-'))?.slice(9) ?? '';
    const highlightLanguage = normalizeCodeLanguage(language);
    const pre = code.parentElement;
    const source = code.textContent ?? '';
    const expansionKey = `${root.dataset.viewportGroupKey}:code:${codeIndex}`;
    if (highlightLanguage === 'mermaid' && !streaming) {
      if (readyRenderers.has('mermaid')) {
        renderMermaid(pre, source, messageId);
      } else {
        code.textContent = source.replace(/(?:\r\n|\r|\n)+$/, '');
        renderCodeBlock(pre, code, language, source, expansionKey);
        rerenderWhenRendererReady('mermaid', ensureMermaidRenderer(), root);
      }
      continue;
    }
    if (highlightLanguage === 'html' && !streaming) {
      addHtmlPreview(
        pre,
        code.textContent ?? '',
        `${expansionKey}:preview`,
        messageId,
      );
    }
    const displaySource = source.replace(/(?:\r\n|\r|\n)+$/, '');
    if (!streaming && !readyRenderers.has('highlight')) {
      code.textContent = displaySource;
      renderCodeBlock(pre, code, language, source, expansionKey);
      rerenderWhenRendererReady('highlight', ensureHighlightRenderer(), root);
      continue;
    }
    code.classList.add('hljs');
    if (streaming) {
      code.textContent = displaySource;
    } else {
      try {
        code.innerHTML = window.hljs.highlight(displaySource, {
          language: highlightLanguage,
          ignoreIllegals: true,
        }).value;
      } catch {
        code.textContent = displaySource;
        bridge.post({ type: 'diagnostic', code: 'highlight_block_failed' });
      }
    }
    renderCodeBlock(pre, code, language, source, expansionKey);
  }
  try {
    if (streaming || state.display?.math === false || !containsMath(root)) return;
    if (!readyRenderers.has('math')) {
      rerenderWhenRendererReady('math', ensureMathRenderer(), root);
      return;
    }
    window.renderMathInElement(root, {
      throwOnError: false,
      delimiters: [
        { left: '$$', right: '$$', display: true },
        ...(state.display?.dollarMath === true ? [{ left: '$', right: '$', display: false }] : []),
        { left: '\\[', right: '\\]', display: true },
        { left: '\\(', right: '\\)', display: false },
      ],
    });
  } catch { bridge.post({ type: 'diagnostic', code: 'math_block_failed' }); }
}

function enhanceRawCitations(root, messageId) {
  if (!messageId) return;
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  const textNodes = [];
  while (walker.nextNode()) {
    const node = walker.currentNode;
    if (!node.parentElement?.closest('code, pre, a, button')) textNodes.push(node);
  }
  const pattern = /\[citation:([^\]\r\n]+)\]/gi;
  for (const node of textNodes) {
    const source = node.textContent ?? '';
    const fragment = document.createDocumentFragment();
    let cursor = 0;
    let replaced = false;
    for (const match of source.matchAll(pattern)) {
      const references = String(match[1]).split(',')
        .map((part) => parseCitationReference(part.trim()));
      if (!references.length || references.some((reference) => reference == null)) continue;
      fragment.append(document.createTextNode(source.slice(cursor, match.index)));
      for (const [index, reference] of references.entries()) {
        if (index > 0) fragment.append(document.createTextNode(' '));
        fragment.append(citationMarker(reference, messageId));
      }
      cursor = match.index + match[0].length;
      replaced = true;
    }
    if (!replaced) continue;
    fragment.append(document.createTextNode(source.slice(cursor)));
    node.replaceWith(fragment);
  }
}

function citationMarker(reference, messageId) {
  const marker = document.createElement('button');
  marker.type = 'button';
  marker.className = 'citation-marker';
  marker.textContent = reference.index;
  marker.setAttribute('aria-label', `${t('sources')} ${reference.index}`.trim());
  marker.addEventListener('click', () => sendAction('openCitation', messageId, {
    citationId: reference.id,
    index: reference.index,
  }));
  return marker;
}

function parseCitationReference(raw) {
  let value = String(raw ?? '').trim();
  if (value.toLowerCase().startsWith('citation:')) value = value.slice(9).trim();
  if (!value || /[\s\]\)]/.test(value)) return null;
  const separator = value.indexOf(':');
  const index = (separator < 0 ? value : value.slice(0, separator)).trim();
  const id = (separator < 0 ? index : value.slice(separator + 1)).trim();
  if (!/^[A-Za-z0-9_-]+$/.test(index) ||
      (separator >= 0 && !/\d/.test(index)) || !id) return null;
  return { index, id };
}

function parseCitationLink(label, href) {
  const rawHref = String(href ?? '');
  const prefix = '#cuplivo-citation=';
  if (rawHref.startsWith(prefix)) {
    try {
      return parseCitationReference(decodeURIComponent(rawHref.slice(prefix.length)));
    } catch {
      return null;
    }
  }
  if (String(label ?? '').trim().toLowerCase() !== 'citation') return null;
  return parseCitationReference(rawHref);
}

function renderCodeBlock(pre, code, language, source, expansionKey) {
  const displaySource = code.textContent ?? '';
  const threshold = Number(state.display?.collapsedCodeLines ?? 0);
  const lineCount = (displaySource.match(/\n/g)?.length ?? 0) + 1;
  const collapsible = threshold > 0 && lineCount > threshold;
  const block = document.createElement('section');
  block.className = 'code-block';
  block.dataset.component = 'code-block';
  block.dataset.expansionKey = expansionKey;
  block.classList.toggle('is-wrapped', state.display?.wrapCode === true);
  if (collapsible) block.style.setProperty('--collapsed-lines', String(threshold));

  const header = document.createElement('div');
  header.className = 'code-block-header';
  const toggle = document.createElement('button');
  toggle.type = 'button';
  toggle.className = 'code-block-toggle';
  toggle.dataset.interactionAnchor = 'true';
  toggle.dataset.viewportAnchorKey = `${expansionKey}:header`;
  toggle.setAttribute('aria-label', collapsible ? t('expandCode') : t('code'));
  toggle.setAttribute('aria-expanded', String(!collapsible));
  const languageLabel = document.createElement('span');
  languageLabel.className = 'code-block-language';
  languageLabel.textContent = language.trim() || t('code');
  const chevron = iconNode('next', 'code-block-chevron');
  chevron.hidden = true;
  toggle.append(languageLabel, chevron);

  const copy = iconButton(
    'copy',
    t('copyCode'),
    () => sendAction('copyText', null, { text: source }),
    'code-block-action',
  );
  header.append(toggle, copy);

  const body = document.createElement('div');
  body.className = 'code-block-body';
  pre.className = 'code-block-pre';
  mountCodeBlock({ pre, block, header, body });

  const applyCodeExpansion = (expanded) => {
    block.classList.toggle('is-collapsed', !expanded);
    toggle.setAttribute('aria-expanded', String(expanded));
    toggle.setAttribute('aria-label', expanded ? t('collapseCode') : t('expandCode'));
    chevron.hidden = expanded;
  };
  if (collapsible) {
    toggle.addEventListener('click', () => {
      const interactionAnchor = beginLayoutInteraction(toggle);
      const expanded = !localExpansion(expansionKey, false);
      localExpansions.set(expansionKey, expanded);
      applyCodeExpansion(expanded);
      queueInteractionLayoutReconcile(interactionAnchor, true);
    });
    applyCodeExpansion(localExpansion(expansionKey, false));
  }
}

async function renderMermaid(pre, source, messageId) {
  const renderSessionId = state?.renderSessionId;
  try {
    window.mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', theme: 'default' });
    const { svg } = await window.mermaid.render(`m-${Date.now()}-${requestSequence += 1}`, source);
    const wrapper = document.createElement('div');
    wrapper.innerHTML = window.DOMPurify.sanitize(svg, {
      USE_PROFILES: { svg: true, svgFilters: true },
      FORBID_TAGS: ['style', 'foreignObject', 'script'],
    });
    if (rendererUpdatesBlocked() || !pre.isConnected) {
      pendingMermaidCommits.set(pre, {
        wrapper,
        messageId,
        renderSessionId,
      });
      scheduleRendererUpdateFlush();
      return;
    }
    commitMermaidRender(pre, wrapper, messageId, renderSessionId);
  } catch {
    bridge.post({ type: 'diagnostic', code: 'mermaid_block_failed' });
    pre.classList.add('block-error');
  }
}

function addHtmlPreview(pre, source, key, messageId) {
  if (!messageId || source.length > maxHtmlPreviewCodeUnits) return;
  const body = document.createElement('div');
  body.className = 'html-preview-body';
  body.append(button(
    t('openHtmlPreview'),
    () => sendAction('openHtmlPreview', messageId, { source }),
    'action html-preview-open',
  ));
  pre.after(disclosure({
    key,
    label: t('htmlPreview'),
    body,
    expanded: localExpansion(key, false),
    className: 'html-preview',
    onToggle: (next) => {
      localExpansions.set(key, next);
      return next;
    },
  }));
}

function renderReasoning(message, parent) {
  const segments = message.reasoning ?? [];
  for (const [index, segment] of segments.entries()) renderReasoningSegment(message, segment, index, parent);
}

function createReasoningElapsedNode(segment) {
  if (segment.startAt == null) return null;
  const node = document.createElement('span');
  node.className = 'disclosure-detail reasoning-elapsed';
  node.dataset.reasoningElapsed = 'true';
  node.dataset.reasoningStartAt = String(segment.startAt);
  node.dataset.reasoningFinishedAt = String(segment.finishedAt ?? '');
  node.dataset.reasoningLoading = String(Boolean(segment.loading));
  node.textContent = formatReasoningElapsed(
    segment.startAt,
    segment.finishedAt,
    Boolean(segment.loading),
  );
  return node;
}

function refreshReasoningElapsed() {
  let hasLoading = false;
  for (const node of document.querySelectorAll('[data-reasoning-elapsed]')) {
    const loading = node.dataset.reasoningLoading === 'true';
    hasLoading ||= loading;
    node.textContent = formatReasoningElapsed(
      node.dataset.reasoningStartAt,
      node.dataset.reasoningFinishedAt,
      loading,
    );
  }
  if (!hasLoading && reasoningElapsedTimer != null) {
    clearInterval(reasoningElapsedTimer);
    reasoningElapsedTimer = null;
  }
}

function ensureReasoningElapsedTimer() {
  refreshReasoningElapsed();
  if (reasoningElapsedTimer == null &&
      document.querySelector('[data-reasoning-elapsed][data-reasoning-loading="true"]')) {
    reasoningElapsedTimer = setInterval(refreshReasoningElapsed, 100);
  }
}

function renderReasoningSegment(message, segment, index, parent) {
  const kind = segment.kind ?? 'legacy';
  const segmentIndex = Number.isInteger(segment.index) ? segment.index : index;
  const key = segment.key ?? `${message.id}:reasoning:${kind}:${segmentIndex}`;
  const authoritative = Boolean(segment.expanded);
  const expanded = kind === 'legacy'
    ? localExpansion(key, authoritative)
    : expansionCoordinator.value(key, authoritative);
  const body = document.createElement('div');
  body.className = 'thinking-body';
  body.append(markdownNode(
    segment.text ?? '',
    Boolean(segment.loading),
    'reasoning',
    message.id,
    `${key}:body`,
  ));
  const card = disclosure({
    key,
    label: segment.loading ? t('thinking') : t('reasoning'),
    body,
    expanded,
    className: 'thinking',
    icon: 'reasoning',
    detailNode: createReasoningElapsedNode(segment),
    onToggle: (next) => {
      if (kind === 'legacy') {
        localExpansions.set(key, next);
        return next;
      }
      return expansionCoordinator.toggle({
        key,
        authoritative,
        dispatch: (target) => sendAction('setReasoningExpanded', message.id, {
          kind,
          index: segmentIndex,
          expanded: target,
        }),
      });
    },
  });
  card.dataset.component = 'reasoning';
  card.classList.toggle('is-loading', Boolean(segment.loading));
  parent.append(card);
}

function appendConversationText(message, parent, content, blockKey) {
  if (!content) return;
  const markdown = markdownNode(
    content,
    message.isStreaming,
    message.role,
    message.id,
    `${message.id}:${blockKey}`,
  );
  markdown.dataset.contentBlockKey = blockKey;
  if (message.role === 'user') {
    parent.append(markdown);
    return;
  }
  const surface = document.createElement('div');
  surface.className = 'assistant-text-surface';
  surface.append(markdown);
  parent.append(surface);
}

function renderConversationBlocks(message, parent) {
  const reasoning = message.reasoning ?? [];
  const tools = message.tools ?? [];
  const splits = message.contentSplits ?? {};
  const offsets = splits.offsets ?? [];
  const reasoningCounts = splits.reasoningCounts ?? [];
  const toolCounts = splits.toolCounts ?? [];
  if (!offsets.length) {
    renderReasoning(message, parent);
    appendConversationText(message, parent, message.content, 'content:0');
    for (const tool of tools) renderTool(message, tool, parent);
    return;
  }
  let contentOffset = 0;
  let textBlockIndex = 0;
  let reasoningIndex = 0;
  let toolIndex = 0;
  for (let index = 0; index < offsets.length; index += 1) {
    const offset = Math.max(contentOffset, Math.min(message.content.length, offsets[index]));
    if (offset > contentOffset) {
      appendConversationText(
        message,
        parent,
        message.content.slice(contentOffset, offset),
        `content:${textBlockIndex}`,
      );
      textBlockIndex += 1;
    }
    while (reasoningIndex < Math.min(reasoning.length, reasoningCounts[index] ?? 0)) {
      renderReasoningSegment(message, reasoning[reasoningIndex], reasoningIndex, parent);
      reasoningIndex += 1;
    }
    while (toolIndex < Math.min(tools.length, toolCounts[index] ?? 0)) {
      renderTool(message, tools[toolIndex], parent);
      toolIndex += 1;
    }
    contentOffset = offset;
  }
  while (reasoningIndex < reasoning.length) {
    renderReasoningSegment(message, reasoning[reasoningIndex], reasoningIndex, parent);
    reasoningIndex += 1;
  }
  while (toolIndex < tools.length) {
    renderTool(message, tools[toolIndex], parent);
    toolIndex += 1;
  }
  if (contentOffset < message.content.length) {
    appendConversationText(
      message,
      parent,
      message.content.slice(contentOffset),
      `content:${textBlockIndex}`,
    );
  }
}

function conversationTextBlocks(message) {
  const content = String(message.content ?? '');
  const offsets = message.contentSplits?.offsets ?? [];
  if (!offsets.length) {
    return content ? [{ key: 'content:0', content }] : [];
  }
  const blocks = [];
  let contentOffset = 0;
  for (const rawOffset of offsets) {
    const offset = Math.max(contentOffset, Math.min(content.length, Number(rawOffset) || 0));
    if (offset > contentOffset) {
      blocks.push({ key: `content:${blocks.length}`, content: content.slice(contentOffset, offset) });
    }
    contentOffset = offset;
  }
  if (contentOffset < content.length) {
    blocks.push({ key: `content:${blocks.length}`, content: content.slice(contentOffset) });
  }
  return blocks;
}

function groupChainCards(parent) {
  let chain = null;
  for (const child of [...parent.children]) {
    const isStep = child.dataset?.component === 'reasoning' ||
      child.dataset?.component === 'tool';
    if (!isStep) {
      chain = null;
      continue;
    }
    if (!chain) {
      chain = document.createElement('section');
      chain.className = 'chain-card';
      child.before(chain);
    }
    chain.append(child);
  }
}

function renderTool(message, tool, parent) {
  const key = `${message.id}:tool:${tool.id}`;
  const summary = state.display?.showToolResultSummary === true && tool.content != null
    ? String(tool.content).replace(/\s+/g, ' ').trim().slice(0, 72)
    : '';
  const label = `${tool.content == null ? t('toolCall') : t('toolResult')} ${tool.toolName}${summary ? ` · ${summary}` : ''}`.trim();
  const body = document.createElement('div');
  body.className = 'tool-body';
  const args = document.createElement('pre');
  args.textContent = JSON.stringify(tool.arguments ?? {}, null, 2);
  body.append(args);
  if (tool.content != null) {
    body.append(markdownNode(
      tool.content,
      tool.loading,
      'assistant',
      message.id,
      `${key}:body`,
    ));
  }
  if (tool.arguments?.approvalRequired === true && tool.content == null) {
    const actions = document.createElement('div');
    actions.className = 'tool-actions';
    actions.append(
      button(t('approve'), () => sendAction('approveTool', message.id, { toolId: tool.id })),
      button(t('deny'), () => sendAction('denyTool', message.id, { toolId: tool.id })),
    );
    body.append(actions);
  }
  if (tool.arguments?.askUserActive === true && tool.content == null) renderAskUser(message, tool, body);
  const card = disclosure({
    key,
    label,
    body,
    expanded: localExpansion(key, false),
    className: 'tool',
    icon: 'tool',
    onToggle: (next) => {
      localExpansions.set(key, next);
      return next;
    },
  });
  card.dataset.component = 'tool';
  card.classList.toggle('is-loading', Boolean(tool.loading));
  parent.append(card);
}

function applyThinkingStepCollapse(message, parent) {
  if (state.display?.collapseThinkingSteps !== true) return;
  for (const [cardIndex, card] of [...parent.querySelectorAll(':scope > .chain-card')].entries()) {
    const steps = [...card.children].filter((node) =>
      node.dataset?.component === 'reasoning' || node.dataset?.component === 'tool');
    const { collapsed: collapsibleSteps } = partitionThinkingSteps(steps);
    if (collapsibleSteps.length === 0) continue;
    const key = `${message.id}:thinking-steps:${cardIndex}`;
    const toggle = button(
      '',
      () => {
        const interactionAnchor = beginLayoutInteraction(toggle);
        const expanded = !localExpansion(key, false);
        localExpansions.set(key, expanded);
        applyExpanded(expanded);
        queueInteractionLayoutReconcile(interactionAnchor, true);
      },
      'show-thinking-steps',
    );
    card.dataset.expansionKey = key;
    toggle.dataset.interactionAnchor = 'true';
    toggle.dataset.viewportAnchorKey = `${key}:toggle`;
    const applyExpanded = (expanded) => {
      for (const step of collapsibleSteps) step.hidden = !expanded;
      const label = expanded
        ? t('collapseThinkingSteps')
        : formatCountTemplate(
            t('expandThinkingSteps'),
            collapsibleSteps.length,
          );
      toggle.textContent = label;
      toggle.setAttribute('aria-label', label);
      toggle.setAttribute('aria-expanded', String(expanded));
    };
    applyExpanded(localExpansion(key, false));
    card.prepend(toggle);
  }
}

function renderAskUser(message, tool, parent) {
  const form = document.createElement('form');
  const questions = tool.arguments?.questions ?? [];
  const skipped = new Set();
  const customNames = new Map();
  for (const [index, question] of questions.entries()) {
    const fieldset = document.createElement('fieldset');
    const legend = document.createElement('legend');
    legend.textContent = question.question ?? '';
    fieldset.append(legend);
    const name = question.id ?? `q${index + 1}`;
    if (question.options?.length) {
      for (const option of question.options) {
        const label = document.createElement('label');
        const input = document.createElement('input');
        input.type = question.type === 'multi' ? 'checkbox' : 'radio';
        input.name = name;
        input.value = option;
        if (input.type === 'radio') input.required = true;
        label.append(input, document.createTextNode(option));
        fieldset.append(label);
      }
    }
    const custom = document.createElement('input');
    custom.name = `${name}__custom`;
    custom.placeholder = t('customAnswer');
    customNames.set(name, custom.name);
    if (!question.options?.length) custom.required = true;
    fieldset.append(custom);
    const skip = button(t('skip'), () => {
      const isSkipped = !skipped.has(name);
      if (isSkipped) skipped.add(name); else skipped.delete(name);
      for (const input of fieldset.querySelectorAll('input')) input.disabled = isSkipped;
      skip.textContent = isSkipped ? t('skipped') : t('skip');
      skip.setAttribute('aria-label', skip.textContent);
    });
    fieldset.append(skip);
    form.append(fieldset);
  }
  const submit = button(t('submit'), () => {}, 'action');
  submit.type = 'submit';
  form.append(submit);
  form.addEventListener('submit', (event) => {
    event.preventDefault();
    const data = new FormData(form);
    const custom = [];
    const answers = Object.fromEntries(questions.map((question, index) => {
      const name = question.id ?? `q${index + 1}`;
      const values = data.getAll(name).map(String);
      const customValue = String(data.get(customNames.get(name)) ?? '').trim();
      if (customValue) {
        custom.push(name);
        if (question.type === 'single') values.splice(0, values.length, customValue);
        else values.push(customValue);
      }
      return [name, values];
    }));
    sendAction('answerTool', message.id, {
      toolId: tool.id,
      answers,
      skipped: [...skipped],
      custom,
    });
  });
  parent.append(form);
}

function renderAttachments(message, parent) {
  for (const attachment of message.attachments ?? []) {
    const source = state.media?.[attachment.reference] ?? attachment.reference;
    const handle = isMediaHandle(attachment.reference)
      ? attachment.reference
      : state.remoteMediaHandles?.[attachment.reference];
    if (attachment.kind === 'image' && /^(data:|https?:)/i.test(source)) {
      const image = document.createElement('img');
      image.dataset.component = 'attachment-image';
      image.src = source;
      image.alt = attachment.name ?? '';
      image.referrerPolicy = 'no-referrer';
      if (handle) {
        image.dataset.mediaHandle = handle;
        image.tabIndex = 0;
        image.setAttribute('role', 'button');
        const preview = () => sendAction('previewImage', message.id, { handle });
        image.addEventListener('click', preview);
        image.addEventListener('keydown', (event) => {
          if (event.key === 'Enter' || event.key === ' ') {
            event.preventDefault();
            preview();
          }
        });
      }
      parent.append(image);
    } else if (attachment.kind === 'image' && isMediaHandle(attachment.reference)) {
      requestMedia(attachment.reference);
    } else if (attachment.kind === 'file') {
      const file = document.createElement('button');
      file.type = 'button';
      file.className = 'attachment-file';
      file.dataset.component = 'attachment-file';
      file.textContent = attachment.name ?? attachment.mime ?? '';
      if (handle) {
        file.addEventListener('click', () =>
          sendAction('openAttachment', message.id, { handle }));
      } else {
        file.disabled = true;
      }
      parent.append(file);
    }
  }
}

function mediaImage(reference, alt, monochrome = false) {
  const source = state.media?.[reference] ?? reference ?? '';
  if (!/^(data:|https?:)/i.test(source)) {
    if (isMediaHandle(reference)) requestMedia(reference);
    return null;
  }
  const image = document.createElement('img');
  image.src = source;
  image.alt = alt ?? '';
  image.referrerPolicy = 'no-referrer';
  image.classList.toggle('is-monochrome', monochrome);
  return image;
}

function renderAvatar(message) {
  const isUser = message.role === 'user';
  const display = state.display ?? {};
  const assistant = state.assistant ?? {};
  const user = state.user ?? {};
  if (isUser && display.showUserAvatar === false) return null;
  if (!isUser && !assistant.useAvatar && display.showModelIcon === false) return null;

  const avatar = document.createElement('div');
  avatar.className = 'avatar';
  if (isUser) {
    const image = mediaImage(user.avatar, user.name, false);
    if (image) avatar.append(image);
    else if (user.avatarLabel) avatar.textContent = user.avatarLabel;
    else avatar.append(iconNode('user'));
    return avatar;
  }

  if (assistant.useAvatar) {
    const image = mediaImage(assistant.avatar, assistant.name, false);
    if (image) avatar.append(image);
    else if (assistant.avatarLabel) avatar.textContent = assistant.avatarLabel;
    else avatar.append(iconNode('bot'));
    return avatar;
  }
  avatar.classList.add('is-model-icon');
  const image = mediaImage(
    message.modelIcon,
    message.modelId,
    Boolean(message.modelIconMonochrome),
  );
  if (image) avatar.append(image);
  else if (message.modelId?.trim()) {
    avatar.textContent = [...message.modelId.trim()][0].toUpperCase();
  } else {
    avatar.append(iconNode('bot'));
  }
  return avatar;
}

function renderMessageHeader(message) {
  const isUser = message.role === 'user';
  const display = state.display ?? {};
  const assistant = state.assistant ?? {};
  const header = document.createElement('div');
  header.className = 'message-header';
  const meta = document.createElement('div');
  meta.className = 'meta';
  if ((isUser && display.showUserName !== false) || (!isUser && display.showModelName !== false)) {
    const name = document.createElement('span');
    name.className = 'name';
    name.textContent = isUser
      ? (state.user?.name ?? t('user'))
      : (assistant.useName ? (assistant.name || t('assistant')) : (message.modelId || t('assistant')));
    meta.append(name);
  }
  if ((isUser && display.showUserTimestamp !== false) || (!isUser && display.showModelTimestamp !== false)) {
    const time = document.createElement('time');
    time.dateTime = message.timestamp;
    time.textContent = message.timestampLabel ?? '';
    meta.append(time);
  }
  const avatar = renderAvatar(message);
  if (isUser) header.append(meta, ...[avatar].filter(Boolean));
  else header.append(...[avatar].filter(Boolean), meta);
  return header.childElementCount ? header : null;
}

function renderMessageActions(message) {
  const actions = document.createElement('div');
  actions.className = 'actions';
  actions.dataset.component = 'message-actions';
  for (const action of message.actions ?? []) {
    const icon = action === 'speak' && state.display?.ttsActive === true
      ? 'stop'
      : ({ copy: 'copy', edit: 'edit', resend: 'resend', regenerate: 'regenerate',
        speak: 'speak', translate: 'translate', more: 'more' }[action] ?? 'sparkle');
    actions.append(iconButton(icon, actionLabel(action), () => sendAction(action, message.id)));
  }
  if ((message.versionCount ?? 1) > 1) {
    const previous = iconButton('previous', t('previousVersion'),
      () => sendAction('version', message.id, { delta: -1 }), 'version-action');
    previous.disabled = (message.versionIndex ?? 0) <= 0;
    const version = document.createElement('span');
    version.className = 'version-label';
    version.textContent = `${(message.versionIndex ?? 0) + 1}/${message.versionCount}`;
    const next = iconButton('next', t('nextVersion'),
      () => sendAction('version', message.id, { delta: 1 }), 'version-action');
    next.disabled = (message.versionIndex ?? 0) >= message.versionCount - 1;
    actions.append(previous, version, next);
  }
  if (message.role !== 'user' && state.display?.showTokenStats !== false && message.tokens != null) {
    const tokens = document.createElement('span');
    tokens.className = 'token-stats';
    tokens.textContent = `${message.tokens} ${t('tokens')}`;
    tokens.title = [
      message.promptTokens == null ? null : `${message.promptTokens}`,
      message.completionTokens == null ? null : `${message.completionTokens}`,
      message.cachedTokens == null ? null : `${message.cachedTokens}`,
    ].filter(Boolean).join(' / ');
    actions.append(tokens);
  }
  return actions.childElementCount ? actions : null;
}

function renderSuggestions() {
  if (!state.suggestions?.length) return null;
  const suggestions = document.createElement('div');
  suggestions.className = 'suggestions';
  for (const suggestion of state.suggestions.slice(0, 3)) {
    suggestions.append(button(
      suggestion,
      () => sendAction('suggestion', null, { text: suggestion }),
      'suggestion',
    ));
  }
  return suggestions;
}

function renderMessage(message, isLast = false) {
  const article = document.createElement('article');
  article.className = `message ${message.role === 'user' ? 'is-user' : 'is-assistant'}`;
  article.dataset.component = 'message';
  article.dataset.role = message.role;
  article.dataset.selected = String(Boolean(message.selected));
  article.tabIndex = -1;

  const main = document.createElement('div');
  main.className = 'message-main';
  const header = renderMessageHeader(message);

  const attachments = document.createElement('div');
  attachments.className = 'attachments';
  renderAttachments(message, attachments);

  const bubble = document.createElement('div');
  bubble.className = 'bubble';
  bubble.dataset.component = 'message-bubble';
  if (header) header.dataset.viewportAnchorKey = `${message.id}:header`;
  attachments.dataset.viewportAnchorKey = `${message.id}:attachments`;
  if (message.role === 'user' && (message.quickInstructions?.length ?? 0) > 0) {
    const instructions = document.createElement('div');
    instructions.className = 'quick-instructions';
    instructions.dataset.component = 'quick-instructions';
    for (const title of message.quickInstructions) {
      const chip = document.createElement('span');
      chip.className = 'quick-instruction-chip';
      chip.textContent = String(title ?? '');
      instructions.append(chip);
    }
    bubble.append(instructions);
  }
  renderConversationBlocks(message, bubble);
  groupChainCards(bubble);
  applyThinkingStepCollapse(message, bubble);
  if (message.translation) {
    const key = `${message.id}:translation`;
    bubble.append(disclosure({
      key,
      label: t('translation'),
      body: markdownNode(
        message.translation,
        message.isStreaming,
        'assistant',
        message.id,
        `${key}:body`,
      ),
      expanded: localExpansion(key, true),
      className: 'translation',
      icon: 'translate',
      onToggle: (next) => {
        localExpansions.set(key, next);
        return next;
      },
    }));
  }
  if (message.role !== 'user' && (message.citations?.length ?? 0) > 0) {
    const sources = button(
      `${t('sources')} (${message.citations.length})`,
      () => sendAction('showCitations', message.id),
      'sources-summary',
    );
    bubble.append(sources);
  }
  if (message.role !== 'user' && message.isStreaming && !bubble.childElementCount) {
    const streaming = document.createElement('div');
    streaming.className = 'streaming-indicator';
    streaming.setAttribute('aria-label', t('assistant'));
    streaming.append(document.createElement('i'), document.createElement('i'), document.createElement('i'));
    bubble.append(streaming);
  }
  const actions = message.selecting || (message.role !== 'user' && message.isStreaming)
    ? null
    : renderMessageActions(message);
  if (actions) actions.dataset.viewportAnchorKey = `${message.id}:actions`;
  const suggestions = message.role !== 'user' && isLast && !message.isStreaming
    ? renderSuggestions()
    : null;
  main.append(
    ...[
      header,
      attachments.childElementCount ? attachments : null,
      bubble.childElementCount ? bubble : null,
      actions,
      suggestions,
    ].filter(Boolean),
  );
  if (message.selecting) {
    const checkbox = button(t('select'), (event) => {
      event.stopPropagation();
      sendAction('select', message.id);
    }, 'selection-checkbox');
    checkbox.setAttribute('role', 'checkbox');
    checkbox.setAttribute('aria-checked', String(Boolean(message.selected)));
    checkbox.replaceChildren(message.selected ? '✓' : '');
    article.append(checkbox);
  }
  article.append(main);
  article.addEventListener('contextmenu', (event) => {
    event.preventDefault();
    if (!message.selecting) sendAction('more', message.id);
  });
  if (message.selecting) {
    article.addEventListener('click', (event) => {
      if (window.getSelection()?.toString().trim()) return;
      if (!event.target.closest('button, a, input, textarea')) sendAction('select', message.id);
    });
  }
  return article;
}

function messageForPresentation(message) {
  if (message.isStreaming !== true) {
    presentedStreamContent.delete(message.id);
    return message;
  }
  if (!presentedStreamContent.has(message.id)) {
    presentedStreamContent.set(message.id, message.content ?? '');
  }
  return { ...message, content: presentedStreamContent.get(message.id) ?? '' };
}

function createMessageSlot(message, index, messageCount) {
  const slot = document.createElement('div');
  slot.className = 'message-slot';
  slot.dataset.messageId = message.id;
  slot.dataset.messageSlot = 'true';
  const presented = messageForPresentation(message);
  slot.append(renderMessage(presented, index === messageCount - 1));
  if (message.showContextDivider) {
    const divider = document.createElement('div');
    divider.className = 'context-divider';
    divider.textContent = t('contextDivider');
    slot.append(divider);
  }
  return slot;
}

function reportSlowRender(startedAt, code) {
  const elapsed = performance.now() - startedAt;
  if (elapsed < 50) return;
  bridge.post({
    type: 'diagnostic',
    code,
    durationBucketMs: Math.min(1000, Math.ceil(elapsed / 50) * 50),
  });
}

function streamStructureSignature(message) {
  const cached = streamStructureSignatureCache.get(message);
  if (cached != null) return cached;
  const signature = stableTextKey('stream-structure', JSON.stringify({
    role: message.role,
    isStreaming: message.isStreaming,
    reasoning: message.reasoning,
    contentSplits: message.contentSplits,
    tools: message.tools,
    translation: message.translation,
  }));
  streamStructureSignatureCache.set(message, signature);
  return signature;
}

function updateMountedStreamingContent(messageId, content) {
  const slot = mountedSlots.get(messageId);
  if (!slot?.isConnected || !state?.messages?.length) return false;
  if (touchActive || userScrolling || virtualWindowLoading) {
    pendingMountedUpdates.add(messageId);
    return false;
  }
  const message = state.messages.find((candidate) => candidate.id === messageId);
  if (!message || message.isStreaming !== true) return false;
  const blocks = conversationTextBlocks({ ...message, content });
  const roots = [...slot.querySelectorAll('.markdown[data-content-block-key]')];
  if (blocks.length !== roots.length || blocks.some(
    (block, index) => roots[index].dataset.contentBlockKey !== block.key,
  )) return false;
  const viewport = captureViewport(timeline);
  const startedAt = performance.now();
  try {
    for (const [index, block] of blocks.entries()) {
      patchStreamingMarkdownRoot(roots[index], block.content, message.role);
    }
  } catch (error) {
    bridge.post({ type: 'diagnostic', code: 'stream_markdown_patch_failed' });
    return false;
  }
  restorePreferredViewport(viewport);
  enforceNavigationEdge();
  sendViewportMetrics();
  reportSlowRender(startedAt, 'stream_markdown_render_slow');
  return true;
}

function updateMountedMessage(messageId) {
  const slot = mountedSlots.get(messageId);
  if (!slot?.isConnected || !state?.messages?.length) return false;
  if (touchActive || userScrolling || virtualWindowLoading) {
    pendingMountedUpdates.add(messageId);
    return false;
  }
  const index = state.messages.findIndex((message) => message.id === messageId);
  if (index < 0) return false;
  const viewport = captureViewport(timeline);
  const startedAt = performance.now();
  const replacement = createMessageSlot(
    state.messages[index],
    index,
    state.messages.length,
  );
  slot.replaceChildren(...replacement.children);
  restorePreferredViewport(viewport);
  enforceNavigationEdge();
  ensureReasoningElapsedTimer();
  sendViewportMetrics();
  reportSlowRender(startedAt, 'stream_message_render_slow');
  return true;
}

function flushMountedUpdates() {
  if (touchActive || userScrolling || virtualWindowLoading) return;
  const ids = [...pendingMountedUpdates];
  pendingMountedUpdates.clear();
  for (const id of ids) updateMountedMessage(id);
  flushRendererUpdates();
}

function render() {
  if (!state) return;
  cancelVirtualPrefetch();
  const startedAt = performance.now();
  const sameSession = renderedSessionId === state.renderSessionId;
  if (!sameSession) {
    navigationEdge = state.initialViewportMode === 'bottom' ? 'bottom' : null;
    initialBottomPin = navigationEdge === 'bottom';
  }
  const savedViewport = sameSession
    ? null
    : viewportForSavedAnchor({
      messageIds: (state.messages ?? []).map((message) => message.id),
      heights: (state.messages ?? []).map(messageHeight),
      anchor: state.initialViewportAnchor,
      viewportHeight: timeline.clientHeight,
    });
  const messages = state.messages ?? [];
  const missingSavedAnchor = !sameSession &&
    state.initialViewportAnchor != null && savedViewport == null;
  const override = forcedViewport;
  forcedViewport = null;
  const startsAtBottom = !sameSession && state.initialViewportMode === 'bottom';
  const viewport = override ?? savedViewport ?? (missingSavedAnchor || startsAtBottom
    ? {
      scrollTop: messages.reduce((sum, message) => sum + messageHeight(message), 0),
      viewportHeight: timeline.clientHeight,
      anchor: null,
    }
    : captureViewport(timeline, { preserve: sameSession }));
  applyTheme();
  resizeObserver?.disconnect();
  resizeObserver ??= new ResizeObserver(handleMeasuredHeights);
  const fragment = document.createDocumentFragment();
  const observedSlots = [];
  if (messages.length === 0) {
    renderedRange = { start: 0, end: 0 };
    topSpacer = null;
    bottomSpacer = null;
    mountedSlots.clear();
    const empty = document.createElement('div');
    empty.className = 'empty';
    empty.textContent = t('empty');
    fragment.append(empty);
    timeline.replaceChildren(fragment);
    renderedSessionId = state.renderSessionId;
    renderedConversationId = state.conversationId;
    ensureReasoningElapsedTimer();
    restorePreferredViewport(viewport, true, true);
    lastTimelineScrollTop = timeline.scrollTop;
    pendingMountedUpdates.clear();
    enforceNavigationEdge();
    releaseInitialBottomPin();
    flushRendererUpdates();
    sendViewportMetrics();
    acknowledgeCommittedRender();
    reportSlowRender(startedAt, 'virtual_window_render_slow');
    return;
  }
  const range = PRINT_MODE
    ? { start: 0, end: messages.length, top: 0, bottom: 0 }
    : visibleRange({
        heights: messages.map(messageHeight),
        scrollTop: viewport.scrollTop,
        viewportHeight: viewport.viewportHeight,
        overscan: virtualOverscan(viewport.viewportHeight),
      });
  renderedRange = { start: range.start, end: range.end };
  mountedSlots.clear();
  topSpacer = document.createElement('div');
  topSpacer.className = 'spacer';
  topSpacer.style.height = `${range.top}px`;
  bottomSpacer = document.createElement('div');
  bottomSpacer.className = 'spacer';
  bottomSpacer.style.height = `${range.bottom}px`;
  fragment.append(topSpacer);
  if (state.preset && range.start === 0) {
    fragment.append(createPresetNode());
  }
  for (const [visibleIndex, message] of messages.slice(range.start, range.end).entries()) {
    const slot = createMessageSlot(
      message,
      range.start + visibleIndex,
      messages.length,
    );
    fragment.append(slot);
    observedSlots.push(slot);
    mountedSlots.set(message.id, slot);
  }
  fragment.append(bottomSpacer);
  timeline.replaceChildren(fragment);
  for (const slot of observedSlots) resizeObserver.observe(slot);
  renderedSessionId = state.renderSessionId;
  renderedConversationId = state.conversationId;
  ensureReasoningElapsedTimer();
  restorePreferredViewport(viewport, true, true);
  lastTimelineScrollTop = timeline.scrollTop;
  pendingMountedUpdates.clear();
  enforceNavigationEdge();
  flushRendererUpdates();
  sendViewportMetrics();
  acknowledgeCommittedRender();
  reportSlowRender(startedAt, 'virtual_window_render_slow');
}

function acknowledgeCommittedRender() {
  if (!state) return;
  renderCommitCoordinator.request({
    renderSessionId: state.renderSessionId,
    conversationId: state.conversationId,
    renderRevision: state.renderRevision,
  });
  if (PRINT_MODE) maybeSchedulePrintComplete();
}

const PRINT_COMPLETE_POLL_MS = 200;
const PRINT_COMPLETE_MAX_ATTEMPTS = 150;
let printCompletePosted = false;
let printCompleteTimer = 0;
let printCompleteAttempts = 0;

function maybeSchedulePrintComplete() {
  if (!PRINT_MODE || printCompletePosted || printCompleteTimer) return;
  printCompleteAttempts = 0;
  printCompleteTimer = setInterval(checkPrintComplete, PRINT_COMPLETE_POLL_MS);
}

function checkPrintComplete() {
  printCompleteAttempts += 1;
  const imagesLoaded = [...document.querySelectorAll('img[data-media-handle]')]
    .every((image) => image.complete);
  const coreIdle =
    pendingMedia.size === 0 &&
    pendingRendererRenders.size === 0 &&
    pendingRendererRefreshes.size === 0 &&
    pendingMermaidCommits.size === 0 &&
    rendererRefreshFrame === 0;
  const timedOut = printCompleteAttempts >= PRINT_COMPLETE_MAX_ATTEMPTS;
  if ((coreIdle && imagesLoaded) || timedOut) {
    clearInterval(printCompleteTimer);
    printCompleteTimer = 0;
    printCompletePosted = true;
    bridge.post({
      type: 'printRenderComplete',
      protocolVersion: PROTOCOL_VERSION,
      assetVersion: ASSET_VERSION,
      renderSessionId: state?.renderSessionId ?? '',
      conversationId: state?.conversationId ?? '',
      capabilityToken: state?.capabilityToken ?? '',
      ...(timedOut && !(coreIdle && imagesLoaded) ? { timedOut: true } : {}),
    });
  }
}

function releaseInitialBottomPin() {
  if (!initialBottomPin || bottomHoldTimer != null) return;
  initialBottomPin = false;
  if (navigationEdge === 'bottom') navigationEdge = null;
}

function notifyViewportInteraction() {
  if (!state) return;
  bridge.post({
    type: 'viewportInteraction',
    protocolVersion: PROTOCOL_VERSION,
    renderSessionId: state.renderSessionId,
    conversationId: state.conversationId,
    capabilityToken: state.capabilityToken,
  });
}

function releaseInteractionAnchor(anchor) {
  if (!isCurrentInteraction(anchor)) return false;
  pendingInteractionAnchor = null;
  clearTimeout(interactionExpiryTimer);
  interactionExpiryTimer = null;
  return true;
}

function cancelInteractionLayout() {
  interactionRevision += 1;
  pendingInteractionAnchor = null;
  clearTimeout(interactionExpiryTimer);
  interactionExpiryTimer = null;
  if (interactionMeasureFrame) cancelAnimationFrame(interactionMeasureFrame);
  interactionMeasureFrame = 0;
}

function beginLayoutInteraction(element) {
  cancelInteractionLayout();
  viewportNavigation.cancel();
  programmaticNavigationActive = false;
  navigationCursorId = null;
  navigationEdge = null;
  initialBottomPin = false;
  clearTimeout(bottomHoldTimer);
  bottomHoldTimer = null;
  notifyViewportInteraction();
  const captured = captureInteractionAnchor(timeline, element);
  if (!captured) return null;
  const anchor = {
    ...captured,
    revision: interactionRevision,
    controlled: false,
    releaseRequested: false,
  };
  pendingInteractionAnchor = anchor;
  interactionExpiryTimer = setTimeout(() => {
    if (!isCurrentInteraction(anchor)) return;
    releaseInteractionAnchor(anchor);
    scheduleMeasuredHeightReconcile();
    scheduleVirtualPrune();
  }, 2000);
  return anchor;
}

function isCurrentInteraction(anchor) {
  return anchor != null && pendingInteractionAnchor != null &&
    anchor.revision === interactionRevision &&
    pendingInteractionAnchor.revision === anchor.revision;
}

function updateInteractionControl(anchor, controlled) {
  if (!isCurrentInteraction(anchor)) return;
  anchor.controlled = Boolean(controlled);
  pendingInteractionAnchor.controlled = anchor.controlled;
}

function interactionAnchorCanRelease(anchor) {
  if (!anchor) return false;
  if (anchor.controlled) {
    return !expansionCoordinator.isPending(anchor.expansionKey);
  }
  return anchor.releaseRequested === true;
}

function restorePreferredViewport(
  viewport,
  allowInteractionRelease = false,
  dropMissingInteraction = false,
) {
  if (pendingInteractionAnchor) {
    if (restoreInteractionAnchor(timeline, pendingInteractionAnchor)) {
      if (allowInteractionRelease &&
          interactionAnchorCanRelease(pendingInteractionAnchor)) {
        releaseInteractionAnchor(pendingInteractionAnchor);
      }
      return;
    }
    if (dropMissingInteraction) releaseInteractionAnchor(pendingInteractionAnchor);
  }
  restoreViewport(timeline, viewport);
}

function stageMeasuredHeight(id, rawHeight) {
  const height = normalizeMeasuredHeight(rawHeight);
  if (!id || height == null) return false;
  const current = pendingMeasuredHeights.get(id) ?? heights.get(id) ?? 0;
  if (Math.abs(current - height) <= 1) return false;
  pendingMeasuredHeights.set(id, height);
  measuredHeightsPending = true;
  return true;
}

function queueInteractionLayoutReconcile(anchor, releaseRequested = false) {
  if (!isCurrentInteraction(anchor)) return;
  anchor.releaseRequested ||= Boolean(releaseRequested);
  pendingInteractionAnchor.releaseRequested = anchor.releaseRequested;
  // Correct the click-triggered layout change before the browser can paint;
  // the next frame measures and commits the matching height generation.
  restoreInteractionAnchor(timeline, anchor);
  cancelVirtualPrefetch();
  clearTimeout(virtualPruneTimer);
  if (interactionMeasureFrame) return;
  const revision = anchor.revision;
  interactionMeasureFrame = requestAnimationFrame(() => {
    interactionMeasureFrame = 0;
    if (!isCurrentInteraction(anchor) || revision !== interactionRevision) return;
    const activeAnchor = pendingInteractionAnchor;
    const slot = activeAnchor == null
      ? null
      : mountedSlots.get(activeAnchor.messageId);
    if (slot?.isConnected) {
      stageMeasuredHeight(
        activeAnchor.messageId,
        slot.getBoundingClientRect().height,
      );
    }
    if (isCurrentInteraction(activeAnchor)) {
      restoreInteractionAnchor(timeline, activeAnchor);
    }
    scheduleMeasuredHeightReconcile();
  });
}

function handleMeasuredHeights(entries) {
  if (!state?.messages?.length) return;
  let changed = false;
  for (const entry of entries) {
    const id = entry.target.dataset.messageId;
    const height = normalizeMeasuredHeight(
      entry.borderBoxSize?.[0]?.blockSize ?? entry.contentRect.height,
    );
    if (id && mountedSlots.get(id) === entry.target) {
      changed = stageMeasuredHeight(id, height) || changed;
    }
  }
  if (!changed) return;
  scheduleMeasuredHeightReconcile();
}

function reconcileMeasuredHeights() {
  if ((!measuredHeightsPending && !pendingInteractionAnchor) ||
      !state?.messages?.length ||
      touchActive || userScrolling || virtualWindowLoading ||
      !topSpacer || !bottomSpacer || renderedRange.start < 0) return;
  const viewport = captureViewport(timeline);
  const changed = measuredHeightsPending
    ? commitPendingMeasurements(heights, pendingMeasuredHeights)
    : false;
  measuredHeightsPending = false;
  if (!changed) {
    restorePreferredViewport(viewport, true);
    releaseInitialBottomPin();
    sendViewportMetrics();
    return;
  }
  const messages = state.messages;
  // Publish the ledger and both spacers within one frame before restoring the
  // interaction anchor. A paint with mixed generations reintroduces jumps.
  topSpacer.style.height = `${messages.slice(0, renderedRange.start)
    .reduce((sum, message) => sum + messageHeight(message), 0)}px`;
  bottomSpacer.style.height = `${messages.slice(renderedRange.end)
    .reduce((sum, message) => sum + messageHeight(message), 0)}px`;
  restorePreferredViewport(viewport, true);
  const restoredScrollTop = timeline.scrollTop;
  const coverage = coverageFor(restoredScrollTop);
  if (!coverage.covered) {
    beginVirtualWindowLoad(coverage.requested, restoredScrollTop);
    return;
  }
  enforceNavigationEdge();
  releaseInitialBottomPin();
  sendViewportMetrics();
  const range = visibleRange({
    heights: messages.map(messageHeight),
    scrollTop: restoredScrollTop,
    viewportHeight: viewport.viewportHeight,
    overscan: virtualOverscan(viewport.viewportHeight),
  });
  if (range.start < renderedRange.start || range.end > renderedRange.end) {
    scheduleVirtualPrefetch(restoredScrollTop);
  }
}

function renderSafely() {
  try {
    render();
  } catch (error) {
    bridge.post({
      type: 'diagnostic',
      code: 'render_failed',
      renderSessionId: state?.renderSessionId,
      conversationId: state?.conversationId,
      renderRevision: state?.renderRevision,
      capabilityToken: state?.capabilityToken,
    });
  }
}

const scheduleRender = createFrameCoalescer(renderSafely);
const scheduleMeasuredHeightReconcile = createFrameCoalescer(
  reconcileMeasuredHeights,
);
const renderGate = createRenderGate(scheduleRender);
function requestRender() { renderGate.request(); }
function setRenderBlocked(value) { renderGate.setBlocked(value); }
const streamPresenter = createAdaptiveStreamPresenter({
  commit: (messageId, content) => {
    presentedStreamContent.set(messageId, content);
    if (!updateMountedStreamingContent(messageId, content)) {
      updateMountedMessage(messageId);
    }
  },
});
const sendViewportMetrics = createFrameCoalescer(() => {
  const anchor = captureAnchor(timeline, { granular: false });
  bridge.post({
    type: 'viewportMetrics',
    pixels: timeline.scrollTop,
    maxExtent: Math.max(0, timeline.scrollHeight - timeline.clientHeight),
    isUserScrolling: userScrolling,
    renderSessionId: renderedSessionId,
    conversationId: renderedConversationId,
    anchorMessageId: anchor?.id ?? null,
    anchorOffset: anchor?.offset ?? 0,
  });
});
const viewportNavigation = createViewportNavigationCoordinator({
  setRenderBlocked,
  requestRender,
});

function webContentInsets() {
  const insets = state?.display?.contentInsets ?? {};
  return {
    top: normalizeContentInset(insets.top, 0),
    bottom: normalizeContentInset(insets.bottom, 0),
  };
}

function coverageFor(scrollTop) {
  const insets = webContentInsets();
  return virtualCoverage({
    heights: (state?.messages ?? []).map(messageHeight),
    range: renderedRange,
    scrollTop,
    viewportHeight: timeline.clientHeight,
    leadingInset: insets.top,
    trailingInset: insets.bottom,
  });
}

function setVirtualWindowLoading(value) {
  virtualWindowLoading = Boolean(value);
  virtualWindowLoader.hidden = !virtualWindowLoading;
  virtualWindowLoaderLabel.textContent = virtualWindowLoading ? t('loading') : '';
  timeline.setAttribute('aria-busy', String(virtualWindowLoading));
  if (virtualWindowLoading) return;
  releaseScrollStopLock();
  if (!touchActive && !userScrolling) setRenderBlocked(false);
  flushMountedUpdates();
  scheduleMeasuredHeightReconcile();
}

function clampVirtualScroll(scrollTop) {
  const top = Math.max(0, Number(scrollTop) || 0);
  scrollStopLock = true;
  scrollStopLeft = timeline.scrollLeft;
  timeline.scrollTo({ left: scrollStopLeft, top, behavior: 'auto' });
  scrollStopTop = timeline.scrollTop;
  if (!scrollStopFrame) scrollStopFrame = requestAnimationFrame(enforceScrollStop);
}

function messageOrderMatches(messageIds, renderSessionId) {
  const current = state?.messages ?? [];
  return state?.renderSessionId === renderSessionId &&
    current.length === messageIds.length &&
    current.every((message, index) => message.id === messageIds[index]);
}

async function renderVirtualTarget(scrollTop, requestRevision) {
  const startedAt = performance.now();
  const target = Math.max(0, Number(scrollTop) || 0);
  const renderSessionId = state?.renderSessionId;
  const messageIds = (state?.messages ?? []).map((message) => message.id);
  if (!renderSessionId || messageIds.length === 0) {
    throw new Error('virtual_window_target_missing');
  }
  const viewportHeight = timeline.clientHeight;
  const range = visibleRange({
    heights: state.messages.map(messageHeight),
    scrollTop: target,
    viewportHeight,
    overscan: virtualOverscan(viewportHeight),
  });
  if (range.start >= range.end) {
    throw new Error('virtual_window_target_missing');
  }
  const indices = Array.from(
    { length: range.end - range.start },
    (_, offset) => range.start + offset,
  );
  const built = await buildWithFrameBudget({
    items: indices,
    shouldContinue: () => virtualWindowCoordinator.isCurrent(requestRevision) &&
      messageOrderMatches(messageIds, renderSessionId),
    build: (index) => {
      const message = state.messages[index];
      if (message?.id !== messageIds[index]) {
        throw new Error('virtual_window_target_missing');
      }
      return {
        id: message.id,
        slot: createMessageSlot(message, index, state.messages.length),
      };
    },
  });
  if (!virtualWindowCoordinator.isCurrent(requestRevision) ||
      !messageOrderMatches(messageIds, renderSessionId)) {
    throw new Error('virtual_window_stale');
  }

  const fragment = document.createDocumentFragment();
  const nextTopSpacer = document.createElement('div');
  nextTopSpacer.className = 'spacer';
  nextTopSpacer.style.height = `${range.top}px`;
  const nextBottomSpacer = document.createElement('div');
  nextBottomSpacer.className = 'spacer';
  nextBottomSpacer.style.height = `${range.bottom}px`;
  fragment.append(nextTopSpacer);
  if (state.preset && range.start === 0) fragment.append(createPresetNode());
  for (const entry of built) fragment.append(entry.slot);
  fragment.append(nextBottomSpacer);

  applyTheme();
  resizeObserver?.disconnect();
  resizeObserver ??= new ResizeObserver(handleMeasuredHeights);
  timeline.replaceChildren(fragment);
  mountedSlots.clear();
  for (const entry of built) {
    mountedSlots.set(entry.id, entry.slot);
    resizeObserver.observe(entry.slot);
  }
  topSpacer = nextTopSpacer;
  bottomSpacer = nextBottomSpacer;
  renderedRange = { start: range.start, end: range.end };
  renderedSessionId = state.renderSessionId;
  renderedConversationId = state.conversationId;
  ensureReasoningElapsedTimer();
  reportSlowRender(startedAt, 'virtual_window_target_slow');
}

const virtualWindowCoordinator = createVirtualWindowCoordinator({
  setLoading: setVirtualWindowLoading,
  clamp: clampVirtualScroll,
  renderTarget: renderVirtualTarget,
  settleTarget: (target) => {
    const requested = Math.max(0, Number(target) || 0);
    const restoredInteraction = pendingInteractionAnchor != null &&
      restoreInteractionAnchor(timeline, pendingInteractionAnchor);
    if (restoredInteraction &&
        interactionAnchorCanRelease(pendingInteractionAnchor)) {
      releaseInteractionAnchor(pendingInteractionAnchor);
    }
    if (!restoredInteraction) {
      timeline.scrollTo({ top: requested, behavior: 'auto' });
    }
    scrollStopTop = timeline.scrollTop;
    lastTimelineScrollTop = scrollStopTop;
    sendViewportMetrics();
  },
  onError: (error) => {
    const code = error?.message === 'virtual_window_timeout'
      ? 'virtual_window_timeout'
      : error?.message === 'virtual_window_target_missing'
        ? 'virtual_window_target_missing'
        : 'virtual_window_render_failed';
    bridge.post({ type: 'diagnostic', code });
  },
});

function beginVirtualWindowLoad(target, hold = target, onSettled = null) {
  cancelVirtualPrefetch();
  setRenderBlocked(true);
  virtualWindowCoordinator.request({ target, hold, onSettled });
}

function createPresetNode() {
  if (!state?.preset) return null;
  const preset = document.createElement('div');
  preset.className = 'suggestions';
  preset.dataset.component = 'preset-toggle';
  preset.append(button(state.preset.label, () => sendAction('togglePresets'), 'suggestion'));
  return preset;
}

async function extendVirtualRange(targetTop, prefetchRevision) {
  if (!state?.messages?.length || virtualWindowLoading ||
      pendingInteractionAnchor || !topSpacer || !bottomSpacer) {
    return false;
  }
  const messages = state.messages;
  const renderSessionId = state.renderSessionId;
  const messageIds = messages.map((message) => message.id);
  const baseRange = { ...renderedRange };
  const desired = visibleRange({
    heights: messages.map(messageHeight),
    scrollTop: Math.max(0, Number(targetTop) || 0),
    viewportHeight: timeline.clientHeight,
    overscan: virtualOverscan(timeline.clientHeight),
  });
  const start = Math.min(baseRange.start, desired.start);
  const end = Math.max(baseRange.end, desired.end);
  if (start === baseRange.start && end === baseRange.end) return true;
  const span = messages.slice(start, end).reduce((sum, message) => sum + messageHeight(message), 0);
  const limit = virtualOverscan(timeline.clientHeight) * 2 + timeline.clientHeight * 3;
  if (span > limit) return false;

  const startedAt = performance.now();
  const indices = [
    ...Array.from(
      { length: baseRange.start - start },
      (_, offset) => start + offset,
    ),
    ...Array.from(
      { length: end - baseRange.end },
      (_, offset) => baseRange.end + offset,
    ),
  ];
  const built = await buildWithFrameBudget({
    items: indices,
    shouldContinue: () => prefetchRevision === virtualPrefetchRevision &&
      !virtualWindowLoading && messageOrderMatches(messageIds, renderSessionId) &&
      renderedRange.start === baseRange.start && renderedRange.end === baseRange.end,
    build: (index) => {
      const message = state.messages[index];
      if (message?.id !== messageIds[index]) {
        throw new Error('virtual_window_stale');
      }
      return {
        id: message.id,
        index,
        slot: createMessageSlot(message, index, state.messages.length),
      };
    },
  });
  if (prefetchRevision !== virtualPrefetchRevision || virtualWindowLoading ||
      !messageOrderMatches(messageIds, renderSessionId) ||
      renderedRange.start !== baseRange.start || renderedRange.end !== baseRange.end) {
    throw new Error('virtual_window_stale');
  }

  const viewport = captureViewport(timeline);
  const before = document.createDocumentFragment();
  const after = document.createDocumentFragment();
  for (const entry of built) {
    if (entry.index < baseRange.start) before.append(entry.slot);
    else after.append(entry.slot);
  }
  if (before.childNodes.length) {
    const preset = start === 0 && !timeline.querySelector('[data-component="preset-toggle"]')
      ? createPresetNode()
      : null;
    topSpacer.after(...[preset, before].filter(Boolean));
  }
  if (after.childNodes.length) bottomSpacer.before(after);
  for (const entry of built) {
    mountedSlots.set(entry.id, entry.slot);
    resizeObserver.observe(entry.slot);
  }

  renderedRange = { start, end };
  topSpacer.style.height = `${messages.slice(0, start)
    .reduce((sum, message) => sum + messageHeight(message), 0)}px`;
  bottomSpacer.style.height = `${messages.slice(end)
    .reduce((sum, message) => sum + messageHeight(message), 0)}px`;
  restoreViewport(timeline, viewport);
  reportSlowRender(startedAt, 'virtual_window_prefetch_slow');
  return true;
}

function scheduleVirtualPrefetch(targetTop) {
  if (pendingInteractionAnchor) return;
  virtualPrefetchTarget = Math.max(0, Number(targetTop) || 0);
  if (virtualPrefetchFrame || virtualPrefetchActive) return;
  virtualPrefetchFrame = requestAnimationFrame(async () => {
    virtualPrefetchFrame = 0;
    const target = virtualPrefetchTarget;
    virtualPrefetchTarget = null;
    if (target == null) return;
    virtualPrefetchActive = true;
    const revision = ++virtualPrefetchRevision;
    let extended = false;
    try {
      extended = await extendVirtualRange(target, revision);
    } catch (error) {
      if (error?.message !== 'virtual_window_stale') {
        bridge.post({ type: 'diagnostic', code: 'virtual_window_prefetch_failed' });
      }
    } finally {
      virtualPrefetchActive = false;
      if (virtualPrefetchTarget != null) {
        scheduleVirtualPrefetch(virtualPrefetchTarget);
      } else if (extended && !touchActive && !userScrolling &&
          !virtualWindowLoading) {
        scheduleVirtualPrune();
      }
    }
  });
}

function cancelVirtualPrefetch() {
  virtualPrefetchRevision += 1;
  virtualPrefetchTarget = null;
  if (virtualPrefetchFrame) cancelAnimationFrame(virtualPrefetchFrame);
  virtualPrefetchFrame = 0;
}

function pruneVirtualRange() {
  if (!state?.messages?.length || touchActive || userScrolling ||
      virtualWindowLoading || virtualPrefetchActive || pendingInteractionAnchor ||
      !topSpacer || !bottomSpacer) return;
  const messages = state.messages;
  const viewport = captureViewport(timeline);
  const desired = visibleRange({
    heights: messages.map(messageHeight),
    scrollTop: viewport.scrollTop,
    viewportHeight: viewport.viewportHeight,
    overscan: virtualOverscan(viewport.viewportHeight),
  });
  if (desired.start < renderedRange.start || desired.end > renderedRange.end) {
    scheduleVirtualPrefetch(viewport.scrollTop);
    return;
  }
  for (let index = renderedRange.start; index < desired.start; index += 1) {
    const slot = mountedSlots.get(messages[index].id);
    if (slot) resizeObserver.unobserve(slot);
    slot?.remove();
    mountedSlots.delete(messages[index].id);
  }
  for (let index = desired.end; index < renderedRange.end; index += 1) {
    const slot = mountedSlots.get(messages[index].id);
    if (slot) resizeObserver.unobserve(slot);
    slot?.remove();
    mountedSlots.delete(messages[index].id);
  }
  if (desired.start > 0) {
    timeline.querySelector('[data-component="preset-toggle"]')?.remove();
  }
  renderedRange = { start: desired.start, end: desired.end };
  topSpacer.style.height = `${desired.top}px`;
  bottomSpacer.style.height = `${desired.bottom}px`;
  restoreViewport(timeline, viewport);
  sendViewportMetrics();
}

function scheduleVirtualPrune() {
  clearTimeout(virtualPruneTimer);
  virtualPruneTimer = setTimeout(pruneVirtualRange, 160);
}

function releaseScrollStopLock() {
  if (virtualWindowLoading) return;
  scrollStopLock = false;
  if (scrollStopFrame) {
    cancelAnimationFrame(scrollStopFrame);
    scrollStopFrame = 0;
  }
}
function restoreScrollStopPosition() {
  if (!scrollStopLock) return;
  if (timeline.scrollTop !== scrollStopTop || timeline.scrollLeft !== scrollStopLeft) {
    timeline.scrollTo({ left: scrollStopLeft, top: scrollStopTop, behavior: 'auto' });
  }
}
function enforceScrollStop() {
  if (!scrollStopLock) {
    scrollStopFrame = 0;
    return;
  }
  restoreScrollStopPosition();
  scrollStopFrame = requestAnimationFrame(enforceScrollStop);
}
function stopScrolling(origin = 'programmatic') {
  // The Flutter/Android bridge may deliver this call slightly after the DOM
  // pointer event. Never restart the lock after this gesture already became a
  // real drag.
  if (gestureActive && gestureIntent !== 'hold') return;
  timeline.style.scrollBehavior = 'auto';
  // Mobile touch devices own the pan: a touch-origin call never arms the
  // persistent lock. Programmatic or non-touch calls (viewport commands,
  // Flutter bridge, mouse pointers, virtual-window clamping) still arm, and
  // an already-established programmatic lock is always honored below.
  if (origin === 'touch' && isTouchNativeOwned && !scrollStopLock) return;
  if (!scrollStopLock) {
    scrollStopLock = true;
    scrollStopTop = timeline.scrollTop;
    scrollStopLeft = timeline.scrollLeft;
  }
  restoreScrollStopPosition();
  if (!scrollStopFrame) scrollStopFrame = requestAnimationFrame(enforceScrollStop);
}
function finishUserScrollWhenIdle() {
  if (touchActive || gestureActive) {
    userScrollTimer = setTimeout(finishUserScrollWhenIdle, 100);
    return;
  }
  userScrolling = false;
  sendViewportMetrics();
  if (!virtualWindowLoading) setRenderBlocked(false);
  flushMountedUpdates();
  scheduleMeasuredHeightReconcile();
  scheduleVirtualPrune();
}
function markUserScroll(realIntent = true) {
  const firstIntent = !userScrolling;
  if (realIntent || firstIntent) cancelInteractionLayout();
  if (firstIntent) {
    programmaticNavigationActive = false;
    viewportNavigation.cancel();
    navigationCursorId = null;
    navigationEdge = null;
    initialBottomPin = false;
    clearTimeout(bottomHoldTimer);
    bottomHoldTimer = null;
  }
  userScrolling = true;
  setRenderBlocked(true);
  if (firstIntent) sendViewportMetrics();
  clearTimeout(userScrollTimer);
  userScrollTimer = setTimeout(finishUserScrollWhenIdle, 800);
}
timeline.addEventListener('wheel', () => markUserScroll(true), { passive: true });
timeline.addEventListener('pointerdown', (event) => {
  gestureActive = true;
  gestureIntent = 'hold';
  pointerStartX = event.clientX;
  pointerStartY = event.clientY;
  stopScrolling(event.pointerType === 'touch' ? 'touch' : 'pointer');
}, { passive: true });
timeline.addEventListener('pointermove', (event) => {
  if (virtualWindowLoading) {
    restoreScrollStopPosition();
    return;
  }
  if (pointerStartX == null || pointerStartY == null) return;
  const intent = verticalGestureIntent({
    startX: pointerStartX,
    startY: pointerStartY,
    currentX: event.clientX,
    currentY: event.clientY,
  });
  if (intent === 'hold') return;
  gestureIntent = intent;
  releaseScrollStopLock();
  pointerStartX = null;
  pointerStartY = null;
  if (intent === 'vertical') markUserScroll();
}, { passive: true });
timeline.addEventListener('pointerup', () => {
  gestureActive = false;
  gestureIntent = 'idle';
  pointerStartX = null;
  pointerStartY = null;
  releaseScrollStopLock();
}, { passive: true });
timeline.addEventListener('pointercancel', () => {
  if (touchActive && gestureIntent === 'hold') return;
  gestureActive = false;
  gestureIntent = 'idle';
  pointerStartX = null;
  pointerStartY = null;
  releaseScrollStopLock();
}, { passive: true });
timeline.addEventListener('touchstart', (event) => {
  gestureActive = true;
  gestureIntent = 'hold';
  touchActive = true;
  stopScrolling('touch');
  setRenderBlocked(true);
  touchStartX = event.touches[0]?.clientX ?? null;
  touchStartY = event.touches[0]?.clientY ?? null;
}, { passive: true });
timeline.addEventListener('touchmove', (event) => {
  if (virtualWindowLoading) {
    restoreScrollStopPosition();
    if (!isTouchNativeOwned && event.cancelable) event.preventDefault();
    return;
  }
  const currentX = event.touches[0]?.clientX;
  const current = event.touches[0]?.clientY;
  if (touchStartX == null || touchStartY == null ||
      currentX == null || current == null) return;
  const intent = verticalGestureIntent({
    startX: touchStartX,
    startY: touchStartY,
    currentX,
    currentY: current,
  });
  if (intent === 'hold') {
    restoreScrollStopPosition();
    if (!isTouchNativeOwned && scrollStopLock && event.cancelable) {
      event.preventDefault();
    }
    return;
  }
  gestureIntent = intent;
  releaseScrollStopLock();
  touchStartX = null;
  touchStartY = null;
  if (intent === 'vertical') markUserScroll();
}, { passive: false });
timeline.addEventListener('touchend', () => {
  gestureActive = false;
  gestureIntent = 'idle';
  releaseScrollStopLock();
  touchActive = false;
  touchStartX = null;
  touchStartY = null;
  if (!userScrolling && !virtualWindowLoading) setRenderBlocked(false);
  flushMountedUpdates();
  scheduleMeasuredHeightReconcile();
}, { passive: true });
timeline.addEventListener('touchcancel', () => {
  gestureActive = false;
  gestureIntent = 'idle';
  releaseScrollStopLock();
  touchActive = false;
  touchStartX = null;
  touchStartY = null;
  if (!userScrolling && !virtualWindowLoading) setRenderBlocked(false);
  flushMountedUpdates();
  scheduleMeasuredHeightReconcile();
}, { passive: true });
timeline.addEventListener('scroll', () => {
  if (scrollStopLock) {
    restoreScrollStopPosition();
    return;
  }
  const attemptedTop = timeline.scrollTop;
  const direction = Math.sign(attemptedTop - lastTimelineScrollTop);
  lastTimelineScrollTop = attemptedTop;
  if (!programmaticNavigationActive && state?.messages?.length && renderedRange.start >= 0) {
    const coverage = coverageFor(attemptedTop);
    if (!coverage.covered) {
      navigationCursorId = null;
      navigationEdge = null;
      beginVirtualWindowLoad(coverage.requested, attemptedTop);
      return;
    }
    const viewport = Math.max(1, timeline.clientHeight);
    if (direction > 0 && coverage.max - attemptedTop <= viewport) {
      scheduleVirtualPrefetch(attemptedTop + viewport * 2);
    } else if (direction < 0 && attemptedTop - coverage.min <= viewport) {
      scheduleVirtualPrefetch(Math.max(0, attemptedTop - viewport * 2));
    }
  }
  if (userScrolling) markUserScroll(false);
  sendViewportMetrics();
  if (timeline.scrollTop < 180 && state?.hasMoreBefore) sendAction('loadMoreBefore');
  if (timeline.scrollHeight - timeline.scrollTop - timeline.clientHeight < 180 && state?.hasMoreAfter) sendAction('loadMoreAfter');
}, { passive: true });
timeline.addEventListener('keydown', (event) => {
  if (event.key === 'Home') {
    event.preventDefault();
    prepareProgrammaticNavigation();
    navigationCursorId = null;
    navigateToEdge('top');
  } else if (event.key === 'End') {
    event.preventDefault();
    prepareProgrammaticNavigation();
    navigationCursorId = null;
    navigateToEdge('bottom');
  } else if (event.key === 'PageUp') {
    markUserScroll();
    timeline.scrollBy({ top: -timeline.clientHeight * .85, behavior: 'smooth' });
  } else if (event.key === 'PageDown') {
    markUserScroll();
    timeline.scrollBy({ top: timeline.clientHeight * .85, behavior: 'smooth' });
  } else if (event.key === 'ArrowUp' || event.key === 'ArrowDown' ||
      event.key === ' ' || event.key === 'Spacebar') {
    markUserScroll();
  }
});
window.addEventListener('resize', requestRender);

function prepareProgrammaticNavigation() {
  cancelInteractionLayout();
  virtualWindowCoordinator.cancel();
  cancelVirtualPrefetch();
  programmaticNavigationActive = true;
  initialBottomPin = false;
  clearTimeout(bottomHoldTimer);
  bottomHoldTimer = null;
  releaseScrollStopLock();
  clearTimeout(userScrollTimer);
  userScrollTimer = null;
  userScrolling = false;
}

function handleViewportCommand(envelope) {
  const command = envelope.command;
  const payload = envelope.payload ?? {};
  // A bottom command may already be crossing the platform bridge when the
  // user starts a drag or opens a disclosure. That stale auto-follow must not
  // cancel the newer local intent and pull the viewport away.
  if (command === 'bottom' || command === 'holdBottom') {
    if (touchActive || gestureActive || pendingInteractionAnchor) return;
    if (userScrolling && payload.force !== true) return;
  }
  prepareProgrammaticNavigation();
  if (command === 'top') {
    navigationCursorId = null;
    navigateToEdge('top');
  } else if (command === 'bottom') {
    navigationCursorId = null;
    navigateToEdge('bottom');
  } else if (command === 'holdBottom') {
    navigationCursorId = null;
    navigateToEdge('bottom', { hold: true });
    const duration = Math.max(0, Math.min(2000, Number(payload.durationMs) || 0));
    bottomHoldTimer = setTimeout(() => {
      bottomHoldTimer = null;
      if (!userScrolling && navigationEdge === 'bottom') navigationEdge = null;
    }, duration);
  } else if (command === 'message') {
    navigationEdge = null;
    navigationCursorId = payload.messageId ?? null;
    if (!scrollToMessage(payload.messageId)) {
      bridge.post({ type: 'diagnostic', code: 'viewport_navigation_target_missing' });
    }
  } else if (command === 'previousQuestion') {
    jumpQuestion(-1);
  } else if (command === 'nextQuestion') {
    jumpQuestion(1);
  } else if (command === 'restoreAnchor') {
    navigationEdge = null;
    navigationCursorId = null;
    if (!restoreMessageAnchor(payload)) {
      bridge.post({ type: 'diagnostic', code: 'viewport_navigation_target_missing' });
    }
  }
}

function navigateToEdge(edge, { hold = false } = {}) {
  programmaticNavigationActive = true;
  navigationEdge = edge;
  const settle = edge === 'top'
    ? () => timeline.scrollTo({ top: 0, behavior: 'auto' })
    : () => timeline.scrollTo({ top: timeline.scrollHeight, behavior: 'auto' });
  const complete = () => {
    const remaining = timeline.scrollHeight - timeline.clientHeight - timeline.scrollTop;
    const settled = edge === 'top' ? timeline.scrollTop <= 1 : remaining <= 1;
    if (!settled) {
      bridge.post({ type: 'diagnostic', code: 'viewport_navigation_unsettled' });
    }
    if (!hold && navigationEdge === edge) {
      navigationEdge = null;
    }
    programmaticNavigationActive = false;
    sendViewportMetrics();
  };
  const coverage = coverageFor(edge === 'top' ? 0 : Number.POSITIVE_INFINITY);
  if (!coverage.covered) {
    beginVirtualWindowLoad(coverage.requested, coverage.requested, () => {
      settle();
      complete();
    });
    return;
  }
  settle();
  viewportNavigation.run(settle, complete);
}

function enforceNavigationEdge() {
  if (navigationEdge === 'top') {
    timeline.scrollTo({ top: 0, behavior: 'auto' });
  } else if (navigationEdge === 'bottom') {
    timeline.scrollTo({ top: timeline.scrollHeight, behavior: 'auto' });
  }
}

function restoreMessageAnchor(anchor) {
  programmaticNavigationActive = true;
  navigationEdge = null;
  const viewport = viewportForSavedAnchor({
    messageIds: (state?.messages ?? []).map((message) => message.id),
    heights: (state?.messages ?? []).map(messageHeight),
    anchor,
    viewportHeight: timeline.clientHeight,
  });
  if (!viewport) {
    programmaticNavigationActive = false;
    return false;
  }
  const complete = () => {
    if (!restoreAnchor(timeline, viewport.anchor)) {
      bridge.post({ type: 'diagnostic', code: 'viewport_navigation_unsettled' });
    }
    programmaticNavigationActive = false;
    sendViewportMetrics();
  };
  const coverage = coverageFor(viewport.scrollTop);
  if (!coverage.covered) {
    beginVirtualWindowLoad(coverage.requested, coverage.requested, complete);
    return true;
  }
  timeline.scrollTo({ top: viewport.scrollTop, behavior: 'auto' });
  viewportNavigation.run(
    () => restoreAnchor(timeline, viewport.anchor),
    complete,
  );
  return true;
}

function scrollToMessage(messageId) {
  programmaticNavigationActive = true;
  navigationEdge = null;
  const viewport = viewportForSavedAnchor({
    messageIds: (state?.messages ?? []).map((message) => message.id),
    heights: (state?.messages ?? []).map(messageHeight),
    anchor: { messageId, offset: 0 },
    viewportHeight: timeline.clientHeight,
  });
  if (!viewport) {
    programmaticNavigationActive = false;
    return false;
  }
  const complete = () => {
    if (!restoreAnchor(timeline, viewport.anchor)) {
      bridge.post({ type: 'diagnostic', code: 'viewport_navigation_unsettled' });
    }
    const target = timeline.querySelector(
      `[data-message-id="${CSS.escape(messageId)}"]`,
    );
    target?.focus({ preventScroll: true });
    programmaticNavigationActive = false;
    sendViewportMetrics();
  };
  const coverage = coverageFor(viewport.scrollTop);
  if (!coverage.covered) {
    beginVirtualWindowLoad(coverage.requested, coverage.requested, complete);
    return true;
  }
  timeline.scrollTo({ top: viewport.scrollTop, behavior: 'auto' });
  viewportNavigation.run(
    () => restoreAnchor(timeline, viewport.anchor),
    complete,
  );
  return true;
}

function jumpQuestion(delta) {
  navigationEdge = null;
  const messages = state?.messages ?? [];
  if (!messages.length) {
    programmaticNavigationActive = false;
    return;
  }
  const anchor = captureAnchor(timeline);
  let index = messages.findIndex((message) => message.id === navigationCursorId);
  if (index < 0) index = messages.findIndex((message) => message.id === anchor?.id);
  if (index < 0) {
    index = messageIndexAtOffset(messages.map(messageHeight), timeline.scrollTop);
  }
  const next = index + delta;
  if (next < 0 || next >= messages.length) {
    navigationCursorId = null;
    programmaticNavigationActive = false;
    return;
  }
  navigationCursorId = messages[next].id;
  scrollToMessage(navigationCursorId);
}

function handleMessagePatches(envelope) {
  if (!state || envelope.renderSessionId !== state.renderSessionId ||
      envelope.conversationId !== state.conversationId) return;
  const patches = (envelope.patches ?? []).map((patch) => {
    const { remoteMediaHandles, ...messagePatch } = patch;
    if (remoteMediaHandles && typeof remoteMediaHandles === 'object') {
      state = {
        ...state,
        remoteMediaHandles: {
          ...(state.remoteMediaHandles ?? {}),
          ...remoteMediaHandles,
        },
      };
    }
    return messagePatch;
  });
  const previousById = new Map(state.messages.map((message) => [message.id, message]));
  const nextState = reduceEnvelope(state, { ...envelope, patches });
  state = nextState;
  const nextById = new Map(state.messages.map((message) => [message.id, message]));
  for (const patch of patches) {
    const id = patch.id?.toString();
    const previous = previousById.get(id);
    const next = nextById.get(id);
    if (!id || !previous || !next) continue;
    if (Number.isInteger(patch.streamRevision) &&
        next.streamRevision !== patch.streamRevision) {
      bridge.post({ type: 'diagnostic', code: 'stream_patch_stale' });
      continue;
    }
    const target = String(next.content ?? '');
    const displayed = presentedStreamContent.get(id) ?? String(previous.content ?? '');
    if (!mountedSlots.get(id)?.isConnected) {
      streamPresenter.cancel(id);
      presentedStreamContent.set(id, target);
      continue;
    }
    const contentChanged = target !== displayed;
    if (next.isStreaming !== true) {
      streamPresenter.update({ id, displayed, target, final: true });
      continue;
    }
    if (contentChanged) {
      streamPresenter.update({
        id,
        displayed,
        target,
        final: false,
      });
    }
    const structuralChange = streamStructureSignature(previous) !==
      streamStructureSignature(next);
    if (!contentChanged || structuralChange) updateMountedMessage(id);
  }
}

function handleMediaResult(payload) {
  if (!state || payload.renderSessionId !== state.renderSessionId ||
      payload.conversationId !== state.conversationId) return;
  state = {
    ...state,
    media: { ...(state.media ?? {}), [payload.handle]: payload.dataUrl },
  };
  pendingMedia.delete(payload.handle);
  const transferFamilies = fontFaceTracker.takeTransfer(payload.handle);
  if (transferFamilies?.size) {
    registerFontFaces(payload.handle, transferFamilies, payload.dataUrl);
  }
  for (const image of document.querySelectorAll('img[data-media-handle]')) {
    if (image.dataset.mediaHandle === payload.handle) image.src = payload.dataUrl;
  }
  applyTheme();
  const userAvatar = state.user?.avatar === payload.handle;
  const assistantAvatar = state.assistant?.avatar === payload.handle;
  for (const message of state.messages ?? []) {
    const affected = message.modelIcon === payload.handle ||
      (userAvatar && message.role === 'user') ||
      (assistantAvatar && message.role !== 'user') ||
      (message.attachments ?? []).some(
        (attachment) => attachment.reference === payload.handle,
      );
    if (affected) updateMountedMessage(message.id);
  }
  if (PRINT_MODE) maybeSchedulePrintComplete();
}

window.CuplivoWeb = {
  stopScrolling,
  receive(raw) {
    try {
      const envelope = typeof raw === 'string' ? JSON.parse(raw) : raw;
      if (envelope.type === 'transferChunk') {
        const payload = receiveTransferChunk(envelope);
        if (!payload) return;
        if (payload.type === 'mediaResult') {
          handleMediaResult(payload);
        } else {
          const previousSessionId = state?.renderSessionId;
          const previousConversationId = state?.conversationId;
          state = reduceEnvelope(state, payload);
          if (previousSessionId &&
              (previousSessionId !== state?.renderSessionId ||
                previousConversationId !== state?.conversationId)) {
            viewportNavigation.cancel();
            virtualWindowCoordinator.cancel();
            streamPresenter.clear();
            navigationCursorId = null;
            navigationEdge = null;
            initialBottomPin = false;
            programmaticNavigationActive = false;
            clearTimeout(bottomHoldTimer);
            bottomHoldTimer = null;
            expansionCoordinator.clear();
            localExpansions.clear();
            pendingActions.clear();
            pendingMedia.clear();
            fontRegistrator.removeAll(document.fonts);
            fontFaceTracker.reset();
            heights.clear();
            pendingMeasuredHeights.clear();
            mountedSlots.clear();
            presentedStreamContent.clear();
            pendingMountedUpdates.clear();
            pendingRendererRenders.clear();
            pendingRendererRefreshes.clear();
            pendingMermaidCommits.clear();
            if (rendererRefreshFrame) cancelAnimationFrame(rendererRefreshFrame);
            rendererRefreshFrame = 0;
            markdownHtmlCache.clear();
            measuredHeightsPending = false;
            cancelInteractionLayout();
            renderCommitCoordinator.clear();
            cancelVirtualPrefetch();
            clearTimeout(virtualPruneTimer);
          }
          for (const message of state?.messages ?? []) {
            if (message.isStreaming !== true) {
              streamPresenter.cancel(message.id);
              presentedStreamContent.delete(message.id);
            }
          }
          requestRender();
        }
      } else if (envelope.type === 'messagePatches') {
        handleMessagePatches(envelope);
      } else if (envelope.type === 'actionResult') {
        pendingActions.delete(envelope.requestId);
        if (expansionCoordinator.resolve(envelope.requestId, envelope.ok === true)) {
          requestRender();
        }
      }
      else if (envelope.type === 'mediaError' && state &&
          envelope.renderSessionId === state.renderSessionId &&
          envelope.conversationId === state.conversationId) {
        pendingMedia.delete(envelope.handle);
        if (envelope.code === 'inactive') {
          fontFaceTracker.cancel(envelope.handle);
        } else {
          fontFaceTracker.failTransfer(envelope.handle);
        }
      }
      else if (envelope.type === 'viewportCommand') handleViewportCommand(envelope);
    } catch (error) {
      bridge.post({
        type: 'diagnostic',
        code: safeDiagnosticCode(error, 'receive_failed'),
      });
    }
  },
};
window.chrome?.webview?.addEventListener('message', (event) => window.CuplivoWeb.receive(event.data));
bridge.post({ type: 'ready', protocolVersion: PROTOCOL_VERSION, assetVersion: ASSET_VERSION });
