import assert from "node:assert/strict";
import test from "node:test";
import { JSDOM } from "jsdom";
import { createTranscriptRuntime } from "../src/runtime.js";

function encodeCommand(command) {
  return Buffer.from(JSON.stringify(command), "utf8").toString("base64");
}

function setup() {
  const dom = new JSDOM("<!doctype html><main id=\"transcript\"></main>", {
    url: "https://renderer.invalid/",
  });
  const events = [];
  const createdUrls = [];
  const revokedUrls = [];
  dom.window.URL.createObjectURL = () => {
    const url = `blob:test-${createdUrls.length + 1}`;
    createdUrls.push(url);
    return url;
  };
  dom.window.URL.revokeObjectURL = (url) => revokedUrls.push(url);
  const api = createTranscriptRuntime(dom.window, {
    bridge: {
      postMessage(value) {
        events.push(JSON.parse(value));
      },
    },
  });
  events.length = 0;
  return { api, dom, events, createdUrls, revokedUrls };
}

function send(context, type, payload = {}, epoch = 1, id = type) {
  context.api.postCommand(
    encodeCommand({ version: 1, id, type, epoch, payload }),
  );
}

function replace(context, markdown, epoch = 1) {
  send(context, "replaceTranscript", {
    messages: [{ id: "m1", role: "assistant", markdown }],
  }, epoch);
}

test("renders GFM tables and task lists", () => {
  const context = setup();
  replace(context, "| A | B |\n| - | - |\n| 1 | 2 |\n\n- [x] done");

  const document = context.dom.window.document;
  assert.equal(document.querySelector("table td")?.textContent, "1");
  const checkbox = document.querySelector('input[type="checkbox"]');
  assert.equal(checkbox?.checked, true);
  assert.equal(checkbox?.disabled, true);
});

test("renders inline and display KaTeX", () => {
  const context = setup();
  replace(context, "Inline $x^2$\n\n$$y = mx + b$$");

  const document = context.dom.window.document;
  assert.ok(document.querySelector(".katex"));
  assert.ok(document.querySelector(".katex-display"));
});

test("escapes raw HTML, sanitizes unsafe links, and keeps risky fences source-only", () => {
  const context = setup();
  replace(
    context,
    '<img src=x onerror="alert(1)"> [bad](javascript:alert(1))\n\n```svg\n<svg onload="alert(1)"></svg>\n```',
  );

  const document = context.dom.window.document;
  assert.equal(document.querySelector(".message-content > img"), null);
  assert.equal(document.querySelector("a")?.getAttribute("href") ?? null, null);
  assert.equal(document.querySelector("svg"), null);
  assert.match(document.querySelector(".code-fallback")?.textContent ?? "", /<svg/);
  assert.equal(document.querySelector("[onerror], [onload]"), null);
});

test("negotiates the protocol and reports malformed or unknown commands", () => {
  const context = setup();
  send(context, "hello", {}, 0, "hello-1");
  assert.equal(context.events[0].type, "hello");
  assert.equal(context.events[0].payload.protocolVersion, 1);
  assert.equal(context.events[1].type, "ack");

  context.api.postCommand("not-base64!");
  assert.equal(context.events.at(-1).payload.code, "invalid_base64");

  context.api.postCommand(
    encodeCommand({ version: 99, id: "bad-version", type: "hello" }),
  );
  assert.equal(context.events.at(-1).payload.code, "unsupported_version");

  send(context, "printPdf", {}, 0, "no-pdf");
  assert.equal(context.events.at(-1).payload.code, "unknown_command");
});

test("rejects stale epochs without changing the transcript", () => {
  const context = setup();
  replace(context, "new", 2);
  replace(context, "old", 1);

  assert.equal(
    context.dom.window.document.querySelector(".message-content")?.textContent.trim(),
    "new",
  );
  assert.equal(context.events.at(-1).payload.code, "stale_epoch");
});

