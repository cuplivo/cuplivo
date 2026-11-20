# DSH plugin/UI contribution compatibility — settings, sidebar entries, right-rail cards

Status: research note for `feat/cuplivo-dsh` (workstream P2), answering the five
compatibility questions raised for the v2 surfaces. **Verified against the
installed DSH 0.2.2-rc.1 and against a live `dsh web` on 2026-11-20 (UTC)** whose
profile composes the stock web bundles plus the two Cuplivo test plugins:

| item | value |
|---|---|
| Harness | DSH `0.2.2-rc.1`, commit `c59d10a` (`window.__DSH_BOOT__.release`) |
| Stock profile | `@deepseek-ai/dsh-base` + `@deepseek-ai/dsh-web-app` |
| Extra bundles | `@ds-hu/dsh-better-search@0.5.0`, `@ds-hu/dsh-better-workspaces@0.4.1` (four rows) |
| Browser | Chromium via the Playwright skill, locale `zh-CN`, 1440×900 |
| Wire reference | [`protocol.md`](protocol.md) for transports; this note does not repeat them |

Companion documents: [`client-reference.md`](client-reference.md) (wire + Cuplivo
client design; its §3.10 and §5.8 discuss the same plugin surfaces from the
client side), [`plugin-host.md`](plugin-host.md) (what the E2E host's plugins
render and what the CI may assert), [`v2-reuse-map.md`](v2-reuse-map.md)
(`DshSideBar`/`HarnessRailExtraEntry` seams), [`e2e-scenario.md`](e2e-scenario.md)
(acceptance anchors). Where this note and `client-reference.md` disagree about a
DOM detail, this note is the newer, measured one — but nothing in either is a
public DSH API.

> Conventions: `<dsh-root>` is the installed package root
> (`/usr/local/lib/node_modules/@deepseek-ai/dsh`); package paths below are
> relative to `<dsh-root>/node_modules/@deepseek-ai/`. `<host>` is the operator's
> `dsh web` origin. No launch token, cookie or real origin appears here.

---

## 0. What this note answers

| # | question | short answer | section |
|---|---|---|---|
| 1 | Which packages register `settings.section`, with ids, orders and labels; how does a third-party plugin add its own settings section/tab | four stock registrants plus one conditional account section; a plugin calls `ctx.slots.inject("settings.section", () => ctx.slots.register({ name, id, order, label, locale, inject, children }, Component))`, optionally contributes a same-id `settings.section.icon`; most plugins instead use `plugins.item` or `plugins.row.config` | §3 |
| 2 | Which slot or API creates each of the sidebar rows 插件 / 搜索服务 / 自动化任务 / 更多; what is discoverable over RPC | three rows are `sidebar.panellist` list registrations (two built-in packages, one plugin); 更多 is the DSH sidebar's own `PanelMoreMenu`, not a page, and only exists while `sidebar.panellist.actions` has registrations. RPC exposes plugin packages/rows/bundles, **never** UI entries | §4 |
| 3 | How plugin cards register on the right rail; does better-workspaces contribute one | page types are registered with `ctx.sidebarRightTabs.register(definition)`; the card is generated from `definition.guide[]`; better-workspaces contributes three (`bw-diff`, `bw-worktree`, `bw-forge`) and they are visible on the live host | §5 |
| 4 | Are the sidebar pages SPA routes or client state; how does a Flutter WebView open one generically and enumerate entries | client state only — no route, hash or query ever changes (`/` for every surface). Enumerate by DOM anchors (`[data-slot="sidebar.panellist"]` rows, settings nav buttons, `[data-sidebar-right-guide-entry]` cards, `[data-plugin-*]` plugin pages) and click with a bounded wait/verify loop; labels are localized, ids mostly are not in the DOM | §6 |
| 5 | Native RPC or embedded WebUI per surface; what Cuplivo must not hardcode | native RPC for the built-in surfaces' **data**; embedded WebUI for every plugin-contributed **view**; never hardcode plugin names, ids, labels, orders or the presence of a row/section/card | §7, §8 |

**Bottom line up front.** DSH's browser half is a slot-composed React SPA with no
router and no UI registry on the wire. The only two honest ways to reach a
plugin-contributed surface are (a) render it in a WebView and drive the official
DOM with the anchors below, or (b) re-implement that plugin's feature, which
Cuplivo cannot do generically because the view and its data routes are private to
the plugin. Built-in data (sessions, models, plugins inventory, schedules, files,
terminal) is all available over the documented RPC and must not be scraped from
the DOM.

---

## 1. Method and evidence

Two independent evidence sources, cross-checked:

1. **Source read** of the installed 0.2.2-rc.1 client packages — slot
   declarations, registrations, locale dictionaries and the renderer — plus the
   installed plugin bundles' client halves (`@ds-hu/*`), their `docs/CONTRACT.md`,
   technical notes and ADRs.
2. **Live observation** of the real `dsh web` host in a headless Chromium with a
   Playwright probe suite: boot graph capture, DOM/ARIA dumps of every surface,
   synthetic and real clicks, URL checks, and screenshots. Eight UI probes were
   run, plus RPC and deep-link captures; their JSON/text/PNG artifacts stay
   outside the repository in the operator's
   research directory (`plugin-compat/shots/`); the excerpts quoted here
   are trimmed to identifiers and labels.

The installed-package claims below are stable for 0.2.2-rc.1; the DOM hook claims
are observations of that build, not a contract. Both are labelled as such.

---

## 2. How DSH composes its browser UI

This section is the minimum model needed to read the rest of the note.

### 2.1 Client plugins, modules and the boot graph

Every browser-half package is a Cordis plugin whose `lib/client.js` wraps
`window.__ModuleLoader__.load({ id, factory })`. The shell injects a boot graph
into the page as `window.__DSH_BOOT__`:

```json
{"rev": "...", "release": {"version": "0.2.2-rc.1", "commit": "c59d10a"},
 "entries": [{"id": "@deepseek-ai/dsh-client-ui-chat", "url": "...", "rev": "...",
              "inject": ["..."], "immediately": true}],
 "batches": [{"phase": "bootstrap", "entries": ["..."]},
             {"phase": "application", "entries": ["..."]}]}
```

Live host: 78 client entries in three batches (1 bootstrap, 57 + 20
application); the five `@ds-hu` client packages appear as entries
(`@ds-hu/dsh-better-search`, `@ds-hu/dsh-bw-diff`, `@ds-hu/dsh-bw-worktree`,
`@ds-hu/dsh-bw-status`, `@ds-hu/dsh-bw-forge`). This graph is the cheapest way to
tell *whether* a plugin has a browser half and *which* release is installed; it
carries no labels, slot positions or routes (see `protocol.md` for the same
detector used against `GET /`).

### 2.2 The slot system

The client slot registry (`@deepseek-ai/dsh-client-ui-slots`, consumed through
`ctx.slots`) is the composition mechanism:

- An **owner** package declares a slot (`SlotMap` augmentation) with a kind and a
  scope (`root` or `session`), and renders its outlet.
- A **registrant** calls `ctx.slots.register({ name, id | key, order, label, locale, inject, children }, Component)`.
  List slots key by `id`, keyed slots by `key`, chain slots by key too; `order`
  is ascending with registration order as tie-break; `label` is a thunk read on
  every use, so a locale change needs no re-registration.
- Consumers that must not race the declaration call
  `ctx.slots.inject(name, () => ctx.slots.register(...))`, which runs once the
  owner declares the slot and disposes with the caller's effect.
- `ctx.slots.entriesOfSlot(name)` exposes registrations **inside the browser
  context only**; there is no service or RPC that exports them.

Every outlet is rendered by `dsh-client-ui-renderer` as a
`<div data-slot="<slot-name>" style="display:contents">` anchor, with
single/keyed/list/chain variants. This attribute is the most version-tolerant DOM
hook in the product: it mirrors the declared slot name, so it survives owner
markup changes as long as the slot itself survives.

### 2.3 The main column and navigation are client state, not routes

`dsh-client-ui-layout` declares the shell slots:

