'use strict';
// Contract check for the official DSH Web UI DOM recipes.
//
// The Android acceptance cannot render the official single-page app on the
// hosted emulator (its Chromium renderer exits within seconds), so this job
// proves the generic-compatibility recipe against the *real* Host instead: it
// opens the Host in a desktop Chrome at phone width and runs the exact scripts
// the app ships (`tool/e2e/print_dsh_surface_scripts.dart` prints them), then
// asserts the harvested surfaces and the landing behaviour.
//
// Inputs: E2E_DSH_URL (live DSH WebUI URL, launch token included; never printed)
//         DSH_SURFACE_SCRIPTS (path to the JSON printed by the Dart tool)
//         CHROME_BIN (optional Chrome executable override)
// Output: one `[dom-contract] ...` line per assertion; exit 1 on any failure.

const { spawn } = require('node:child_process');
const crypto = require('node:crypto');
const fs = require('node:fs');
const net = require('node:net');
const os = require('node:os');
const path = require('node:path');

const scripts = JSON.parse(
  fs.readFileSync(process.env.DSH_SURFACE_SCRIPTS || '', 'utf8'),
);
// The endpoint is the base root; the launch token is minted per DSH process and
// is exchanged for the session cookie on the first page load (the same URL the
// app's direct-connect form composes). Neither value is ever printed.
const baseUrl = (process.env.E2E_DSH_URL || '').replace(/\/+$/, '');
const launchToken = process.env.E2E_DSH_TOKEN || '';
if (!baseUrl) fail('E2E_DSH_URL is not set');
const targetUrl =
  launchToken && !/[?&]token=/.test(baseUrl)
    ? `${baseUrl}/?token=${encodeURIComponent(launchToken)}`
    : baseUrl;
if (!scripts.harvest || !scripts.settings) fail('script bundle is incomplete');

const VIEWPORT = { width: 412, height: 915 };

function log(message) {
  process.stdout.write(`[dom-contract] ${message}\n`);
}

// Screenshots of the official UI the recipes read, so a reviewer can see that
// the contract ran against a rendered app and not against an error page. They
// are uploaded as the `dom-contract-screenshots` artifact.
const shotsDir =
  process.env.DSH_CONTRACT_SHOTS ||
  path.join(process.env.RUNNER_TEMP || os.tmpdir(), 'dom-contract-shots');
fs.mkdirSync(shotsDir, { recursive: true });

function fail(message) {
  process.stderr.write(`[dom-contract] FAILED: ${message}\n`);
  process.exit(1);
}

const problems = [];
function check(name, condition, detail) {
  if (condition) {
    log(`ok ${name}${detail === undefined ? '' : ` (${detail})`}`);
    return true;
  }
  const message = `${name}${detail === undefined ? '' : `: ${detail}`}`;
  problems.push(message);
  log(`FAIL ${message}`);
  return false;
}

// --- a WebSocket client for the Chrome DevTools protocol --------------------
// Node 22 ships a global WebSocket; older runners do not, so this module carries
// a minimal RFC 6455 client for the localhost CDP connection.
function encodeClientFrame(text) {
  const payload = Buffer.from(text, 'utf8');
  const mask = crypto.randomBytes(4);
  let header;
  if (payload.length < 126) {
    header = Buffer.alloc(2);
    header[1] = 0x80 | payload.length;
  } else if (payload.length < 65536) {
    header = Buffer.alloc(4);
    header[1] = 0x80 | 126;
    header.writeUInt16BE(payload.length, 2);
  } else {
    header = Buffer.alloc(10);
    header[1] = 0x80 | 127;
    header.writeBigUInt64BE(BigInt(payload.length), 2);
  }
  header[0] = 0x81;
  const masked = Buffer.alloc(payload.length);
  for (let index = 0; index < payload.length; index += 1) {
    masked[index] = payload[index] ^ mask[index % 4];
  }
  return Buffer.concat([header, mask, masked]);
}

