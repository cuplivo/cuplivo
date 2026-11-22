import 'dart:convert';

/// The DOM recipes Cuplivo injects into the official DSH Web UI.
///
/// Pure Dart on purpose: the same strings are executed by the embedded WebView
/// and by the CI DOM-contract check (`tool/e2e/dsh_dom_contract.js`, which reads
/// them from `tool/e2e/print_dsh_surface_scripts.dart`), so the recipes the E2E
/// proves against the live Host are literally the recipes the app ships.
///
/// The recipes follow `docs/cuplivo-dsh/plugin-compat.md` §6.3 and §6.3a:
/// - sidebar rows are `nav button` elements that contain the
///   `[data-slot="sidebar.panellist"]` outlet (label = `aria-label`);
/// - the right rail expands through a visible toggle, and its cards are
///   `[data-sidebar-right-guide-entry="<kind>"]` buttons;
/// - the settings dialog is `[role="dialog"][data-shortcut-modal="settings"]`,
///   reached through the account menu at phone widths, and its nav rows are the
///   `settings.section` labels;
/// - at phone widths the sidebar and the right rail are dialogs that have to be
///   opened through their visible toggle first and closed again afterwards.
///
/// Every script is a self-contained async IIFE that posts its result on
/// [channelName]; a failure posts a stage diagnostic and leaves the page usable.
abstract final class DshSurfaceScripts {
  /// Channel name the WebView host registers by default (see `DshWebUiView`).
  static const String channelName = 'CuplivoHost';

  /// The DOM helpers every recipe shares.
  ///
  /// The official UI renders the sidebar and the right rail as *dialogs* at
  /// phone widths, and both are closed by default. A recipe therefore has to
  /// click the visible toggle first, wait for the drawer to slide in, and only
  /// then read or click its rows. The same helpers also drive the account menu
  /// that hosts the 设置 item at phone width, where the well-known
  /// `settings.trigger` button does not exist.
  static const String _domHelpers =
      '''
  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
  const norm = (value) => String(value == null ? '' : value).replace(/\\s+/g, ' ').trim();
  const inView = (element) => {
    if (!element) return false;
    const rect = element.getBoundingClientRect();
    return rect.width > 0 && rect.height > 0 &&
      rect.left >= 0 && rect.right <= window.innerWidth + 1;
  };
  const press = (element) => {
    const base = {
      bubbles: true, cancelable: true, composed: true,
      button: 0, pointerId: 1, pointerType: 'mouse', isPrimary: true,
    };
    element.dispatchEvent(new PointerEvent('pointerdown', Object.assign({}, base, { buttons: 1 })));
    element.dispatchEvent(new MouseEvent('mousedown', Object.assign({}, base, { buttons: 1 })));
    element.dispatchEvent(new PointerEvent('pointerup', Object.assign({}, base, { buttons: 0 })));
    element.dispatchEvent(new MouseEvent('mouseup', Object.assign({}, base, { buttons: 0 })));
    element.dispatchEvent(new MouseEvent('click', Object.assign({}, base, { buttons: 0 })));
  };
  const sidebarOpener = /open sidebar|展开侧边栏|打开侧边栏|打开側邊欄|展开側邊欄|サイドバーを開く|사이드바 열기|seitenleiste öffnen|ouvrir la barre latérale|открыть боковую панель|abrir barra lateral/i;
  const sidebarCollapse = /collapse sidebar|收起侧边栏|收起側邊欄|关闭侧边栏|关闭側邊欄|sidebar schließen|réduire la barre|свернуть боковую|ocultar barra|サイドバーを閉じる|사이드바 닫기/i;
  const railOpener = /open right sidebar|展开右侧边栏|打开右侧边栏|打开右側邊欄|右侧边栏|サイドバーを開く|오른쪽 사이드바 열기|rechte seitenleiste öffnen|ouvrir la barre latérale droite|открыть правую панель|abrir barra lateral derecha/i;
  const railCollapse = /collapse right sidebar|收起右侧边栏|收起右側邊欄|关闭右侧边栏|关闭右側邊欄|rechte seitenleiste schließen|réduire la barre latérale droite|свернуть правую панель|ocultar barra lateral derecha/i;
  const visibleButton = (pattern) =>
    [...document.querySelectorAll('button')].find((button) =>
      pattern.test(norm(button.getAttribute('aria-label'))) && inView(button));
  const settingsTrigger = () =>
    document.querySelector('[data-slot="sidebar.settings"] button[aria-haspopup="menu"]') ||
    document.querySelector('[data-slot="settings.launcher"] button[aria-haspopup="menu"]');
  const settingsDialog = () =>
    document.querySelector('[role="dialog"][data-shortcut-modal="settings"]');
  const navRows = () =>
    [...document.querySelectorAll('nav button')].filter((button) =>
      button.querySelector('[data-slot="sidebar.panellist"]'));
  const openSidebar = async () => {
    for (let attempt = 0; attempt < 40; attempt++) {
      const trigger = settingsTrigger();
      if (trigger && inView(trigger)) return true;
      const opener = visibleButton(sidebarOpener);
      if (opener) opener.click();
      await sleep(250);
    }
    const trigger = settingsTrigger();
    return !!trigger && inView(trigger);
  };
  const closeSidebar = () => {
    const collapse = visibleButton(sidebarCollapse);
    if (collapse) collapse.click();
    return !!collapse;
  };
  const railToggle = () =>
    document.querySelector('[data-sidebar-right-expand]') || visibleButton(railOpener);
  const post = (payload) => {
    try {
      window.flutter_inappwebview.callHandler('$channelName', JSON.stringify(payload));
    } catch (_) {}
  };
''';