| slot | kind | scope | occupant in the stock profile |
|---|---|---|---|
| `main` | keyed | root | one occupant per panel key: `conversation` (chat), `plugins` (plugin manager), `schedules` (automation), plus any plugin page (e.g. `better-search`) |
| `sidebar` | single | root | the whole left column (`dsh-client-ui-sidebar`) |
| `rightbar` | single | root | the right rail |
| `shell.bottom`, `shell.overlay`, `shell.leading` | single/list | root | status/overlays |

The active main panel is a value in the layout service's observable
(`ctx.layout.panelInfo.activePanelId`, mutated by `ctx.layout.selectPanel(id)`).
The sidebar row's `aria-current="page"` and the rendered `main` occupant are the
only visible signs of it. `dsh-client-ui-layout/lib/types/client/index.d.ts`
declares `main` as `{ kind: 'keyed', scope: 'root' }`; there is no route table,
no `history.pushState`, no `location.hash` use. Live confirmation: after opening
插件, 搜索服务, 自动化任务, the settings dialog, and every right-rail page, the
browser location stayed `path=/`, `hash=""`, `search=""` (§6.1).

Consequence: **there is no deep link**, and a WebView cannot be "navigated" to a
surface by URL. It has to be driven.

### 2.4 What the wire exposes

`dsh-client-remote` (as surfaced by the Host) exposes 193 methods on the live
host. Searching the method catalogue for slot, view, setting-section or panel
registries finds **none**: the only plugin-related namespaces are
`pluginInventory/*`, `pluginManager/*`, `pluginMarket/*`,
`pluginRecommendations/*`, `dynamicCordisRunner/*`, plus `settings/*` (a settings
*document* API) and `remoteAccess/*` (method availability). UI contributions
exist only inside the browser; §4.4 and §5.4 enumerate the practical
consequences.

---

## 3. Q1 — Settings sections, their registrants, and third-party registration

### 3.1 The settings slot family

The settings shell (`dsh-client-ui-settings-general`) declares the family and is
itself the General section. The contract is
`dsh-client-ui-settings/lib/types/client/contract/slots.d.ts`:

| slot | kind | scope | who renders it | purpose |
|---|---|---|---|---|
| `settings.launcher` | single | root | sidebar foot (`sidebar.settings` seat) | the primary settings entry; receives `openSettings()` |
| `settings.trigger` | single | root | settings shell fallback | gear-style trigger used only when launcher is empty |
| `settings.header` | single | root | dialog header | title |
| `settings.action` | list | root | dialog header | header actions |
| `settings.close` | single | root | dialog header | close control |
| `settings.section` | list | root | nav list + one active body | one settings page per id |
| `settings.section.icon` | list (inline) | root | nav row glyph | per-section icon, keyed by the section id |
| `settings.plugins.tab` | list | root | inside the built-in Plugins section | tabs next to the plugin inventory |
| `settings.onboarding` | list | root | onboarding coordinator | first-run steps |
| `settings.general.item` | list | root | inside General | one settings row |

`settings.section` owner props are only `{ close }` — the shell owns visibility
and navigation; each section brings its data through its own `inject` faces and
stores. `settings.section.icon` owner props are `{ size, active }`. The nav row
renders `renderSlot("settings.section.icon", { size, active }, { only: id, fallback: ... })`,
so the anchor exists in every row even when the section registers no icon.
Observed: 4 anchors and 4 nav rows while none of the five stock sections above
registers an icon — the shell draws its own fallback glyph.

### 3.2 Registrants in a normal web profile

Live signed-out session (the host serves the stock composition): the dialog
contains exactly four nav buttons in this order, one `settings.section` body
outlet, and four `settings.section.icon` outlets.

| id | order | zh label | en label | registered by | condition |
|---|---|---|---|---|---|
| `account` | -10 | 账号与余额 | Account | `dsh-client-ui-settings-account` | only while the credential state is `credential-stored`; **absent when signed out** (live) |
| `general` | 0 | 通用设置 | General | `dsh-client-ui-settings-general` | always; declares `settings.general.item` as a child slot |
| `models` | 10 | 模型 | Models | `dsh-client-ui-settings-models` | always; declares `settings.models.provider-card` (keyed) and `settings.models.footer` (list) children |
| `plugins` | 15 | 内置插件 | Built-in plugins | `dsh-client-ui-settings-plugins` | always; declares `settings.plugins.tab` as a child slot |
| `agent-presets` | 20 | Agent 预设 | Agent presets | `dsh-client-ui-agent-preset` | always |

Source refs: account `dsh-client-ui-settings-account/lib/client.js:5424`,
general `dsh-client-ui-settings-general/lib/client.js:1588`, models
`dsh-client-ui-settings-models/lib/client.js:5465`, plugins
`dsh-client-ui-settings-plugins/lib/client.js:256`, agent presets
`dsh-client-ui-agent-preset/lib/client.js:3081`. Labels come from the package
dictionaries (`general.nav`, `nav`, `settings.agentPreset → nav`, …) and are
translated to eight locales; the zh/en pairs above are the two a Chinese or
English DSH prints.

Two details matter for a client that wants to "open the models settings":

- The **account section sorts before General** when it exists. Any index-based
  navigation (`nav buttons[0]` = General) silently becomes wrong on a signed-in
  host. The nav row has no `data-section-id` (or any id attribute); only text and
  `aria-current` are exposed.
- The labels are localized. `通用设置` is `General`, and a user-set locale
  changes every string. A label table must be maintained per DSH locale or the
  action must be user-mediated.

### 3.3 The 内置插件 section and its tabs

`settings.plugins.tab` is a list slot inside the built-in Plugins section. In the
stock web profile it has **one** registrant:

| id | order | zh | en | package |
|---|---|---|---|---|
| `all` | 10 | 插件列表 | Plugin list | `dsh-client-ui-settings-plugin-inventory` |

Not to be confused with the Plugins *panel's* own tab slot `plugins.tab`: only
`dsh-client-ui-plugin-market` registers there (`id: "discover"`), and only while
the experimental plugin-market bundle is enabled. The tested profile does not
have it, which is why the live Plugins page (`[data-plugin-panel]`) has no tab
strip and the settings section has only the inventory tab. Inside the section, the inventory lists the same plugin
rows the Plugins panel shows, with enable switches. The page is data-driven from
`pluginInventory/list`/`pluginManager/*`; a native client can reproduce it
without the DOM (§7).

### 3.4 How a third-party plugin registers its own settings section or tab

The platform **does** allow it: `settings.section` is an ordinary list slot. The
contract states the registrant's options verbatim
(`dsh-client-ui-settings/lib/types/client/contract/slots.d.ts:63`):