test("rejects duplicate message IDs atomically", () => {
  const context = setup();
  replace(context, "original", 1);
  const before = context.dom.window.document.querySelector('[data-message-id="m1"]');

  send(
    context,
    "replaceTranscript",
    {
      messages: [
        { id: "m1", role: "assistant", markdown: "changed" },
        { id: "m1", role: "assistant", markdown: "duplicate" },
      ],
    },
    2,
    "duplicate",
  );

  const after = context.dom.window.document.querySelector('[data-message-id="m1"]');
  assert.strictEqual(after, before);
  assert.equal(after?.textContent.trim(), "original");
  assert.equal(context.events.at(-1).payload.code, "duplicate_message");

  send(context, "patchMessage", {
    message: { id: "m1", role: "assistant", markdown: "still-current" },
  });
  assert.equal(after?.textContent.trim(), "still-current");
});

test("patches a keyed message without replacing its DOM node", () => {
  const context = setup();
  replace(context, "before");
  const before = context.dom.window.document.querySelector('[data-message-id="m1"]');

  send(context, "patchMessage", {
    message: { id: "m1", role: "assistant", markdown: "after" },
  });
  const after = context.dom.window.document.querySelector('[data-message-id="m1"]');

  assert.strictEqual(after, before);
  assert.equal(after?.textContent.trim(), "after");
});

test("renders typed actions and emits only their message intent", () => {
  const context = setup();
  send(context, "replaceTranscript", {
    messages: [
      {
        id: "m1",
        role: "assistant",
        markdown: "answer",
        actions: [
          { type: "regenerate", label: "Regenerate" },
          { type: "suggestion", label: "Continue", value: "Continue" },
        ],
      },
    ],
  });

  const buttons = context.dom.window.document.querySelectorAll("button");
  assert.equal(buttons.length, 2);
  buttons[1].click();
  const event = context.events.at(-1);
  assert.equal(event.type, "action");
  assert.deepEqual(event.payload, {
    action: "suggestion",
    value: "Continue",
    messageId: "m1",
  });
});

test("plain messages never interpret markdown or raw HTML", () => {
  const context = setup();
  send(context, "replaceTranscript", {
    messages: [
      {
        id: "m1",
        role: "user",
        markdown: "**literal** <img src=x onerror=alert(1)>",
        format: "plain",
      },
    ],
  });

  const content = context.dom.window.document.querySelector(".message-content");
  assert.equal(content?.children.length, 0);
  assert.equal(content?.textContent, "**literal** <img src=x onerror=alert(1)>");
});

test("assembles resource chunks and revokes object URLs on release and epoch change", () => {
  const context = setup();
  replace(context, "![image](cuplivo-resource://image-1)");
  send(context, "resourceChunk", {
    resourceId: "image-1",
    transferId: "transfer-1",
    index: 0,
    totalChunks: 2,
    mimeType: "image/png",
    data: Buffer.from("first").toString("base64"),
  });
  send(context, "resourceChunk", {
    resourceId: "image-1",
    transferId: "transfer-1",
    index: 1,
    totalChunks: 2,
    mimeType: "image/png",
    data: Buffer.from("second").toString("base64"),
  });

  const image = context.dom.window.document.querySelector("img");
  assert.equal(image?.getAttribute("src"), "blob:test-1");
  assert.equal(context.events.some((event) => event.type === "resourceReady"), true);

  send(context, "releaseResource", { resourceId: "image-1" });
  assert.deepEqual(context.revokedUrls, ["blob:test-1"]);

  send(context, "resourceChunk", {
    resourceId: "image-2",
    transferId: "transfer-2",
    index: 0,
    totalChunks: 1,
    mimeType: "image/png",
    data: Buffer.from("third").toString("base64"),
  });
  send(context, "replaceTranscript", { messages: [] }, 2);
  assert.deepEqual(context.revokedUrls, ["blob:test-1", "blob:test-2"]);
});
