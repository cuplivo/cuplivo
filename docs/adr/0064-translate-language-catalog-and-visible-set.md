# ADR-0064: Translate Language Catalog and User-Visible Set (翻译语言目录与可见集)

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
   `translate_visible_languages_v1` (native `StringList`, KV/SQLite), exposed by
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
4. **The active target is always visible.** Persisted
   `translate_target_lang_v1` is soft-nulled on load when it falls outside the
   visible set (then resolves to locale → first visible); the persisted key is
   kept, so re-enabling the language restores the user's original choice. The
   manage UI's `effectiveTranslateTarget` auto-switches the active target to the
   first still-visible language when the user hides the active one.
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

## Consequences

- The preference is a plain business KV key: it rides `settings.json` backup and
  `settings_meta.json` LWW automatically, with no key-registry edit and no
  `mergeableKeys` union. Absent-key backups restore to the historical nine.
- `translateVisibleLanguages` returns a referentially stable immutable set
  between mutations, so callers can `context.select` it without rebuilding on
  unrelated notifications.
- The desktop standalone-translate selector is the shared
  `DesktopSelectDropdown` (extended with an optional `leading` glyph, an
  optional `footer` row, opt-in `focusable` keyboard support, arrow-key
  traversal with `ensureVisible`, and a `Semantics` trigger), not a
  page-private overlay. The shared dropdown refreshes an open menu when its
  options or value change underneath, and closes itself before a footer action
  launches a modal. `focusable` stays opt-in so the seven pre-existing call
  sites do not silently gain a tab stop.
- `translation_service.dart` now builds `{target_lang}` through
  `translateLanguageDisplayName`, so the in-chat and standalone translate paths
  share one localized prompt vocabulary.
- Adding a future language is now: one catalog entry, one resolver case, and one
  `languageDisplay*` key in all four ARB files — no selector or settings change.