  /// Reads the sidebar rows and the right-rail cards, then posts
  /// `{"v":1,"sidebar":[{"label":…}],"rail":[{"label":…,"kind":…}]}` on
  /// [channelName].
  ///
  /// Mobile-safe: at phone widths the official UI turns the sidebar and the
  /// right rail into dialogs, so the script clicks their visible toggles,
  /// waits for the drawer, reads it and closes it again. Chrome rows are
  /// excluded by construction because a sidebar row carries the
  /// `sidebar.panellist` outlet while the brand/session/footer chrome does not.
  static const String harvest =
      '''
(async () => {
$_domHelpers
  try {
  const sidebar = [];
  if (await openSidebar()) {
    for (const button of navRows()) {
      const label = norm(button.getAttribute('aria-label')) ||
        norm(button.textContent).split('\\n')[0];
      if (label && sidebar.indexOf(label) < 0) sidebar.push(label);
    }
    closeSidebar();
    await sleep(300);
  }
  const rail = [];
  for (let attempt = 0; attempt < 30 && !rail.length; attempt++) {
    const toggle = railToggle();
    if (!toggle) {
      await sleep(250);
      continue;
    }
    toggle.click();
    await sleep(700);
    for (const card of document.querySelectorAll('[data-sidebar-right-guide-entry]')) {
      const kind = norm(card.getAttribute('data-sidebar-right-guide-entry'));
      const label = norm(card.innerText).split('\\n')[0] ||
        norm(card.getAttribute('aria-label'));
      if (label) rail.push({ label: label, kind: kind || null });
    }
    if (!rail.length) {
      toggle.click();
      await sleep(300);
    }
  }
  if (rail.length) {
    const collapse = visibleButton(railCollapse);
    if (collapse) collapse.click();
  }
  post({ v: 1, sidebar: sidebar.map((label) => ({ label: label })), rail: rail });
  } catch (error) {
    post({ v: 1, stage: 'script-error' });
  }
})();
''';