function rawWebSocket(wsUrl) {
  const url = new URL(wsUrl);
  const socket = net.connect({
    host: url.hostname,
    port: Number(url.port || 80),
  });
  let buffer = Buffer.alloc(0);
  let upgraded = false;
  let fragment = null;
  const pending = new Map();
  const listeners = new Map();
  let nextId = 0;
  const opened = new Promise((resolve, reject) => {
    socket.once('connect', () => {
      const key = crypto.randomBytes(16).toString('base64');
      socket.write(
        [
          `GET ${url.pathname}${url.search} HTTP/1.1`,
          `Host: ${url.host}`,
          'Upgrade: websocket',
          'Connection: Upgrade',
          `Sec-WebSocket-Key: ${key}`,
          'Sec-WebSocket-Version: 13',
          '',
          '',
        ].join('\r\n'),
      );
    });
    socket.once('error', reject);
    socket.on('close', () => {
      for (const entry of pending.values()) entry.reject(new Error('CDP closed'));
      pending.clear();
    });
    const pump = () => {
      if (!upgraded) {
        const end = buffer.indexOf('\r\n\r\n');
        if (end < 0) return;
        const head = buffer.subarray(0, end).toString('latin1');
        buffer = buffer.subarray(end + 4);
        if (!/^HTTP\/1\.1 101/.test(head)) {
          reject(new Error('WebSocket upgrade rejected'));
          return;
        }
        upgraded = true;
        resolve();
      }
      for (;;) {
        if (buffer.length < 2) return;
        const first = buffer[0];
        const second = buffer[1];
        const fin = (first & 0x80) !== 0;
        const opcode = first & 0x0f;
        let length = second & 0x7f;
        let offset = 2;
        if (length === 126) {
          if (buffer.length < 4) return;
          length = buffer.readUInt16BE(2);
          offset = 4;
        } else if (length === 127) {
          if (buffer.length < 10) return;
          length = Number(buffer.readBigUInt64BE(2));
          offset = 10;
        }
        if (buffer.length < offset + length) return;
        const payload = buffer.subarray(offset, offset + length);
        buffer = buffer.subarray(offset + length);
        if (opcode === 0x9) {
          continue; // ping: the localhost connection does not need pongs
        }
        const chunk = Buffer.from(payload);
        const text = fragment
          ? Buffer.concat([fragment, chunk]).toString('utf8')
          : chunk.toString('utf8');
        if (!fin && opcode !== 0x8) {
          fragment = fragment ? Buffer.concat([fragment, chunk]) : chunk;
          continue;
        }
        fragment = null;
        if (opcode === 0x8) return;
        let message;
        try {
          message = JSON.parse(text);
        } catch {
          continue;
        }
        if (message.id != null && pending.has(message.id)) {
          const entry = pending.get(message.id);
          pending.delete(message.id);
          if (message.error) entry.reject(new Error(JSON.stringify(message.error)));
          else entry.resolve(message.result);
        } else if (message.method && listeners.has(message.method)) {
          listeners.get(message.method)(message.params);
        }
      }
    };
    socket.on('data', (data) => {
      buffer = Buffer.concat([buffer, data]);
      if (upgraded) pump();
      else pump();
    });
  });
  return opened.then(() => ({
    send(method, params) {
      return new Promise((resolve, reject) => {
        const id = (nextId += 1);
        pending.set(id, { resolve, reject });
        socket.write(encodeClientFrame(JSON.stringify({ id, method, params })));
      });
    },
    close() {
      try {
        socket.end();
      } catch {}
    },
  }));
}

function globalWebSocket(wsUrl) {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(wsUrl);
    const pending = new Map();
    let nextId = 0;
    socket.addEventListener('error', () => reject(new Error('CDP socket error')));
    socket.addEventListener('message', (event) => {
      let message;
      try {
        message = JSON.parse(event.data);
      } catch {
        return;
      }
      if (message.id != null && pending.has(message.id)) {
        const entry = pending.get(message.id);
        pending.delete(message.id);
        if (message.error) entry.reject(new Error(JSON.stringify(message.error)));
        else entry.resolve(message.result);
      }
    });
    socket.addEventListener('open', () =>
      resolve({
        send(method, params) {
          return new Promise((res, rej) => {
            const id = (nextId += 1);
            pending.set(id, { resolve: res, reject: rej });
            socket.send(JSON.stringify({ id, method, params }));
          });
        },
        close() {
          try {
            socket.close();
          } catch {}
        },
      }),
    );
  });
}

function connectCdp(wsUrl) {
  const forceCustom = process.env.DSH_DOM_CONTRACT_FORCE_CUSTOM_WS === '1';
  if (typeof WebSocket === 'function' && !forceCustom) return globalWebSocket(wsUrl);
  return rawWebSocket(wsUrl);
}

