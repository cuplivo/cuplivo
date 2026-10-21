# ADR-0014: Translate Language Catalog and User-Visible Set (翻译语言目录与可见集)

The translate-target selector was a fixed 9-language list
(`language_select_sheet.dart` `supportedLanguages`), with six more languages
left commented out and no way for users to trim the list. Issue #767 asked for
Bangla. Adding it — and any future language — meant a fixed list that grows for
everyone, plus a display-name `switch` duplicated across six copies in three
files. We decided to separate the *catalog* (what the app can translate to) from
the *visible set* (what this user sees), and to make the visible set a
user-managed, persisted preference.

## Decision

1. **Catalog is code, visibility is data.** The catalog is the `const
   supportedLanguages` list (now 16: the original 9 plus `pt, ru, ar, hi, th,
   vi, bn`). The visible set is the business preference
   `translate_visible_languages_v1` (native `StringList`), exposed by
   `SettingsProvider.translateVisibleLanguages`.
2. **Default is the historical nine.** When the key is absent, the visible set
   is `defaultTranslateVisibleLanguages` (the original 9). Newly added
   languages are therefore opt-in, so an existing user's selector does not
   silently grow; a new user can enable others in the manage UI.
3. **Catalog order is fixed; the feature is visibility only, no reordering.**
   `visibleTranslateLanguages(codes)` filters the catalog in catalog order and
   is guaranteed non-empty (falls back to the default set). The manage surface
   (mobile bottom sheet / desktop centered dialog) is a checkbox list over the
   full catalog with an at-least-one-visible guard.
4. **The active target is always visible, and never rewritten.** The persisted
   `translate_target_lang_v1` is never rewritten or nulled by a visibility
   change: `effectiveTranslateLanguage(visible, persisted, locale)` is the
   single owner of the target in effect — the persisted code when it is
   visible, else the locale language when that is visible, else the first
   visible catalog entry. Hiding the active language therefore changes what the
   pages show and translate to, while the key keeps the user's choice, so
   re-enabling the language restores that choice immediately and after a
   restart.
5. **One resolver, one catalog.** `translateLanguageDisplayName(l10n, code)` is
   the single display-name resolver used by every entry point (including the
   in-chat `translation_service`); the six duplicated private switches and the
   hardcoded `LanguageOption.displayName`/`displayNameZh` fields were deleted.

## Considered options

- **Hidden set instead of visible set, default all 16 visible**: rejected — the
  selector would grow unexpectedly for existing users and diverge from the
  "opt-in for new languages" intent; the default must reproduce today's list.
- **Reorderable visible list**: rejected — the catalog order is stable and
  ordering was not requested; a set keeps the preference and merge semantics
  simple (whole-value LWW, no union).
- **Keep six private resolver switches and patch each**: rejected — with a
  16-entry catalog, a missed copy renders the raw code; the drift trap is the
  exact defect this change would otherwise preserve.
- **Auto-switch by writing the fallback over `translate_target_lang_v1`** (the
  manager writing `setTranslateTargetLang(firstVisible)` when the active
  language is hidden): rejected — it implements the visibility rule twice, and
  the write is the only thing that makes "re-enabling restores the choice"
  false. The resolver already renders a hidden target correctly, so the write
  had no effect except destroying the preference.

## Consequences

- The preference is an ordinary business key, so it must be registered where the
  business store decides membership: `BusinessKeyRegistry.preferenceKeys` (the
  source-scanning test fails on an unclassified writer) **and**
  `syncedPreferenceKeys`, next to the `translate_target_lang_v1` it belongs to.
  A new device that received a target language without the visible set could not
  show it and would silently fall back to its own locale. Backup needs no
  further edit: it carries every non-device preference row. Absent-key backups
  restore to the historical nine.
- `translateVisibleLanguages` returns a referentially stable immutable set
  between mutations, so callers can `context.select` it without rebuilding on
  unrelated notifications; a write that changes nothing does not notify.
- The desktop standalone-translate selector is the shared
  `DesktopSelectDropdown` (extended with an optional `leading` glyph, an
  optional `footer` row, opt-in `focusable` keyboard support, arrow-key
  traversal with `ensureVisible`, and a `Semantics` trigger), not a
  page-private overlay. The shared dropdown refreshes an open menu when its
  options or value change underneath, closes itself before a footer action
  launches a modal, and bounds its list to a scrollable 360 px viewport now that
  the catalog is 16 entries. `focusable` stays opt-in so the pre-existing call
  sites do not silently gain a tab stop, and the v4 additions this widget
  already carried (`subtitle`, `embedded`) are untouched.
- `translation_service.dart` now builds `{target_lang}` through
  `translateLanguageDisplayName`, so the in-chat and standalone translate paths
  share one localized prompt vocabulary (the in-chat prompt used to name the
  target in English regardless of the UI language).
- Adding a future language is now: one catalog entry, one resolver case, and one
  `languageDisplay*` key in all four ARB files — no selector or settings change.
