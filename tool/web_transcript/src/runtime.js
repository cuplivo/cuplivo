import katexPlugin from "@vscode/markdown-it-katex";
import createDOMPurify from "dompurify";
import hljs from "highlight.js/lib/common";
import katex from "katex";
import MarkdownIt from "markdown-it";
import taskLists from "markdown-it-task-lists";

export const PROTOCOL_VERSION = 1;
const MAX_RESOURCE_BYTES = 32 * 1024 * 1024;
const MAX_RESOURCE_CHUNKS = 4096;
const SOURCE_ONLY_LANGUAGES = new Set([
  "html",
  "htm",
  "mermaid",
  "plantuml",
  "puml",
  "raw_html",
  "rawhtml",
  "svg",
]);
const THEME_COLOR_KEYS = new Map([
  ["background", "--transcript-background"],
  ["foreground", "--transcript-foreground"],
  ["muted", "--transcript-muted"],
  ["accent", "--transcript-accent"],
  ["codeBackground", "--transcript-code-background"],
  ["border", "--transcript-border"],
]);

function decodeBase64(window, encoded) {
  if (typeof encoded !== "string" || encoded.length === 0) {
    throw new ProtocolError("invalid_base64", "Command must be base64 text");
  }
  let binary;
  try {
    binary = window.atob(encoded);
  } catch {
    throw new ProtocolError("invalid_base64", "Command is not valid base64");
  }
  const bytes = Uint8Array.from(binary, (character) => character.charCodeAt(0));
  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    throw new ProtocolError("invalid_utf8", "Command is not valid UTF-8");
  }
}

function decodeBase64Bytes(window, encoded) {
  if (typeof encoded !== "string") {
    throw new ProtocolError("invalid_resource", "Resource chunk must be base64 text");
  }
  let binary;
  try {
    binary = window.atob(encoded);
  } catch {
    throw new ProtocolError("invalid_resource", "Resource chunk is not valid base64");
  }
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

class ProtocolError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

function requireObject(value, name) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new ProtocolError("invalid_command", `${name} must be an object`);
  }
  return value;
}

function requireString(value, name) {
  if (typeof value !== "string" || value.length === 0) {
    throw new ProtocolError("invalid_command", `${name} must be a non-empty string`);
  }
  return value;
}

function normalizeMessage(value) {
  const message = requireObject(value, "message");
  const actions = Array.isArray(message.actions)
    ? message.actions
        .filter(
          (action) =>
            action &&
            typeof action === "object" &&
            typeof action.type === "string" &&
            typeof action.label === "string",
        )
        .map((action) => ({
          type: action.type,
          label: action.label,
          value: typeof action.value === "string" ? action.value : null,
        }))
    : [];
  return {
    id: requireString(message.id, "message.id"),
    role: typeof message.role === "string" ? message.role : "assistant",
    markdown: typeof message.markdown === "string" ? message.markdown : "",
    format: message.format === "plain" ? "plain" : "markdown",
    displayName: typeof message.displayName === "string" ? message.displayName : "",
    timestamp: typeof message.timestamp === "string" ? message.timestamp : "",
    timestampIso:
      typeof message.timestampIso === "string" ? message.timestampIso : "",
    actions,
    streaming: message.streaming === true,
    selected: message.selected === true,
    spotlight: message.spotlight === true,
  };
}