> One settings page per list entry. Registrant options carry the nav identity:
> `id` (section key, drives `only` filtering), `order` (nav position), `label`
> (registrant-localized display text — the registrant re-registers with fresh
> text on locale change, so the shell never subscribes locale state; the ledger
> bump doubles as the shell's re-render trigger). Sections render inside the
> panel content column.

The icon slot is documented next to it: *"Optional navigation icons addressed by
the matching settings.section id. The registration id must equal the target
section's id; unmatched ids never render. […] The shell […] keeps its default
glyph when no icon is registered for that id."* A plugin's client module
registers on the same slot the stock sections do; the models section is the
canonical in-tree example:

```js
ctx.slots.inject("settings.section", () => ctx.slots.register({
  name: "settings.section",
  id: "models",
  order: 10,
  label: () => t("nav"),          // thunk: re-read on locale change
  inject: injected,               // rows/actions for the section body
  children: {
    "settings.models.provider-card": { kind: "keyed", scope: "root" },
    "settings.models.footer": { kind: "list", scope: "root" },
  },
}, ModelsSection));
```

A third-party package follows the same shape with its own id, order, label and
`locale` namespace; an icon is an independent registration keyed by the same id:

```js
ctx.slots.inject("settings.section", () => ctx.slots.register({
  name: "settings.section", id: "my-plugin", order: 30,
  label: () => t("nav"), locale: "myPlugin",
}, MySection));

ctx.slots.inject("settings.section.icon", () => ctx.slots.register({
  name: "settings.section.icon", id: "my-plugin", locale: "myPlugin",
}, MyGlyph));
```

Other seats a plugin author may choose instead, in increasing order of what they
own:

| seat | what appears | who uses it in the wild |
|---|---|---|
| `settings.general.item` | one row inside General | in-tree packages: `dsh-client-ui-theme`, `dsh-client-locale`, `dsh-client-ui-shortcuts`, `dsh-client-ui-permission-presets`, `dsh-client-ui-chat`, `dsh-client-ui-settings-general`, `dsh-client-ui-settings-session-log`, `dsh-client-ui-conversation` |
| `plugins.item` | a configuration card inside the Plugins panel's inventory (id per item, `view: 'page'`) | the four official items in-tree: `subagent` (10), `web-search` (20), `agent-loop` (30), `shell` (40) |
| `plugins.row.config` | the configuration page of one Loader row, keyed `"<bundle package>#<rowId>"` | `@ds-hu/dsh-better-search` (`@ds-hu/dsh-better-search#dsh-better-search`), `@ds-hu/dsh-bw-worktree`, `@ds-hu/dsh-bw-forge` |
| `plugins.bundle.config` | the configuration page of a whole bundle, keyed by package name | in-tree: `dsh-experimental-client-ui-cot-translation`, `dsh-experimental-client-ui-voice-input` |
| `settings.section` | a whole root settings page with its own nav row | the five sections in §3.2; no third-party package on the tested host does this |
| `settings.plugins.tab` | a tab next to the plugin inventory | `dsh-client-ui-plugin-inventory` (`all`), plugin-market (`discover`) |

`@ds-hu/dsh-better-search` deliberately does **not** contribute a
`settings.section`; its `docs/CONTRACT.md` (v0.5) records that decision, and the
live settings dialog confirms no extra section. Its configuration lives in
`plugins.row.config` (rendered as the plugin's own page inside the Plugins
panel). So "plugin settings appear under settings" is not a platform rule — it is
one of several placements a plugin chooses. Cuplivo must not assume it.

This is also why `settings/describe` namespaces are not settings tabs: the live
host describes 21 namespaces (`subagent`, `web-search-deepseek`, `ui-settings`,
`agent-preset-registry`, …), each a settings document a plugin or the Host owns.
A namespace can back a section, a row config page, or nothing visible. The
namespace list is useful for native forms (§7); it is not a UI registry.

### 3.4a How Cuplivo renders a plugin-contributed settings section

The implementation is generic and name-agnostic:

- `DshSurfaceHarvest.settingsScript` opens the official settings dialog through
  the `settings.launcher`/`settings.trigger` anchors, reads the `nav button`
  labels of `[role="dialog"][data-shortcut-modal="settings"]`, posts
  `{v:1, settings:[{label}…]}` on the `CuplivoHost` channel, and (with a
  `landLabel`) leaves the dialog on that section.
- `DshSurfaceInventory.shared` merges the message into the per-authority
  snapshot. `snapshot.pluginSettingsSections` is every harvested label that is
  not one of DSH's own (`DshSettingsSectionLabels.builtIn`, all eight shipped
  locales — §6.2b).
- The assistant settings page appends one tab per such section and lands its
  inline official-WebUI body with `settingsScript(landLabel: <label>)`. A visit
  is required because the Host RPC never lists those slots.
- The 内置插件 tab keeps one `打开官方设置` affordance for that visit and for
  plugins whose configuration lives in `plugins.row.config` (the better-search /
  better-workspaces placement below).

On the tested host for this PR (`@ds-hu/dsh-better-search` +
`@ds-hu/dsh-better-workspaces` installed) the harvest reports **no**
plugin-contributed settings section, and that is the correct result: neither
package registers `settings.section` (better-search chose `plugins.row.config`,
better-workspaces contributes sidebar/rail entries). Cuplivo therefore shows the
five native tabs and no plugin tabs, and the generic mechanism is exercised by
unit tests plus any plugin that does register the slot. The R5/R7 harvest is
where the two installed plugins are accepted live.

---

## 4. Q2 — The sidebar rows: slot, owner, and what is discoverable

### 4.1 The `sidebar.panellist` slot

`dsh-client-ui-sidebar` declares the sidebar shell and its holes
(`dsh-client-ui-sidebar/lib/types/client/contract/slots.d.ts`). The global panel
row list is:

```ts
'sidebar.panellist': {
  kind: 'list';
  scope: 'root';
  owner: SidebarPanelIconOwnerProps;   // { size, active }
};
```

The contract text is explicit: *"Global panel icons. Each list id addresses the
matching main panel; the sidebar owns the button and resolves its label from list
metadata."* Concretely, the sidebar builds its row metadata from
`ctx.slots.entriesOfSlot("sidebar.panellist")` as `{ id, order: order ?? 0, label: resolveSlotLabel(label) ?? id }`,
sorts by `order`, and for each row renders a `button` whose `aria-label` is the
resolved label, whose glyph is the registered component, and whose
`aria-current="page"` marks the panel currently shown by `main`
(`dsh-client-ui-sidebar/lib/client.js:206` `PanelRow`; metadata at `:690`).
Clicking calls `ctx.layout.selectPanel(id)`; the matching `main` keyed
registration supplies the page.

Therefore **a row is a pair**: a `sidebar.panellist` registration (id, order,
label, icon) and a `main` registration with the same key. A package that
registers only the first gets a row that opens nothing; one that registers only
the second gets a page with no navigation (and `selectPanel` can still throw if
the main key is missing — see the layout service types).

### 4.2 The rows on the live host

| row (zh / en) | nature | slot registration | page (`main` key) | notes |
|---|---|---|---|---|
| 插件 / Plugins | built-in | `sidebar.panellist` id `plugins`, order 0, package `dsh-client-ui-plugin-manager` | `plugins`, same package | always pinned; the sidebar ignores attempts to unpin it (`setPinned` returns early for `plugins`). Live page heading: 插件 / 安装、启用和配置插件 |
| 搜索服务 / Search services | **plugin** | `sidebar.panellist` id `better-search`, order 5, package `@ds-hu/dsh-better-search` (client module) | `better-search`, same plugin | **optional module**: mounted only while the plugin's persisted preference is on; its configuration page inside the Plugins panel (插件 → 搜索服务 → 配置) has a 侧边栏入口 switch that unmounts both registrations live, without a reload. Live row present because the host fixture left it on. |
| 自动化任务 / Automation tasks | built-in | `sidebar.panellist` id `schedules`, order 10, package `dsh-client-ui-schedule` | `schedules`, same package | live page has 新建 / 已开启 / 已暂停 / 已结束 / 全部 tabs |
| 更多 / More | built-in, **not a page** | none — the sidebar's own `PanelMoreMenu` (`dsh-client-ui-sidebar/lib/client.js:240`) | none | rendered only while `sidebar.panellist.actions` has at least one registration (`hasEntryActions`); a button with `aria-haspopup="menu"`, no `aria-current`; its menu content is the registrant's |