  /// Opens the official settings dialog, reports its sections and (when
  /// [landLabel] is given) leaves it open on that section.
  ///
  /// This is a separate script on purpose: the automatic [script] must not pop
  /// the settings dialog on every page load, so Cuplivo runs this one only when
  /// the user asks for the official settings surface or opens a plugin section
  /// tab. Two recipes live here because DSH's settings entry differs by width:
  /// wide layouts have a `settings.trigger` button, while a phone width only
  /// has the account menu inside the sidebar drawer. The dialog's nav rows are
  /// the `settings.section` labels in both cases.
  static String settings({String? landLabel}) =>
      '''
(async () => {
$_domHelpers
  try {
  const landLabel = ${jsonEncode(landLabel ?? '')};
  const postStage = (stage) => post({ v: 1, stage: stage });
  if (!(await openSidebar())) {
    postStage('no-settings-trigger');
    return;
  }
  const trigger = settingsTrigger();
  for (let attempt = 0; attempt < 40 && !settingsDialog(); attempt++) {
    trigger.click();
    await sleep(300);
    const item = [...document.querySelectorAll('[role="menuitem"]')].find((element) =>
      /^(设置|Settings|Preferences|設定|Einstellungen|Préférences|Paramètres|Configurações|Ajustes|Настройки|설정)\$/.test(norm(element.innerText)));
    if (item) press(item);
    await sleep(350);
  }
  const root = settingsDialog();
  if (!root) {
    postStage('no-settings-dialog');
    return;
  }
  await sleep(300);
  const sections = [];
  for (const button of root.querySelectorAll('nav button')) {
    const label = norm(button.textContent);
    if (label && sections.indexOf(label) < 0) sections.push(label);
  }
  if (landLabel) {
    const target = [...root.querySelectorAll('nav button')].find((button) =>
      norm(button.textContent) === landLabel);
    if (target) {
      press(target);
      await sleep(500);
    } else {
      postStage('no-land-section');
    }
  } else {
    const close = root.querySelector('[data-slot="settings.close"] button') ||
      [...root.querySelectorAll('button')].find((button) =>
        /^(Close|关闭|關閉|閉じる|닫기|Schließen|Fermer|Закрыть|Fechar|Cerrar)\$/.test(norm(button.innerText)));
    if (close) close.click();
    await sleep(400);
    closeSidebar();
  }
  post({ v: 1, settings: sections.map((label) => ({ label: label })) });
  } catch (error) {
    post({ v: 1, stage: 'settings-error' });
  }
})();
''';

  /// Landing script for a left-sidebar row: opens the sidebar drawer (or the
  /// sidebar dialog at phone width), clicks the row by its harvested label and
  /// lets the official UI close the drawer itself.
  static String sidebarLanding(String label) =>
      '''
(async () => {
$_domHelpers
  const target = ${jsonEncode(label)};
  for (let attempt = 0; attempt < 60; attempt++) {
    await openSidebar();
    const row = navRows().find((button) =>
      norm(button.getAttribute('aria-label')) === target ||
      norm(button.textContent).split('\\n')[0] === target);
    if (row) {
      press(row);
      await sleep(700);
      break;
    }
    await sleep(250);
  }
  closeSidebar();
})();
''';

  /// Landing script for the official 更多 row.
  ///
  /// 更多 is DSH's own `PanelMoreMenu` entry. Wide layouts register it through
  /// a `sidebar.panellist.actions` outlet; at phone width the same action is
  /// the one sidebar row that has no `sidebar.panellist` outlet at all, so the
  /// recipe clicks the localized label first and falls back to that structural
  /// shape without guessing a label.
  static const String moreMenuLanding =
      '''
(async () => {
$_domHelpers
  const moreLabels = /^(更多|More|その他|더 보기|Más|Plus|Mehr|Ещё|Mais)\$/;
  for (let attempt = 0; attempt < 60; attempt++) {
    await openSidebar();
    const rows = [...document.querySelectorAll('nav button')];
    const more = rows.find((button) =>
        moreLabels.test(norm(button.getAttribute('aria-label')) || norm(button.textContent).split('\\n')[0])) ||
      rows.find((button) => inView(button) && !button.querySelector('[data-slot="sidebar.panellist"]'));
    if (more) {
      press(more);
      await sleep(700);
      break;
    }
    await sleep(250);
  }
})();
''';

  /// Landing script for a right-rail card. Prefers the harvested page-type
  /// [kind] (language-neutral `data-sidebar-right-guide-entry` attribute) and
  /// falls back to the visible [label]; opens the rail first, which is a dialog
  /// at phone width.
  static String railLanding(String label, {String? kind}) =>
      '''
(async () => {
$_domHelpers
  const target = ${jsonEncode(label)};
  const kind = ${jsonEncode(kind ?? '')};
  let card = null;
  for (let attempt = 0; attempt < 40 && !card; attempt++) {
    const cards = [...document.querySelectorAll('[data-sidebar-right-guide-entry]')];
    if (!cards.length) {
      const toggle = railToggle();
      if (toggle) toggle.click();
      await sleep(700);
      continue;
    }
    card = (kind ? cards.find((element) =>
        norm(element.getAttribute('data-sidebar-right-guide-entry')) === kind) : null) ||
      cards.find((element) => norm(element.innerText).split('\\n')[0] === target);
    if (!card) await sleep(300);
  }
  if (card) press(card);
})();
''';
}