function createMarkdownRenderer(window) {
  const purifier = createDOMPurify(window);
  const markdown = new MarkdownIt({
    breaks: true,
    html: false,
    linkify: true,
    typographer: false,
    highlight(code, language) {
      if (language && hljs.getLanguage(language)) {
        try {
          return hljs.highlight(code, { language, ignoreIllegals: true }).value;
        } catch {
          return "";
        }
      }
      return "";
    },
  });
  markdown.use(taskLists, { enabled: false, label: true, labelAfter: true });
  markdown.use(katexPlugin.default, { katex, throwOnError: false });

  const defaultFence = markdown.renderer.rules.fence;
  markdown.renderer.rules.fence = (tokens, index, options, env, self) => {
    const token = tokens[index];
    const language = token.info.trim().split(/\s+/u)[0].toLowerCase();
    if (!SOURCE_ONLY_LANGUAGES.has(language)) {
      return defaultFence(tokens, index, options, env, self);
    }
    const escapedLanguage = markdown.utils.escapeHtml(language);
    const escapedCode = markdown.utils.escapeHtml(token.content);
    return `<pre class="code-fallback" data-code-language="${escapedLanguage}"><code>${escapedCode}</code></pre>\n`;
  };

  const defaultImage = markdown.renderer.rules.image;
  markdown.renderer.rules.image = (tokens, index, options, env, self) => {
    const token = tokens[index];
    const source = token.attrGet("src");
    if (source?.startsWith("cuplivo-resource://")) {
      token.attrSet("data-resource-id", source.slice("cuplivo-resource://".length));
      token.attrSet("src", "");
    }
    return defaultImage(tokens, index, options, env, self);
  };

  const defaultLinkOpen = markdown.renderer.rules.link_open;
  markdown.renderer.rules.link_open = (tokens, index, options, env, self) => {
    const token = tokens[index];
    const href = token.attrGet("href");
    if (href?.startsWith("cuplivo-resource://")) {
      token.attrSet("data-resource-id", href.slice("cuplivo-resource://".length));
      token.attrSet("href", "");
    }
    return defaultLinkOpen(tokens, index, options, env, self);
  };

  return (source) =>
    purifier.sanitize(markdown.render(source), {
      ALLOW_DATA_ATTR: true,
      FORBID_TAGS: ["button", "form", "iframe", "object", "script", "style"],
      USE_PROFILES: { html: true, mathMl: true },
    });
}

function makeMessageElement(document, message, renderMarkdown) {
  const element = document.createElement("article");
  element.className = "message";
  element.dataset.messageId = message.id;

  const header = document.createElement("header");
  header.className = "message-header";
  const name = document.createElement("span");
  name.className = "message-name";
  const timestamp = document.createElement("time");
  timestamp.className = "message-time";
  header.append(name, timestamp);

  const content = document.createElement("div");
  content.className = "message-content markdown-body";

  const actions = document.createElement("footer");
  actions.className = "message-actions";
  element.append(header, content, actions);
  updateMessageElement(element, message, renderMarkdown);
  return element;
}

function updateMessageElement(element, message, renderMarkdown) {
  element.dataset.role = message.role;
  element.dataset.streaming = String(message.streaming);
  element.dataset.selected = String(message.selected);
  element.dataset.spotlight = String(message.spotlight);
  element.querySelector(".message-name").textContent = message.displayName;
  const time = element.querySelector(".message-time");
  time.textContent = message.timestamp;
  time.dateTime = message.timestampIso;
  element.querySelector(".message-header").hidden =
    message.displayName.length === 0 && message.timestamp.length === 0;
  const content = element.querySelector(".message-content");
  if (message.format === "plain") {
    content.textContent = message.markdown;
  } else {
    content.innerHTML = renderMarkdown(message.markdown);
  }
  const actions = element.querySelector(".message-actions");
  actions.replaceChildren();
  for (const action of message.actions) {
    const button = element.ownerDocument.createElement("button");
    button.type = "button";
    button.dataset.action = action.type;
    if (action.value !== null) {
      button.dataset.actionValue = action.value;
    }
    button.textContent = action.label;
    actions.append(button);
  }
}