Source refs: plugin manager `PANEL_ID = "plugins"` and the panellist registration
at `dsh-client-ui-plugin-manager/lib/client.js:7680` and around `:7810`;
schedule `PANEL_ID = "schedules"` at `dsh-client-ui-schedule/lib/client.js:19198`
and its panellist registration at `:19388` (`order: 10`); better-search module at
`dsh-better-search/lib/client.js:110-135` (`order: 5`, `main` key `better-search`,
both released together by the page's switch).

### 4.3 The 更多 row is a menu, not a destination

This row deserves its own paragraph because it is the easiest thing to
mis-model. There is no `sidebar.panellist` registration for it and no `main`
page: the sidebar renders it after all panel rows when any
`sidebar.panellist.actions` registration exists, and its menu content is whatever
that list renders (`OwnerProps` includes `entries`, `onOpen`, `onPinnedChange`,
`onDismiss`, plus the region's injected callbacks).

Stock registrant: `dsh-client-ui-entry-customization`, id `entry-customization`,
rendered by `EntryMenuContent` with `region: "sidebar"` (registered at
`dsh-client-ui-entry-customization/lib/client.js:190`). Its menu for the sidebar
region contains only:

- **浏览更多插件 / Browse other plugins** — shows while the optional
  `pluginNavigation` service is present; calls
  `ctx.get("pluginNavigation").openList()`, i.e. switches the main panel to the
  Plugins list and resets its view (client-side API, `dsh-client-ui-plugin-manager/lib/client.js:7801`).
- **创建你的插件 / Create your plugin** — starts a new session with
  `agentPreset: "cordis"` and a region-specific prompt
  (`createPrompt.sidebar`).

The same component is registered into `conversation.session.header.views.actions`
(region `conversation`, where it also lists folded conversation views) and
`sidebar.right.tab.guide.actions` (region `rightbar`). For the sidebar region the
`entries`/`onOpen`/`onPinnedChange` props it receives are ignored by this stock
registrant — the sidebar's 更多 menu therefore never lists panel rows. Live
confirmation: the menu contained exactly 浏览更多插件 and 创建你的插件.

Consequences: the row may be absent (if the entry-customization package is
disabled, or a different composition has no actions registrant); its label is
localized; it opens a menu, not a page; and a click on it cannot be treated as
"open 更多 page".

### 4.4 What is discoverable over the Host RPC — and what is not

Plugin state is split between Host and browser. The Host knows packages, rows,
bundles, enablement and patch targets; it knows nothing about how the browser
placed them.

**Host-side (RPC, verified live):**

| method | result (trimmed to shape) | what it can drive |
|---|---|---|
| `pluginInventory/list` | `{ managementAvailable: true, entries: [{ entryId, moduleName, enabled, fiberPhase, meta: { title: {zh,en,…}, description: {…}, icon? }, diagnostic? }], agentPresets? }` — 204 entries on the live host | a native plugin inventory screen, enable/disable controls, "is this package present" checks |
| `pluginManager/listPlugins` | same data plus `patchId` or `readOnlyReason` per row — 204 rows live | native toggles with the same restrictions the official page shows |
| `pluginManager/listBundles` | `BundleInfo[]`: `name`, `version`, `enabled`, `official`, `availability`, `listedByDefault`, `installTarget`, `meta.title/description`, `description`, `rows: [{ rowId, moduleName, meta, entryId? }]`, `overrides`, … — 26 bundles live, including `@ds-hu/dsh-better-workspaces` with rows `bw-diff`/`bw-worktree`/`bw-status`/`bw-forge` | a native plugin list grouped by bundle, install/update/remove, per-row enablement, and the row identity a WebView landing script can target (§6.4) |
| `pluginManager/registries` | `{ registry, fallbackRegistries, resolved }` | registry pickers |
| `pluginManager/inspect` | accepted/refused install-spec inspection (name, version, bundle flag, registry) | add-plugin validation |
| `pluginManager/readBundleDetail` | bundle README/documents by locale, with files | native detail pages (markdown) |
| `pluginMarket/*` | plugin index entries and detail; off unless configured | optional discover UI |
| `pluginRecommendations/describe` | recommendation metadata | optional |
| `dynamicCordisRunner/*` | the Cordis runner panel's host side | optional |

Exact envelope, error handling and auth are in `protocol.md`; the payloads above
were captured live and match the package type declarations
(`dsh-host-plugin-inventory/lib/types/types.d.ts`,
`dsh-plugin-manager/lib/types/types.d.ts`).

**Not on the wire at all:** whether a bundle has a browser half. `BundleInfo`
carries rows, versions and enablement but no client flag, and
`pluginInventory/list` exposes no UI surface; the only enumeration of client
modules is `window.__DSH_BOOT__.entries` inside the page (§2.1).

**Browser-side (no RPC):** slot registrations (settings sections, panel rows,
right-rail page types, guide cards), their labels, orders, icons, components, and
the client navigation service. `ctx.slots`, `ctx.layout`, `ctx.sidebarRightTabs`,
`ctx.pluginNavigation` are in-memory services; there is no global that exposes
them to injected script (the only page globals are `__DSH_BOOT__`,
`__DSH_BOOT_READY__`, `__DSH_CONNECTION_RECOVERY__`, `__DSH_SHORTCUTS_CONFIG__`,
`__DSH_LOCALE__`, `__DSH_REMOTE_ACCESS__`, `__DSH_FILE_UPLOAD__`,
`__DSH_MODELS_ONBOARDING__`, `__DSH_HOST_PATHS__`, `__DSH_DIRECTORY_PICKER__`,
`__DSH_CONTACT_CONFIG__`, `__DSH_DOCUMENT_PREVIEW_CONFIG__`,
`__DSH_CODE_ICON_INSTANCE__`, plus the module loader itself; none is a context
handle). The settings dialog's `settings/describe` data is Host-side, but the
settings *sections* are not.

So the division is: **RPC can tell Cuplivo that the 搜索服务 plugin exists and
what its package/row ids are; only the browser can tell Cuplivo where its row
sits, what it is called today, and what its page looks like.** Any native UI that
shows plugin entry points must therefore either (a) be Cuplivo's own entry list,
fed by RPC data, with generic labels Cuplivo controls, or (b) leave the official
rail to a WebView.

### 4.5 Enumerating and clicking rows from injected JS

The version-tolerant anchor is the slot name, not the label:

```js
// label-free enumeration of the global panel rows
const rows = [...document.querySelectorAll('nav button')]
  .filter((b) => b.querySelector('[data-slot="sidebar.panellist"]'))
  .map((b) => ({
    label: b.getAttribute('aria-label') ?? b.textContent.trim(),
    active: b.getAttribute('aria-current') === 'page',
    more: b.getAttribute('aria-haspopup') === 'menu',   // the More row
  }));
```

The nav itself is `nav[aria-label]` (`全局面板` / `Global panels`); the rows are
direct children but are not marked with ids. Open one by clicking the button (a
plain `element.click()` works; the handler is React's delegated listener), then
verify success by waiting for `aria-current="page"` on the same button or for the
expected page content. The 更多 row has `aria-haspopup="menu"` and no
`aria-current`; its menu appears as `[role="menu"]` with `[role="menuitem"]`
children.

The label is needed only for the user-facing choice; a Flutter client can show a
list of labels read at runtime and open the row the user picked without ever
hardcoding one. If it must open a *particular* row programmatically (e.g. "open
the Plugins panel"), it needs either a locale label table or a probe: click rows
in order until the page identifies itself (`[data-plugin-panel]` for the plugin
manager; a heading or `[data-slot]` content for others). §6.3 gives the probe
shape and its cost.

---

## 5. Q3 — The right rail and its plugin cards

### 5.1 Family, owner and slots

`dsh-client-ui-sidebar-right` owns the right column. It declares seven slots
(`dsh-client-ui-sidebar-right/lib/types/client/contract/slots.d.ts`):

| slot | kind | scope | purpose |
|---|---|---|---|
| `rightbar.session` | single | session | the rail's session-bound body |
| `sidebar.right.pane.tab` | keyed | session | one open tab body, keyed by the **page type id** |
| `sidebar.right.pane.tab.title` | keyed | session | that tab's chip title renderer, same key |
| `sidebar.right.tab.guide` | chain | session | the guide page (the "开始" tab) |
| `sidebar.right.tab.guide.entry` | keyed | session | an optional custom card for one guide entry, keyed by provider id |
| `sidebar.right.tab.guide.actions` | list | session | rows of the guide's More menu |
| `sidebar.right.tab.menu.item` | list | session | rows of a tab's More menu |

The keyed body slot is **not** keyed by `kind`: it is keyed by the page type's
`id` (`SidebarRightTabDefinition.id`, "a package name is the natural value"),
because a kind can be taken over by an extension. This is the single most common
mistake when reading plugin source: the body is registered under
`dsh-better-workspaces/diff`, while the tab is opened by `kind: "bw-diff"`.

### 5.2 How a page type (and therefore a card) registers

A plugin calls the tab registry service through the client context:

```js
ctx.effect(() => ctx.sidebarRightTabs.register({
  id: "dsh-better-workspaces/diff",     // stable implementation identity
  kind: "bw-diff",                       // what openTab() names
  priority: "extension",                 // extension > builtin > fallback
  multiple: false,                       // one page per kind unless set
  title: () => t("view.diff"),           // tab chip at open time
  guide: [{                              // zero or more guide cards
    id: "diff", order: 20,
    title: () => t("guide.title"),
    description: () => t("guide.description"),
    icon: DiffGlyph,
  }],
}));
```

and supplies the body and chip title as keyed slot registrations under the same
`id`:

```js
ctx.slots.inject("sidebar.right.pane.tab", () => ctx.slots.register({
  name: "sidebar.right.pane.tab",
  key: "dsh-better-workspaces/diff",
  inject: (sessionId) => ({ sessionId }),
}, SidebarDiffBody));

ctx.slots.inject("sidebar.right.pane.tab.title", () => ctx.slots.register({
  name: "sidebar.right.pane.tab.title",
  key: "dsh-better-workspaces/diff",
}, SidebarDiffTitle));
```

The registry types document the three pieces as "stage one (what a type is)",
"stage two (the body)", and the guide entry; `title`/`guide[].title`/
`guide[].description` are thunks re-read on every use. Priority bands let an
extension take over a built-in kind; the built-in resumes when it unregisters.
Registration order breaks ties between types that recognize the same resource
address; address-recognition (`patterns` + `canOpen`) exists for resource viewers
(files, previews), not for the guide cards themselves.

`better-workspaces` factors this into a helper so its three pages cannot drift:
`dsh-bw-core/client/sidebar-page.js:56` `registerSidebarPage(ctx, definition)`
registers the tab type plus the keyed body and title slots, gated behind
`ctx.inject(['sidebarRightTabs'], …)` so a DSH without a right rail keeps the
rest of the bundle alive. The per-row definitions are
`dsh-bw-diff/lib/client.js:2816`, `dsh-bw-worktree/lib/client.js:2910`,
`dsh-bw-forge/lib/client.js:2648`.

The guide card itself is rendered by the rail's guide page from each definition's
`guide` array, in ascending `order`; a type may supply a custom card component
via `sidebar.right.tab.guide.entry` keyed by its provider id (the terminal does
this to add a launch menu button to its card). The card DOM carries the kind:

```html
<button data-sidebar-right-guide-entry="bw-diff">代码变更 …</button>
```

`sidebar.right.tab.guide.actions` supplies the guide's own More menu rows; on the
live host that is `entry-customization` with region `rightbar`, so the menu
contains 浏览更多插件 / 创建你的插件 (create prompt: "创建一个带右侧栏入口的 DSH
插件。"). There is no per-card Pin control in the guide.

### 5.3 Built-in page types and the live rail

Stock page types on the tested profile:

| id | kind | priority | guide card | source |
|---|---|---|---|---|
| `@deepseek-ai/dsh-client-ui-sidebar-files` | `files` | builtin | 工作区文件 / Workspace files, guide id `workspace`, order 10 | `dsh-client-ui-sidebar-files/lib/client.js:14,22` |
| `@deepseek-ai/dsh-client-ui-sidebar-terminal` | `terminal` | builtin | 新建终端 / New terminal, guide id `new`, order 20, `multiple: true` | `dsh-client-ui-sidebar-terminal/lib/client.js:630` |
| `@deepseek-ai/dsh-client-ui-sidebar-documentpreview` | `text` | fallback | no guide card; opened by a file address, yields to more specific viewers | `dsh-client-ui-sidebar-documentpreview/lib/client.js:1184,1210` |
| browser type | — | — | absent on this host (experimental bundle off) | — |

A guide card is not implied by a page type: four more stock packages on this
profile register page types that are opened from context instead — the schedule
task tab (`dsh-client-ui-schedule/lib/client.js:941`), the deliverables
changes-review viewer (`dsh-client-ui-deliverables/lib/client.js:2009`, address
pattern `dsh-resource://changes-review/**`), the plan preview
(`dsh-client-ui-plan/lib/client.js:751`) and the subagent chat
(`dsh-client-ui-subagent/lib/client.js:825`). None declares `guide`, so none draws
a card. The browser type exists in the install
(`@deepseek-ai/dsh-client-ui-sidebar-browser`) but its bundle is not booted on
this host, which is why no 浏览器 card appears.

Live rail, opened with the aria-label 打开右侧边栏 button in the conversation
header, showed exactly five cards in this order: 工作区文件 (`files`), 代码变更
(`bw-diff`), 新建终端 (`terminal`), 新建 worktree (`bw-worktree`), Issue 与 PR
(`bw-forge`). Clicking the `bw-diff` card opened a tab whose chip text is `diff`,
and its body appeared under `[data-slot="sidebar.right.pane.tab"]`; the tab strip
is a dockkit tablist (`role="tab"`, `aria-selected`, `data-dockkit-tab`; panels
`data-dockkit-pane`).

### 5.4 Does `better-workspaces` contribute rail cards? Yes — three

The installed `@ds-hu/dsh-better-workspaces@0.4.1` is a meta bundle with four
rows and one shared library. Exact contributions:

| row | rail page | kind | page type id | guide id / order | also |
|---|---|---|---|---|---|
| `bw-diff` | 代码变更 / Changes | `bw-diff` | `dsh-better-workspaces/diff` | `diff` / 20 | diff page, editor, action ladder |
| `bw-worktree` | 新建 worktree / New worktree | `bw-worktree` | `dsh-better-workspaces/worktree` | `worktree` / 30 | composer worktree strip; `plugins.row.config` page for its directory setting |
| `bw-status` | none | — | — | — | workspace branch badge + composer diff pill (`conversation.input.dock`), DOM injections |
| `bw-forge` | Issue 与 PR / Issues & PRs | `bw-forge` | `dsh-better-workspaces/forge` | `forge` / 40 | composer GitHub control; `plugins.row.config` page |

The three rail bodies are keyed slot registrations under the `id`s above and
their titles under the same keys; the cards are the guide entries from the
definitions. `bw-worktree` and `bw-forge` additionally register
`plugins.row.config` with keys `@ds-hu/dsh-better-workspaces#bw-worktree` and
`@ds-hu/dsh-better-workspaces#bw-forge` (`dsh-bw-worktree/lib/client.js:3074`,
`dsh-bw-forge/lib/client.js:2812`); `bw-diff` and `bw-status` do not.
`bw-status` is the proof that "a plugin row is installed" does not imply "the
plugin contributes a rail page".

The plugin's own ADRs document two things relevant to Cuplivo: ADR 0006 defines
the right-rail page-type extension point, and ADR 0001 documents the
DOM-injection-over-slot-shadowing technique the bundle uses on surfaces without
additive slots (portal + scoped CSS + MutationObserver). That technique is
exactly what Cuplivo would have to imitate to render a plugin surface natively —
an argument for the WebView, not against it.

### 5.5 Discoverability of the rail

Nothing on the rail is on the wire: page types, guide cards and open tabs are
in-memory. What a WebView can read:

```js
// guide cards, label-free by kind
[...document.querySelectorAll('[data-sidebar-right-guide-entry]')]
  .map((b) => b.getAttribute('data-sidebar-right-guide-entry'))
// [{kind}...] on the live host: files, bw-diff, terminal, bw-worktree, bw-forge

// open tabs
[...document.querySelectorAll('[role="tab"][data-dockkit-tab]')]
  .map((t) => ({ title: t.textContent.trim(), selected: t.getAttribute('aria-selected') === 'true' }));
```

Other stable hooks owned by the rail: `[data-sidebar-right-expand]` (the expand
button in `conversation.session.header.corner`), `[data-sidebar-right-toggle]`
(collapse), `[data-sidebar-right-panel][data-sidebar-right-open]` (panel root and
state), `[data-sidebar-right-session]` (session id on the panel),
`[data-sidebar-right-tab]` (a tab strip). RPC-side, the only related data is
`pluginManager/listBundles` telling Cuplivo that `bw-diff` etc. exist as Loader
rows — useful to explain absence, useless to render a body.

---

## 6. Q4 — Navigation, deep links, and injected-JS landing

### 6.1 There are no routes

Every in-app navigation is client state: opening 插件, 搜索服务, 自动化任务,
the 更多 menu, the settings dialog, or a right-rail page leaves `location` at the
host root. Probe evidence across all surfaces:

| navigation | `location.pathname` | `hash` | `search` |
|---|---|---|---|
| rail 插件 / 搜索服务 / 自动化任务 | `/` | `""` | `""` |
| settings dialog, sections, close | `/` | `""` | `""` |
| right rail open, guide card, tab | `/` | `""` | `""` |
| plugin bundle detail / row config / item detail | `/` | `""` | `""` |

The client bundle contains no `history.pushState`/`replaceState` call and no
hash router; `dsh web` serves one HTML shell, and unknown paths 404 rather than
render (the server has no SPA fallback). The official client's own cross-plugin
navigation is the client API `ctx.pluginNavigation.openList()` /
`openBundle(name)` (`dsh-client-ui-plugin-manager/lib/types/client/index.d.ts:17`,
provider at `lib/client.js:7801`), which simply calls
`ctx.layout.selectPanel("plugins")` and sets the plugin manager's internal view
state. `openBundle` accepts a package name and opens its detail page without
changing the current session — the only official "deep link" that exists, and it
is callable only from inside the client, not from injected script.

Practical result: **no URL can select a page**, and a WebView must land by
driving the DOM, or accept whatever state the SPA restores.

### 6.2 Enumeration recipes (what exists, generically)

Each recipe below is label-free where an anchor exists, and label-dependent only
where DSH itself exposes nothing else. All were executed on the live host.

**a. Global panel rows**

```js
const rows = [...document.querySelectorAll('nav button')]
  .filter((b) => b.querySelector('[data-slot="sidebar.panellist"]'))
  .map((b) => ({ label: b.getAttribute('aria-label'), active: b.getAttribute('aria-current') === 'page' }));
```

**b. Settings sections**

The shell has a stable dialog marker: `role="dialog"`, `aria-modal="true"`,
`data-shortcut-modal="settings"`. The nav buttons live in its `nav`; only
`aria-current` and text are exposed (no id attribute):

```js
const dlg = document.querySelector('[role="dialog"][data-shortcut-modal="settings"]');
const sections = [...dlg.querySelectorAll('nav button')]
  .map((b) => ({ label: b.textContent.trim(), current: b.getAttribute('aria-current') === 'true' }));
// active body: exactly one [data-slot="settings.section"] outlet
```

**c. Plugins panel pages** — the plugin manager is the one surface with
language-neutral data attributes (verified live):

| selector | value on the live host | meaning |
|---|---|---|
| `[data-plugin-panel]` | present on the panel root | "this is the Plugins panel" |
| `[data-plugin-item="<id>"]` | `subagent`, `web-search`, `agent-loop`, `shell` | an official settings item card |
| `[data-plugin-package="<pkg>"]`, `[data-plugin-status]` | `@ds-hu/dsh-better-search`, `@ds-hu/dsh-better-workspaces`, `disabled`, … | a bundle card |
| `[data-plugin-group]`, `[data-plugin-scope]` | `basic`, `extensions`, `global` | section grouping |
| `[data-plugin-detail="<pkg>"]` | `@ds-hu/dsh-better-search` | a bundle detail page |
| `[data-plugin-name]` | the `<code>` with the package name | bundle identity in the detail |
| `[data-plugin-rows]`, `[data-plugin-row="<entryId or rowId>"]` | `include:dsh-better-search` | the bundle's row list / one row |
| `[data-plugin-row-detail="<pkg>#<rowId>"]` | `@ds-hu/dsh-better-search#dsh-better-search` | a row configuration page |
| `[data-plugin-item-detail="<id>"]` | `subagent` | an official item detail page |
| `[data-plugin-config]` | present inside both detail pages | the mount point of the plugin's React body (`plugins.row.config` / `plugins.item`) |
| `[data-plugin-versions]`, `[data-plugin-source]`, `[data-plugin-loading]`, `[data-plugin-highlight]` | detail sections / states | version and source sections, loading state |

Each row in the bundle detail has exactly two buttons in this order:
`配置 <title>` (opens the row config page) then `启用组件 <title>` / `禁用组件`
(toggles). The detail pages have a back button whose aria-label starts with
`返回` (`返回插件`, `返回 搜索服务`). These texts are localized; the attributes are
not.

**d. Right-rail cards and tabs** — see §5.5
(`[data-sidebar-right-guide-entry="<kind>"]`, `[data-sidebar-right-expand]`,
`[data-sidebar-right-panel][data-sidebar-right-open]`, `[role="tab"]`).

### 6.3 The landing protocol (bounded, verified, degradable)

A WebView landing script should be a small deterministic state machine rather
than a click sequence with sleeps. Shape that worked in the probes:

1. **Wait for the SPA to be interactive.** `document.readyState` is not enough:
   poll until there is a sidebar nav with row buttons and a
   `[data-slot="main"]` outlet. Cold boot ranged from about 4 s to more than
   10 s across the probes; the Plugins panel's own list took another ~2 s after
   the panel opened. Budget ~30 s, then degrade: leave the page as it is; never
   block the Flutter surface.
2. **Dismiss first-run overlays** if present (`role=dialog` named Preview
   Notice/预览通知, button Continue/继续); they cover the whole page and swallow
   clicks. This is a host state, not a user action.
3. **Land.** For each step: wait for the anchor (poll or MutationObserver),
   click once, then *verify the postcondition* — `aria-current="page"` on the
   rail row, `[role="dialog"][data-shortcut-modal="settings"]` for settings,
   `[data-plugin-detail="<pkg>"]` / `[data-plugin-row-detail="<key>"]` /
   `[data-plugin-item-detail]` for plugin pages, the
   `[data-sidebar-right-panel][data-sidebar-right-open]` state plus the expected
   `[role="tab"]` for the rail. On failure retry once after a short delay, then
   stop and stay on whatever surface was reached.
4. **Never assert a URL**, never call a click a success without its
   postcondition, and never read business data out of the DOM — enumeration of
   labels/kinds is the only read.

Concrete landings:

```js
const waitFor = (selector, timeout = 5000) => new Promise((resolve) => {
  const t0 = Date.now();
  (function poll() {
    const el = document.querySelector(selector);
    if (el) return resolve(el);
    if (Date.now() - t0 > timeout) return resolve(null);
    setTimeout(poll, 100);
  })();
});

// settings shell (works signed-in and signed-out)
function openSettings() {
  const launcher = document.querySelector('[data-slot="settings.launcher"] button[aria-haspopup="menu"]');
  const fallback = document.querySelector('[data-slot="settings.trigger"] button[aria-haspopup="dialog"]')
                ?? document.querySelector('[data-slot="sidebar.settings"] button[aria-haspopup="dialog"]');
  const seat = launcher ?? fallback;
  if (!seat) return false;
  seat.click();
  if (launcher) {
    const first = document.querySelector('[role="menu"] [role="menuitem"]');
    if (!first) return false;
    first.click();                        // signed-out menu: 设置 / 意见反馈 / 登录
  }
  return new Promise((resolve) => {
    const t0 = Date.now();
    (function poll() {
      if (document.querySelector('[role="dialog"][data-shortcut-modal="settings"]')) return resolve(true);
      if (Date.now() - t0 > 5000) return resolve(false);
      setTimeout(poll, 100);
    })();
  });
}

// a settings section by runtime label (labels are localized; read them first)
async function openSettingsSection(label) {
  const dlg = document.querySelector('[role="dialog"][data-shortcut-modal="settings"]');
  if (!dlg) return false;
  const target = [...dlg.querySelectorAll('nav button')]
    .find((b) => b.textContent.trim() === label);
  if (!target) return false;
  target.click();
  await waitFor('[role="dialog"] nav button[aria-current="true"]');
  // postcondition: the one settings.section outlet now belongs to that row
  return target.getAttribute('aria-current') === 'true'
      && !!document.querySelector('[data-slot="settings.section"]');
}

// plugin bundle / row page, fully data-driven from pluginManager/listBundles
// bundleName = BundleInfo.name, row = BundleInfo.rows[i]
async function openPluginRowConfig(bundleName, row) {
  if (!document.querySelector('[data-plugin-panel]')) { await openPluginsPanel(); }
  const card = document.querySelector(`[data-plugin-package="${CSS.escape(bundleName)}"]`);
  if (!card) return false;
  card.querySelector('button').click();                       // card head opens the detail
  await waitFor(`[data-plugin-detail="${CSS.escape(bundleName)}"]`);
  const rowEl = document.querySelector(`[data-plugin-row="${CSS.escape(row.entryId ?? row.rowId)}"]`);
  if (!rowEl) return false;
  rowEl.querySelectorAll('button')[0].click();                // 配置
  return waitFor(`[data-plugin-row-detail="${CSS.escape(bundleName + '#' + row.rowId)}"]`);
}
```

`openPluginsPanel()` is the one landing with no anchor: the row that opens the
plugin manager is a `sidebar.panellist` registration with no id in the DOM. Two
acceptable implementations, in order of preference:

- a locale label table for the official rows Cuplivo wants to reach (brittle
  across DSH locales and versions, but simple), or
- a **probe**: click each panel row in order, wait briefly for
  `[data-plugin-panel]`, and stop on the hit; if no row produced it, degrade.
  The probe is label-free and survives renames, but it visibly switches pages
  and mounts plugin pages, so run it only when the WebView is already the active
  surface and only once per page load (cache the row's `aria-label` or index for
  the session).

### 6.4 Where to land for each Cuplivo need

| Cuplivo need | landing |
|---|---|
| the settings shell (any section) | `openSettings()`; then either leave the section list to the user or click a section by its runtime label |
| a plugin's own settings/configuration page | `openPluginsPanel()` → `[data-plugin-package]` card → detail → the row's first button, keyed by `bundleName#rowId` from `listBundles` |
| an official item's configuration page | `openPluginsPanel()` → `[data-plugin-item="<id>"]`; enumerate ids from the DOM (they are not on the RPC) |
| the DSH rail / a plugin rail page | open a session, `[data-sidebar-right-expand]`, then `[data-sidebar-right-guide-entry="<kind>"]` (enumerate kinds from the DOM) |
| a rail page by resource address (file, preview) | native equivalents exist over RPC; no need to land |

---

## 7. Q5 — Native RPC vs embedded WebUI, per surface

The decision rule that falls out of the mechanics: **if DSH owns the data model
for the surface, use the RPC; if a plugin owns the view (and usually its data
too), use the WebView.** "Own the view" is not a judgement call — it is visible
in the registration: slots and page types are browser-only, and plugin pages
talk to their own HTTP routes (better-search under `/better-search/api`,
better-workspaces under `/better-workspaces/api`), not to Host RPC.

### 7.1 Decision table

| surface | where the truth lives | native (RPC) | embedded WebUI | recommendation |
|---|---|---|---|---|
| **Settings — built-in sections** (General, Models, Plugins inventory, Agent presets, Account) | Host settings documents + plugin inventory | yes: `settings/describe` + `settings/update`/`mutate`, `llm/*`, `credentials/*`, `pluginInventory/list` + `pluginManager/*`, `agentPresets/*` | possible but unnecessary | **Native.** Cuplivo's settings page is the product's own; the official settings UI is not a compatibility target. |
| **Settings — plugin-contributed sections/tabs** (`settings.section` from a third-party package, extra `settings.plugins.tab`) | the plugin's browser module | no: the section and its data/actions are client-side; only some are backed by a `settings/describe` namespace | the only honest path; enumerate sections from the DOM at runtime | **WebUI**, entered through one generic "DSH 插件设置" route (the settings shell), not one native tab per plugin. Do not enumerate them as native tabs. |
| **R5 — the sidebar entry list** (插件, 搜索服务, 自动化任务, 更多) | browser slot registry + per-plugin preferences | partial: `pluginInventory/list`/`pluginManager/listBundles` list plugin packages and rows; `schedule/list` lists tasks. No method lists panel entries or their labels | yes: land on the rail; labels order and presence are read from the DOM | **Hybrid, native-first.** Cuplivo renders its own destinations from RPC data (chat, sessions, plugin inventory, automation list). Do not mirror DSH's row list in Flutter, and never hardcode 搜索服务. A generic "DSH 面板" WebView covers plugin rows and the 更多 menu. |
| **R5 — pages opened by plugin rows** (搜索服务 page, any plugin page) | the plugin's React component + its private HTTP routes | no | yes (the only path) | **WebUI**, landed by the row the user chose in the WebView. |
| **R5 — 插件 page (plugin manager)** | Host RPC + browser views for detail/config | mostly: inventory, enable/disable, bundles, install/update/remove, README detail; official item forms and plugin row config pages are browser components (some have RPC namespaces, e.g. `subagent`, `web-search-deepseek`) | yes for the exact official forms | **Hybrid.** Native management list is safe and desirable; a "configure" action on a plugin row opens the WebView at that row's page via `bundleName#rowId`. |
| **R7 — official rail cards** (files, terminal, previews) | Host RPC | yes (workspace files, terminal attach, previews — see `client-reference.md` §3.13 and §3.10) | possible | **Native** where the RPC surface exists (files at minimum); no need to embed the official rail for these. |
| **R7 — plugin rail cards** (better-workspaces diff/worktree/forge, future page types) | the plugin's browser module + private HTTP routes | no: page types and bodies are client-side; the data behind them is plugin-private | yes (the only path) | **WebUI.** One generic "DSH 右侧栏" route that expands the rail and lets the user pick a card; never per-plugin native implementations, never a hardcoded card list. |
| chat-adjacent plugin UI (composer pills, header controls, injected badges) | plugin client modules | no | yes | out of scope; WebView only if parity is demanded |

### 7.2 Why not "one native tab per plugin" or "one native card per plugin"

Three independent blockers, each verified:

1. **No enumeration source with labels.** The RPC knows package metadata titles
   (e.g. `搜索服务`), but that is not the settings/section/card title; the actual
   titles come from the plugin's client locale thunks. The DOM has the rendered
   titles but no stable ids for settings sections, so any mapping back to a
   plugin is heuristic.
2. **No stable invocation.** A native card would need to open the plugin's page,
   which requires the client service (`ctx.layout.selectPanel`,
   `ctx.sidebarRight.openTab`) that exists only in the browser; injected script
   can only emulate clicks.
3. **No data model.** Plugin pages read their own HTTP route groups; nothing
   promises those routes, their shapes, or their authentication are stable, and
   the Host RPC does not proxy them.

### 7.3 Native equivalents worth having, surface by surface

These are the parts of the official surfaces that are *not* plugin views and are
safe to build natively; they make the WebView fallback rare rather than central.
They are already covered in `client-reference.md`; the list is repeated here so
the compatibility decision is self-contained.

| official surface | native source |
|---|---|
| plugin inventory, enable/disable, bundles, install/update/remove, README | `pluginInventory/list`, `pluginManager/*` (§4.4) |
| settings documents and schema forms | `settings/describe`, `settings/update`/`mutate`, `settings/document-updated` |
| models/providers/credentials | `llm/*`, `credentials/*` |
| Agent presets | `pluginInventory.agentPresets`; `agentPresets/list`, `read`, `select` exist on 0.2.2 (`protocol.md` §3) |
| automation list | `schedule/list`/`view`/`history`; mutations via `schedule/*` |
| workspace files (right rail 工作区文件) | `workspaceFiles/*` |
| terminal (right rail) | `terminal/attach` (see `protocol.md`) |

---

## 8. Compatibility rules — what Cuplivo must not hardcode

These rules are the actionable part of this note. They apply to Dart code, tests,
and any WebView landing asset.

1. **No plugin names, package names, module names, row ids, panel ids, page
   kinds or languages.** Not `better-search`, not `@ds-hu/*`, not `bw-diff`, and not the localized
   labels `搜索服务` / `Search services`. Every plugin-derived value must come from
   the RPC (`BundleInfo.name`, `rows[].rowId`, `rows[].entryId`, `entryId`,
   `meta`) or from the runtime DOM (labels, kinds, card ids).
2. **No built-in UI literals as invariants.** In the stock web profile the rail
   normally shows 插件 and 自动化任务 (two built-in rows), plus whatever plugins
   add, plus 更多 only while an actions registrant exists — but any of those
   packages can be disabled. The stock settings nav has four sections signed out
   and five signed in (account prepends). Counts and positions are not stable.
3. **No locale strings.** `设置`, `插件`, `更多`, `配置`, `查看`, `返回`, `内置插件`
   etc. are translation output; DSH ships eight locales. Maintain a label table
   only where no anchor exists, and treat a missing label as "degrade", never as
   an error or a test failure.
4. **No unverified DOM shape beyond the documented hooks.** The hooks worth
   relying on are `[data-slot="…"]` (mirrors slot names), `[data-plugin-*]`
   (plugin manager), `[data-sidebar-right-*]` and the dockkit tab attributes;
   everything else (class names, nesting, button text) is implementation detail.
   Each hook gets a presence check and a fallback path.
5. **No scraping of business data.** Labels and kinds may be read for
   enumeration; settings values, plugin config values, diffs, terminal output and
   session content must come from the RPC (or not be shown).
6. **No assumption that a plugin surface exists.** A plugin can be absent,
   disabled, or have its optional module switched off (搜索服务's own 侧边栏入口
   switch); the entry list must tolerate a shrinking rail at any time. Likewise
   no assumption that the 更多 row exists.
7. **No version-specific claims without a gate.** Gate any version-sensitive
   behaviour on `__DSH_BOOT__.release.version` (and treat the DOM hooks as
   best-effort per version); the checked build is 0.2.2-rc.1.
8. **No bridge plugin.** The reference client installs a Cordis plugin that
   publishes an occupancy table; Cuplivo must not (product constraint). The
   absence of a UI registry on the wire is a permanent constraint, not a TODO.

---

## 9. Risks and version notes

- **The DOM is not a contract.** The slot-name anchors are the most stable
  observation available, but DSH has no deprecation policy for them. A DSH
  upgrade can rename a slot, replace dockkit, or restructure the plugin manager.
  Every landing is best-effort, and the WebView must remain usable without it.
- **Localized labels are the weakest link.** Section rows, rail rows, menu items
  and the plugin manager's action buttons expose only text. On a host whose
  locale is not zh or en, a label-driven landing stops working; the attribute-
  driven ones (`data-plugin-*`, `data-sidebar-right-*`) keep working.
- **The plugin panel's own row controls have no slot anchors.** The plugin
  manager's list/detail/row markup is ordinary React with `data-plugin-*`
  attributes; the two buttons on a row are positional (configure first,
  toggle second). That is measured, not promised.
- **Plugin churn.** Plugin versions change labels, order values, guide entries
  and module switches (`better-search` 0.5's sidebar module is the model: its
  row exists only while its own preference allows). Enumerate at runtime.
- **A second browser client.** The WebView is a real DSH client: it restores its
  own session selection, may show the workspace picker first, and can create
  sessions. Landing scripts must not assume the dashboard state Cuplivo's native
  client holds.
- **The settings shell can be occupied.** `settings.launcher` is a single slot;
  when the account plugin is present it replaces the gear trigger entirely
  (live: no `button[aria-haspopup="dialog"]` outside the account menu). The
  launcher menu's first item is Settings in this build, and the account section appears
  only with a stored credential. Both are current behaviour; both are
  single-slot consequences a future composition could change.
- **`更多` is not guaranteed.** Its only stock registrant is
  entry-customization; a profile can drop it. Its menu rows are discovery
  actions, not panel links, so treating it as a page would be wrong on every
  version.
- **0.2.2-rc.1 specifics.** `sidebarRightTabs` priority bands, keyed body slots
  and guide actions are all present in this build; the plugins' `docs/` record
  `plugins.row.config` and right-rail page types as their supported extension
  points. Earlier 0.2.x builds were not measured here; do not extrapolate
  backwards.

---

## Appendix A — slot quick reference (0.2.2-rc.1)

Settings (`dsh-client-ui-settings` contract): `settings.launcher` (single),
`settings.trigger` (single), `settings.header` (single), `settings.action`
(list), `settings.close` (single), `settings.section` (list), `settings.section.icon`
(list, inline), `settings.plugins.tab` (list), `settings.onboarding` (list),
`settings.general.item` (list).

Sidebar (`dsh-client-ui-sidebar` contract): `sidebar.toggle.badge` (single),
`sidebar.brand.mark` (single), `sidebar.brand.name` (single), `sidebar.panellist`
(list), `sidebar.panellist.actions` (list), `sidebar.workspaces` (single),
`sidebar.settings` (single), `sidebar.footer.action` (list). The sidebar shell
also declares session-row holes (`sidebar.session.row.leading`,
`sidebar.session.row.trailing`, `sidebar.workspaces.session.row.action`).

Layout (`dsh-client-ui-layout`): `main` (keyed), `rightbar` (single),
`shell.bottom` (single), `shell.overlay` (list), `shell.leading` (single),
`sidebar` (single). The DOM anchors are `[data-slot="main"]`,
`[data-slot="rightbar"]`, `[data-slot="sidebar"]`, …

Plugin manager (`dsh-client-ui-plugin-manager` contract): `plugins.add.actions`,
`plugins.tab`, `plugins.bundle.activation`, `plugins.item`, `plugins.bundle.config`,
`plugins.row.config`, `plugins.detail.actions`, `plugins.detail.badge`,
`plugins.detail.section`. The manager's page chrome adds the `data-plugin-*`
attributes in §6.2c; its own list rows have no slot anchors.

Right rail (`dsh-client-ui-sidebar-right` contract): `rightbar.session` (single),
`sidebar.right.pane.tab` (keyed), `sidebar.right.pane.tab.title` (keyed),
`sidebar.right.tab.guide` (chain), `sidebar.right.tab.guide.entry` (keyed),
`sidebar.right.tab.guide.actions` (list), `sidebar.right.tab.menu.item` (list).

Renderer: every outlet is `<div data-slot="<slot-name>" style="display:contents">`
(`dsh-client-ui-renderer/lib/client.js`, `ANCHOR_STYLE`); list entries are keyed
by id, keyed slots by key.

## Appendix B — live evidence index

All captures are outside the repository (operator research directory
`plugin-compat/shots/`). Grouped by what they prove; names are the probe
artifacts, not part of the product.

| evidence | proves |
|---|---|
| boot capture (`a-boot.json`) | 78 client entries, 3 batches, five `@ds-hu` client packages, release `0.2.2-rc.1` / `c59d10a` |
| rail capture (`b-rail.json`, `rail-02-插件.png`, `rail-03-搜索服务.png`, `rail-04-自动化任务.png`) and click log (`c-rail-click.json`) | four rows with aria-labels, `aria-current` behaviour, URL unchanged at `/` for every row |
| 更多 menu (`d-more-menu.json`) | menu items 浏览更多插件 / 创建你的插件, `aria-haspopup="menu"` |
| settings seat (`e-settings-trigger.json`, `p2-settings-seat.json`, `p3-account-menu.json`) | launcher replaces the trigger when signed out; account menu 设置 / 意见反馈 / 登录; first item opens settings |
| settings DOM (`p2-settings-dom.json`, `p2-settings-sections.json`, `p2-settings-2-内置插件.png`, `p5-settings-tab-2.png`) | four signed-out nav rows, one section body outlet, `[data-shortcut-modal="settings"]`, URL `/`, section switching by index |
| plugins page (`p2-plugins-dom.json`, `p2-plugins-page.png`, `p7-plugin-list.png`) | `plugins.item` ids `subagent`/`web-search`/`agent-loop`/`shell`; bundle cards with `data-plugin-package`/`data-plugin-status`; no Discover tab |
| plugin detail/config (`p2-plugin-row.json`, `p8-bundle-detail.png`, `p8-row-detail.png`, `p8-results.json`) | bundle detail `@ds-hu/dsh-better-search`, row `include:dsh-better-search` with 配置/启用组件 buttons, row config page keyed `@ds-hu/dsh-better-search#dsh-better-search`, `[data-plugin-config]` mount |
| item detail (`p6-results.json`, `p6-item-page.png`) | `[data-plugin-item-detail="subagent"]` and its config mount |
| right rail (`p2-right-rail.png`, `p3-results.json`, `p5-rail-diff.png`) | expand/collapse aria-labels, five guide cards with kinds, `diff` tab opened, `[data-slot="sidebar.right.pane.tab"]` body |
| deep-link attempts (`g-deeplinks.json`) | `/plugins`, `/settings`, `?panel=` and `#/` do not select a page |
| generic landing script test (`p4-results.json`, `p5-results.json`) | synthetic clicks on slot-anchored rows work; settings opens through launcher + first menu item; postconditions detectable |

## Appendix C — provenance and redaction

- The Host, its address, launch token, cookies and session contents are excluded
  from this note; the live observations were made through an authenticated
  browser session in the operator's infrastructure.
- The plugin bundles were read from their installed packages (and a read-only
  copy outside this repository); their docs are cited as `docs/CONTRACT.md`,
  `docs/adr/*` of the respective package, not copied.
- The DSH client packages were read from the installed 0.2.2-rc.1 package; line
  references are to that build and will drift.
- Nothing here changes Cuplivo code; the only repository artifact of this round
  is this document.