// --- Chrome -----------------------------------------------------------------
function chromeBinary() {
  const candidates = [
    process.env.CHROME_BIN,
    '/usr/bin/google-chrome',
    '/usr/bin/google-chrome-stable',
    '/opt/google/chrome/chrome',
    '/usr/bin/chromium',
    '/usr/bin/chromium-browser',
  ].filter(Boolean);
  for (const candidate of candidates) {
    if (fs.existsSync(candidate)) return candidate;
  }
  fail(`no Chrome found (tried: ${candidates.join(', ')})`);
}

async function launchChrome() {
  const binary = chromeBinary();
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-contract-'));
  const child = spawn(
    binary,
    [
      '--headless=new',
      '--no-sandbox',
      '--disable-gpu',
      '--disable-dev-shm-usage',
      '--no-first-run',
      '--no-default-browser-check',
      '--disable-extensions',
      '--remote-debugging-port=0',
      `--user-data-dir=${profile}`,
      'about:blank',
    ],
    { stdio: ['ignore', 'ignore', 'pipe'] },
  );
  const endpoint = await new Promise((resolve, reject) => {
    let buffer = '';
    const timer = setTimeout(
      () => reject(new Error('Chrome did not open its DevTools endpoint')),
      30000,
    );
    child.stderr.on('data', (data) => {
      buffer += data.toString('utf8');
      const match = buffer.match(/DevTools listening on (ws:\/\/\S+)/);
      if (!match) return;
      clearTimeout(timer);
      resolve(match[1].trim());
    });
    child.once('exit', (code) => {
      clearTimeout(timer);
      reject(new Error(`Chrome exited early (${code})`));
    });
  });
  const browserHost = new URL(endpoint).host;
  let pageWs = null;
  for (let attempt = 0; attempt < 100 && pageWs === null; attempt += 1) {
    const list = await (await fetch(`http://${browserHost}/json/list`)).json();
    const page = list.find((entry) => entry.type === 'page');
    if (page) pageWs = page.webSocketDebuggerUrl;
    else await sleep(200);
  }
  if (pageWs === null) throw new Error('Chrome exposed no page target');
  return { child, pageWs, profile };
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// --- scenario ---------------------------------------------------------------
const READY_EXPRESSION = `JSON.stringify({
  ready: document.readyState,
  rows: document.querySelectorAll('nav button').length,
})`;

const STATE_EXPRESSION = `JSON.stringify({
  ready: document.readyState,
  sidebarRows: [...document.querySelectorAll('nav button')].filter((button) =>
    button.querySelector('[data-slot="sidebar.panellist"]')).length,
  cards: [...document.querySelectorAll('[data-sidebar-right-guide-entry]')].map((el) =>
    el.getAttribute('data-sidebar-right-guide-entry')),
  menuItems: [...document.querySelectorAll('[role="menuitem"]')].map((el) =>
    (el.innerText || '').replace(/\\s+/g, ' ').trim()).slice(0, 8),
  settingsSections: [...document.querySelectorAll('[role="dialog"][data-shortcut-modal="settings"] nav button')].map((button) =>
    (button.innerText || '').replace(/\\s+/g, ' ').trim()),
  bodyText: ((document.body && document.body.innerText) || '').replace(/\\s+/g, ' '),
})`;

async function main() {
  const chrome = await launchChrome();
  const cdp = await connectCdp(chrome.pageWs);
  const send = (method, params) => cdp.send(method, params);
  const evaluate = async (expression, awaitPromise = false) => {
    const result = await send('Runtime.evaluate', {
      expression,
      awaitPromise,
      returnByValue: true,
    });
    if (result.exceptionDetails) {
      throw new Error(
        `evaluate failed: ${JSON.stringify(result.exceptionDetails).slice(0, 400)}`,
      );
    }
    return result.result?.value;
  };
  const state = async () => JSON.parse(await evaluate(STATE_EXPRESSION));
  const waitReady = async () => {
    for (let attempt = 0; attempt < 360; attempt += 1) {
      const ready = JSON.parse(await evaluate(READY_EXPRESSION));
      if (ready.ready === 'complete' && ready.rows > 0) return true;
      await sleep(250);
    }
    return false;
  };
  const installBridge = () =>
    evaluate(`window.__dshPosts = []; window.flutter_inappwebview = {
      callHandler: (name, payload) => window.__dshPosts.push({
        name: name, payload: payload,
      }),
    };`);
  const drainPosts = async () => {
    const raw = await evaluate('JSON.stringify(window.__dshPosts || [])');
    await evaluate('window.__dshPosts = []');
    return JSON.parse(raw);
  };
  const evaluateScript = async (source, label) => {
    await installBridge();
    const evaluated = evaluate(source, true);
    const timeout = new Promise((_, reject) =>
      setTimeout(() => reject(new Error(`${label} did not settle in 120 s`)), 120000),
    );
    await Promise.race([evaluated, timeout]);
    return drainPosts();
  };
  const reload = async () => {
    await send('Page.reload');
    if (!(await waitReady())) throw new Error('the Host did not become ready after a reload');
  };
  const capture = async (name) => {
    const shot = await send('Page.captureScreenshot', { format: 'png' });
    const file = path.join(shotsDir, `${name}.png`);
    fs.writeFileSync(file, Buffer.from(shot.data, 'base64'));
    log(`captured ${file}`);
  };

  try {
    await send('Page.enable');
    await send('Runtime.enable');
    await send('Emulation.setDeviceMetricsOverride', {
      width: VIEWPORT.width,
      height: VIEWPORT.height,
      deviceScaleFactor: 2,
      mobile: true,
    });
    await send('Page.navigate', { url: targetUrl });
    if (!(await waitReady())) {
      // Leave a diagnostic in the job log and the artifact: an unauthenticated
      // launch lands on the login page, a network problem lands on an error
      // page, and both are otherwise an opaque timeout.
      try {
        await capture('00-failure');
        const diagnostic = JSON.parse(
          await evaluate(`JSON.stringify({
            title: document.title,
            path: location.pathname,
            body: ((document.body && document.body.innerText) || '').replace(/\\s+/g, ' ').slice(0, 300),
            url: location.origin,
          })`),
        );
        log(`host page diagnostic: ${JSON.stringify(diagnostic)}`);
      } catch (error) {
        log(`host page diagnostic failed: ${error.message}`);
      }
      fail('the Host Web UI did not render its sidebar within 90 s');
    }
    log('host ready at phone width');
    await capture('01-host-root');

    // 1. Surface harvest.
    const harvestPosts = await evaluateScript(scripts.harvest, 'harvest');
    const harvestRaw = harvestPosts.map((post) => post.payload).find(Boolean);
    const harvest = JSON.parse(harvestRaw || '{}');
    check('harvest posts a v1 payload', harvest.v === 1, harvestRaw?.slice(0, 120));
    const sidebar = Array.isArray(harvest.sidebar) ? harvest.sidebar : [];
    const rail = Array.isArray(harvest.rail) ? harvest.rail : [];
    check('harvest reports the official sidebar rows', sidebar.length >= 3, `${sidebar.length} rows`);
    check(
      'every sidebar row keeps a non-empty Host label',
      sidebar.every((entry) => typeof entry.label === 'string' && entry.label.trim().length > 0),
    );
    const sidebarLabels = sidebar.map((entry) => entry.label);
    log(`sidebar: ${sidebarLabels.join(' | ')}`);
    check('harvest reports the right-rail cards', rail.length >= 3, `${rail.length} cards`);
    const kinds = rail.map((entry) => entry.kind).filter(Boolean);
    log(`rail kinds: ${kinds.join(' | ')}`);
    for (const expected of ['files', 'terminal', 'bw-diff']) {
      check(`rail keeps the language-neutral kind "${expected}"`, kinds.includes(expected));
    }

    // 2. Official settings dialog harvest.
    await reload();
    const settingsPosts = await evaluateScript(scripts.settings, 'settings');
    const settingsRaw = settingsPosts.map((post) => post.payload).find(Boolean);
    const settings = JSON.parse(settingsRaw || '{}');
    const sections = Array.isArray(settings.settings) ? settings.settings : [];
    const sectionLabels = sections.map((entry) => entry.label);
    log(`settings sections: ${sectionLabels.join(' | ')}`);
    check('the settings dialog reports its sections', sections.length >= 4, `${sections.length} sections`);
    const knownBuiltIns = [
      'General', '通用', '通用设置',
      'Models', '模型',
      'Built-in plugins', '内置插件',
      'Agent presets', 'Agent 预设', '代理预设',
    ];
    check(
      'the settings labels are the official ones (built-in set)',
      sectionLabels.some((label) => knownBuiltIns.includes(label)),
      sectionLabels.join(' | '),
    );
    // Land on a real section and screenshot the dialog while it is open. The
    // landing gets its own page load: reopening the dialog right after the
    // harvest script closed it can race the dialog's own close animation, and
    // the app never does that either (every official visit is a fresh load).
    const settingsLandTarget = sectionLabels.find((label) =>
      ['General', '通用', '通用设置', 'Models', '模型'].includes(label),
    );
    if (settingsLandTarget) {
      await reload();
      await installBridge();
      const landingScript = scripts.settingsLand.replace(
        '"__SETTINGS_SECTION__"',
        JSON.stringify(settingsLandTarget),
      );
      await Promise.race([evaluate(landingScript, true), sleep(60000)]);
      await sleep(1500);
      const landingPosts = await drainPosts();
      check(
        'the settings landing opens the dialog on a real section',
        JSON.parse(landingPosts[0]?.payload || '{}').stage === undefined,
        JSON.stringify(landingPosts.map((post) => post.payload)),
      );
      await capture('02-settings-dialog');
      log(`settings dialog landed on: ${settingsLandTarget}`);
    }

    // 3. Landing on a harvested sidebar row.
    await reload();
    const harvestForSidebar = JSON.parse(
      (await evaluateScript(scripts.harvest, 'harvest')).map((post) => post.payload).find(Boolean) || '{}',
    );
    const sidebarTarget = harvestForSidebar.sidebar?.[0]?.label;
    check('a harvested sidebar row exists to land on', typeof sidebarTarget === 'string', sidebarTarget);
    if (typeof sidebarTarget === 'string') {
      await installBridge();
      const landing = scripts.sidebarLanding.replace(
        '"__SIDEBAR_LABEL__"',
        JSON.stringify(sidebarTarget),
      );
      const settled = evaluate(landing, true);
      await Promise.race([settled, sleep(90000)]);
      await sleep(1500);
      const after = await state();
      check(
        `the sidebar landing opens the "${sidebarTarget}" panel`,
        after.bodyText.includes(sidebarTarget),
        after.bodyText.slice(0, 160),
      );
      await capture('03-sidebar-panel');
    }

    // 4. Landing on a harvested right-rail card.
    await reload();
    const harvestForRail = JSON.parse(
      (await evaluateScript(scripts.harvest, 'harvest')).map((post) => post.payload).find(Boolean) || '{}',
    );
    const railTarget =
      (harvestForRail.rail || []).find((entry) => entry.kind === 'bw-diff') ||
      (harvestForRail.rail || [])[0];
    check('a harvested right-rail card exists to land on', Boolean(railTarget?.kind), JSON.stringify(railTarget));
    if (railTarget?.kind) {
      await installBridge();
      const landing = scripts.railLanding
        .replace('"__RAIL_KIND__"', JSON.stringify(railTarget.kind))
        .replace('"__RAIL_LABEL__"', JSON.stringify(railTarget.label || ''));
      const settled = evaluate(landing, true);
      await Promise.race([settled, sleep(90000)]);
      await sleep(2000);
      const after = await state();
      check('the rail landing replaces the card list with the card page', after.cards.length === 0, `${after.cards.length} cards left`);
      check(
        'the rail landing shows the diff page',
        /Uncommitted|No changes|Wrap lines|未提交|无更改|±\s*diff/i.test(after.bodyText),
        after.bodyText.slice(0, 160),
      );
      await capture('04-right-rail-page');
    }

    // 5. The official 更多 entry.
    await reload();
    const morePosts = await evaluateScript(scripts.moreMenuLanding, 'more-menu landing');
    await sleep(1200);
    const afterMore = await state();
    check(
      'the 更多 landing opens the official more menu',
      afterMore.menuItems.length > 0,
      afterMore.menuItems.join(' | '),
    );
    await capture('05-more-menu');
    void morePosts;
  } finally {
    cdp.close();
    chrome.child.kill('SIGKILL');
    fs.rmSync(chrome.profile, { recursive: true, force: true });
  }

  if (problems.length > 0) {
    process.stderr.write(
      `[dom-contract] ${problems.length} assertion(s) failed:\n${problems
        .map((problem) => ` - ${problem}`)
        .join('\n')}\n`,
    );
    process.exit(1);
  }
  log('all DOM-contract assertions passed');
  process.exit(0);
}

main().catch((error) => {
  process.stderr.write(`[dom-contract] FAILED: ${error.stack || error}\n`);
  process.exit(1);
});