export function createTranscriptRuntime(window, options = {}) {
  const { document } = window;
  const transcript = options.transcript ?? document.getElementById("transcript");
  if (!transcript) {
    throw new Error("Missing #transcript root");
  }

  const renderMarkdown = createMarkdownRenderer(window);
  const messages = new Map();
  const resources = new Map();
  const requestedResources = new Set();
  const pendingMessagePatches = new Map();
  const pendingEvents = [];
  let currentEpoch = -1;
  let viewportScheduled = false;
  let scrolling = false;
  let scrollIdleTimer;
  let mathEnabled = true;
  let dollarMathEnabled = true;
  let autoScrollEnabled = true;
  let backgroundResourceId;

  function renderConfiguredMarkdown(source) {
    let configured = source;
    if (!mathEnabled) {
      configured = configured
        .replaceAll("$", "\\$")
        .replaceAll("\\(", "\\\\(")
        .replaceAll("\\)", "\\\\)")
        .replaceAll("\\[", "\\\\[")
        .replaceAll("\\]", "\\\\]");
    } else if (!dollarMathEnabled) {
      configured = configured.replaceAll("$", "\\$");
    }
    return renderMarkdown(configured);
  }

  function bridge() {
    return options.bridge ?? window.CuplivoBridge;
  }

  function emit(type, payload = {}, command = undefined) {
    const event = {
      version: PROTOCOL_VERSION,
      type,
      epoch: currentEpoch,
      payload,
    };
    if (command?.id !== undefined) {
      event.commandId = command.id;
    }
    const target = bridge();
    if (!target || typeof target.postMessage !== "function") {
      pendingEvents.push(event);
      return;
    }
    while (pendingEvents.length > 0) {
      target.postMessage(JSON.stringify(pendingEvents.shift()));
    }
    target.postMessage(JSON.stringify(event));
  }

  function revokeResource(resource) {
    if (resource?.url) {
      window.URL.revokeObjectURL(resource.url);
    }
  }

  function clearResources() {
    for (const resource of resources.values()) {
      revokeResource(resource);
    }
    resources.clear();
    requestedResources.clear();
  }

  function hydrateResources(root = transcript) {
    for (const element of root.querySelectorAll("[data-resource-id]")) {
      const resourceId = element.dataset.resourceId;
      const resource = resources.get(resourceId);
      if (!resource?.url && element.tagName === "IMG") {
        if (!requestedResources.has(resourceId)) {
          requestedResources.add(resourceId);
          emit("resourceRequest", { resourceId });
        }
        continue;
      }
      if (element.tagName === "IMG") {
        element.src = resource.url;
      } else if (element.tagName === "A") {
        element.href = resource.url;
      }
    }
    if (backgroundResourceId) {
      const background = resources.get(backgroundResourceId);
      if (background?.url) {
        document.documentElement.style.setProperty(
          "--transcript-background-image",
          `url("${background.url}")`,
        );
      } else if (!requestedResources.has(backgroundResourceId)) {
        requestedResources.add(backgroundResourceId);
        emit("resourceRequest", { resourceId: backgroundResourceId });
      }
    }
  }

  function firstVisibleAnchor() {
    for (const state of messages.values()) {
      const rect = state.element.getBoundingClientRect();
      if (rect.bottom >= 0) {
        return { messageId: state.message.id, offset: rect.top };
      }
    }
    return null;
  }

  function restoreAnchor(anchor) {
    if (!anchor) {
      return;
    }
    const state = messages.get(anchor.messageId);
    if (!state) {
      return;
    }
    const delta = state.element.getBoundingClientRect().top - anchor.offset;
    if (delta !== 0) {
      scrollElement().scrollTop += delta;
    }
  }

  function reconcileTranscript(nextMessages) {
    const anchor = firstVisibleAnchor();
    const wasAtBottom = isAtBottom();
    const retained = new Set();
    for (const message of nextMessages) {
      retained.add(message.id);
      let state = messages.get(message.id);
      if (!state) {
        state = {
          element: makeMessageElement(document, message, renderConfiguredMarkdown),
          message,
        };
        messages.set(message.id, state);
      } else if (JSON.stringify(state.message) !== JSON.stringify(message)) {
        updateMessageElement(state.element, message, renderConfiguredMarkdown);
        state.message = message;
      }
      transcript.append(state.element);
      hydrateResources(state.element);
    }
    for (const [id, state] of messages) {
      if (!retained.has(id)) {
        state.element.remove();
        messages.delete(id);
      }
    }
    if (wasAtBottom && autoScrollEnabled) {
      scrollElement().scrollTop = scrollElement().scrollHeight;
    } else {
      restoreAnchor(anchor);
    }
    hydrateResources();
  }

  function hasActiveSelection() {
    const selection = window.getSelection?.();
    return Boolean(selection && !selection.isCollapsed && selection.toString());
  }

  function canApplyStreamingPatch() {
    return !scrolling && !hasActiveSelection();
  }

  function applyMessagePatch(message) {
    const state = messages.get(message.id);
    if (!state) {
      throw new ProtocolError("unknown_message", `Unknown message id: ${message.id}`);
    }
    const wasAtBottom = isAtBottom();
    updateMessageElement(state.element, message, renderConfiguredMarkdown);
    state.message = message;
    hydrateResources(state.element);
    if (wasAtBottom && autoScrollEnabled) {
      scrollElement().scrollTop = scrollElement().scrollHeight;
    }
  }

  function flushPendingMessagePatches() {
    if (!canApplyStreamingPatch()) {
      return;
    }
    for (const message of pendingMessagePatches.values()) {
      applyMessagePatch(message);
    }
    pendingMessagePatches.clear();
  }

  function assertEpoch(command, { establish = false } = {}) {
    if (!Number.isSafeInteger(command.epoch) || command.epoch < 0) {
      throw new ProtocolError("invalid_epoch", "epoch must be a non-negative integer");
    }
    if (establish) {
      if (command.epoch < currentEpoch) {
        throw new ProtocolError("stale_epoch", "Command epoch is stale");
      }
      if (command.epoch > currentEpoch) {
        clearResources();
        currentEpoch = command.epoch;
      }
      return;
    }
    if (command.epoch !== currentEpoch) {
      throw new ProtocolError("stale_epoch", "Command epoch is not current");
    }
  }

  function applyTheme(payload) {
    const theme = requireObject(payload, "payload");
    if (theme.scheme !== "light" && theme.scheme !== "dark") {
      throw new ProtocolError("invalid_theme", "theme.scheme must be light or dark");
    }
    const validatedColors = [];
    if (theme.colors !== undefined) {
      const colors = requireObject(theme.colors, "theme.colors");
      for (const [key, value] of Object.entries(colors)) {
        const property = THEME_COLOR_KEYS.get(key);
        if (!property || typeof value !== "string" || !/^#[0-9a-f]{3,8}$/iu.test(value)) {
          throw new ProtocolError("invalid_theme", `Invalid theme color: ${key}`);
        }
        validatedColors.push([property, value]);
      }
    }
    if (theme.fontScale !== undefined) {
      if (
        typeof theme.fontScale !== "number" ||
        theme.fontScale < 0.75 ||
        theme.fontScale > 2
      ) {
        throw new ProtocolError("invalid_theme", "theme.fontScale must be between 0.75 and 2");
      }
    }
    for (const [key, property] of [
      ["topPadding", "--transcript-top-padding"],
      ["bottomPadding", "--transcript-bottom-padding"],
    ]) {
      if (theme[key] === undefined) continue;
      if (
        typeof theme[key] !== "number" ||
        !Number.isFinite(theme[key]) ||
        theme[key] < 0 ||
        theme[key] > 500
      ) {
        throw new ProtocolError("invalid_theme", `${key} must be between 0 and 500`);
      }
      document.documentElement.style.setProperty(property, `${theme[key]}px`);
    }
    if (theme.backgroundMask !== undefined) {
      if (
        typeof theme.backgroundMask !== "number" ||
        theme.backgroundMask < 0 ||
        theme.backgroundMask > 2
      ) {
        throw new ProtocolError(
          "invalid_theme",
          "theme.backgroundMask must be between 0 and 2",
        );
      }
      document.documentElement.style.setProperty(
        "--transcript-background-mask",
        String(Math.min(0.85, 0.25 + theme.backgroundMask * 0.25)),
      );
    }
    if (theme.languageCode !== undefined) {
      if (
        typeof theme.languageCode !== "string" ||
        !/^[a-z]{2,3}(?:-[a-z0-9]{2,8})*$/iu.test(theme.languageCode)
      ) {
        throw new ProtocolError("invalid_theme", "Invalid languageCode");
      }
      document.documentElement.lang = theme.languageCode;
    }
    for (const [key, property] of [
      ["fontFamily", "--transcript-font-family"],
      ["codeFontFamily", "--transcript-code-font-family"],
    ]) {
      if (theme[key] === undefined || theme[key] === null || theme[key] === "") {
        document.documentElement.style.removeProperty(property);
        continue;
      }
      if (
        typeof theme[key] !== "string" ||
        theme[key].length > 100 ||
        /["';{}]/u.test(theme[key])
      ) {
        throw new ProtocolError("invalid_theme", `Invalid ${key}`);
      }
      document.documentElement.style.setProperty(property, `"${theme[key]}"`);
    }
    if (
      theme.backgroundResourceId !== undefined &&
      theme.backgroundResourceId !== null
    ) {
      backgroundResourceId = requireString(
        theme.backgroundResourceId,
        "theme.backgroundResourceId",
      );
    } else {
      backgroundResourceId = undefined;
      document.documentElement.style.removeProperty(
        "--transcript-background-image",
      );
    }

    document.documentElement.dataset.theme = theme.scheme;
    for (const [property, value] of validatedColors) {
      document.documentElement.style.setProperty(property, value);
    }
    if (theme.fontScale !== undefined) {
      document.documentElement.style.setProperty(
        "--transcript-font-scale",
        String(theme.fontScale),
      );
    }
    hydrateResources();
  }

  function acceptResourceChunk(payload) {
    const chunk = requireObject(payload, "payload");
    const resourceId = requireString(chunk.resourceId, "resourceId");
    const transferId = requireString(chunk.transferId, "transferId");
    if (
      !Number.isSafeInteger(chunk.index) ||
      !Number.isSafeInteger(chunk.totalChunks) ||
      chunk.index < 0 ||
      chunk.totalChunks < 1 ||
      chunk.totalChunks > MAX_RESOURCE_CHUNKS ||
      chunk.index >= chunk.totalChunks
    ) {
      throw new ProtocolError("invalid_resource", "Invalid resource chunk index");
    }
    if (
      typeof chunk.mimeType !== "string" ||
      !/^[a-z0-9][a-z0-9.+-]*\/[a-z0-9][a-z0-9.+-]*$/iu.test(chunk.mimeType)
    ) {
      throw new ProtocolError("invalid_resource", "Invalid resource MIME type");
    }

    let resource = resources.get(resourceId);
    if (!resource || resource.transferId !== transferId) {
      revokeResource(resource);
      resource = {
        transferId,
        mimeType: chunk.mimeType,
        totalChunks: chunk.totalChunks,
        chunks: new Array(chunk.totalChunks),
        receivedChunks: 0,
        bytes: 0,
        url: undefined,
      };
      resources.set(resourceId, resource);
    } else if (
      resource.totalChunks !== chunk.totalChunks ||
      resource.mimeType !== chunk.mimeType
    ) {
      throw new ProtocolError("invalid_resource", "Resource metadata changed during transfer");
    }

    if (resource.url) {
      return;
    }

    const bytes = decodeBase64Bytes(window, chunk.data);
    const previousLength = resource.chunks[chunk.index]?.length ?? 0;
    const nextSize = resource.bytes - previousLength + bytes.length;
    if (nextSize > MAX_RESOURCE_BYTES) {
      throw new ProtocolError("resource_too_large", "Resource exceeds 32 MiB");
    }
    if (!resource.chunks[chunk.index]) {
      resource.receivedChunks += 1;
    }
    resource.chunks[chunk.index] = bytes;
    resource.bytes = nextSize;

    if (resource.receivedChunks === resource.totalChunks) {
      revokeResource(resource);
      resource.url = window.URL.createObjectURL(
        new window.Blob(resource.chunks, { type: resource.mimeType }),
      );
      hydrateResources();
      emit("resourceReady", { resourceId, url: resource.url });
    }
  }

  function scrollElement() {
    return document.scrollingElement ?? document.documentElement;
  }

  function commandHandlers(command) {
    const payload = command.payload ?? {};
    switch (command.type) {
      case "hello":
        assertEpoch(command, { establish: true });
        emit(
          "hello",
          {
            protocolVersion: PROTOCOL_VERSION,
            capabilities: [
              "keyedMessages",
              "markdown",
              "katex",
              "resourceChunks",
              "nativeSelection",
              "viewportEvents",
            ],
            exclusions: ["pdf", "rawHtml", "remoteAssets"],
          },
          command,
        );
        break;
      case "replaceTranscript": {
        const body = requireObject(payload, "payload");
        if (!Array.isArray(body.messages)) {
          throw new ProtocolError("invalid_command", "payload.messages must be an array");
        }
        const nextMessages = body.messages.map(normalizeMessage);
        const messageIds = new Set();
        for (const message of nextMessages) {
          if (messageIds.has(message.id)) {
            throw new ProtocolError(
              "duplicate_message",
              `Duplicate message id: ${message.id}`,
            );
          }
          messageIds.add(message.id);
        }
        assertEpoch(command, { establish: true });
        reconcileTranscript(nextMessages);
        break;
      }
      case "patchMessage": {
        assertEpoch(command);
        const message = normalizeMessage(requireObject(payload, "payload").message);
        if (message.streaming && !canApplyStreamingPatch()) {
          pendingMessagePatches.set(message.id, message);
        } else {
          pendingMessagePatches.delete(message.id);
          applyMessagePatch(message);
        }
        break;
      }
      case "theme":
        assertEpoch(command);
        applyTheme(payload);
        break;
      case "renderSettings": {
        assertEpoch(command);
        const body = requireObject(payload, "payload");
        if (body.mathEnabled !== undefined && typeof body.mathEnabled !== "boolean") {
          throw new ProtocolError(
            "invalid_settings",
            "renderSettings.mathEnabled must be boolean",
          );
        }
        mathEnabled = body.mathEnabled ?? true;
        if (
          body.dollarMathEnabled !== undefined &&
          typeof body.dollarMathEnabled !== "boolean"
        ) {
          throw new ProtocolError(
            "invalid_settings",
            "renderSettings.dollarMathEnabled must be boolean",
          );
        }
        if (
          body.autoScrollEnabled !== undefined &&
          typeof body.autoScrollEnabled !== "boolean"
        ) {
          throw new ProtocolError(
            "invalid_settings",
            "renderSettings.autoScrollEnabled must be boolean",
          );
        }
        dollarMathEnabled = body.dollarMathEnabled ?? true;
        autoScrollEnabled = body.autoScrollEnabled ?? true;
        for (const state of messages.values()) {
          updateMessageElement(
            state.element,
            state.message,
            renderConfiguredMarkdown,
          );
        }
        hydrateResources();
        break;
      }
      case "scrollToBottom":
        assertEpoch(command);
        scrollElement().scrollTop = scrollElement().scrollHeight;
        break;
      case "scrollToTop":
        assertEpoch(command);
        scrollElement().scrollTop = 0;
        break;
      case "scrollToMessage": {
        assertEpoch(command);
        const body = requireObject(payload, "payload");
        const state = messages.get(requireString(body.messageId, "messageId"));
        if (!state) {
          throw new ProtocolError("unknown_message", "Cannot scroll to an unknown message");
        }
        const allowedAlignments = new Set(["start", "center", "end", "nearest"]);
        const block = body.block ?? "nearest";
        if (!allowedAlignments.has(block)) {
          throw new ProtocolError("invalid_command", "Invalid scroll alignment");
        }
        state.element.scrollIntoView({ behavior: "auto", block });
        break;
      }
      case "scrollBy": {
        assertEpoch(command);
        const body = requireObject(payload, "payload");
        if (typeof body.delta !== "number" || !Number.isFinite(body.delta)) {
          throw new ProtocolError("invalid_command", "scrollBy.delta must be finite");
        }
        scrollElement().scrollTop += body.delta;
        break;
      }
      case "resourceChunk":
        assertEpoch(command);
        acceptResourceChunk(payload);
        break;
      case "releaseResource": {
        assertEpoch(command);
        const resourceId = requireString(
          requireObject(payload, "payload").resourceId,
          "resourceId",
        );
        const resource = resources.get(resourceId);
        revokeResource(resource);
        resources.delete(resourceId);
        for (const element of transcript.querySelectorAll("[data-resource-id]")) {
          if (element.dataset.resourceId === resourceId) {
            element.removeAttribute(element.tagName === "IMG" ? "src" : "href");
          }
        }
        break;
      }
      default:
        throw new ProtocolError("unknown_command", `Unknown command: ${command.type}`);
    }
  }

  function postCommand(encoded) {
    let command;
    try {
      command = JSON.parse(decodeBase64(window, encoded));
      requireObject(command, "command");
      if (command.version !== PROTOCOL_VERSION) {
        throw new ProtocolError("unsupported_version", "Unsupported protocol version");
      }
      requireString(command.id, "command.id");
      requireString(command.type, "command.type");
      commandHandlers(command);
      emit("ack", { commandType: command.type }, command);
    } catch (error) {
      emit(
        "error",
        {
          code: error instanceof ProtocolError ? error.code : "invalid_command",
          message: error instanceof Error ? error.message : String(error),
        },
        command,
      );
    }
  }

  function emitViewport() {
    viewportScheduled = false;
    const scrollRoot = scrollElement();
    const viewportHeight = window.innerHeight;
    emit("viewport", {
      scrollTop: scrollRoot.scrollTop,
      viewportHeight,
      contentHeight: scrollRoot.scrollHeight,
      atBottom:
        scrollRoot.scrollHeight - scrollRoot.scrollTop - viewportHeight <= 2,
      atTop: scrollRoot.scrollTop <= 2,
      isScrolling: scrolling,
      firstVisibleMessageId: firstVisibleAnchor()?.messageId ?? null,
      firstVisibleOffset: firstVisibleAnchor()?.offset ?? 0,
    });
  }

  function isAtBottom() {
    const element = scrollElement();
    return element.scrollHeight - element.scrollTop - window.innerHeight <= 2;
  }

  function scheduleViewport() {
    if (viewportScheduled) {
      return;
    }
    viewportScheduled = true;
    const schedule = window.requestAnimationFrame ?? window.setTimeout;
    schedule.call(window, emitViewport);
  }

  transcript.addEventListener("click", (event) => {
    const target = event.target.closest?.(
      "button[data-action], a, img[data-resource-id]",
    );
    if (!target) {
      return;
    }
    if (target.tagName === "BUTTON") {
      const message = target.closest("article[data-message-id]");
      emit("action", {
        action: target.dataset.action,
        value: target.dataset.actionValue ?? null,
        messageId: message?.dataset.messageId ?? null,
      });
    } else if (target.tagName === "A") {
      event.preventDefault();
      emit("action", {
        action: "openLink",
        href: target.getAttribute("href") ?? "",
        resourceId: target.dataset.resourceId ?? null,
      });
    } else {
      emit("action", {
        action: "openResource",
        resourceId: target.dataset.resourceId,
      });
    }
  });
  window.addEventListener(
    "scroll",
    () => {
      scrolling = true;
      window.clearTimeout(scrollIdleTimer);
      scrollIdleTimer = window.setTimeout(() => {
        scrolling = false;
        flushPendingMessagePatches();
        scheduleViewport();
      }, 120);
      scheduleViewport();
    },
    { passive: true },
  );
  window.addEventListener("resize", scheduleViewport, { passive: true });
  document.addEventListener("selectionchange", flushPendingMessagePatches);

  const api = Object.freeze({ postCommand });
  window.CuplivoTranscript = api;
  emit("ready", { protocolVersion: PROTOCOL_VERSION });
  return api;
}
