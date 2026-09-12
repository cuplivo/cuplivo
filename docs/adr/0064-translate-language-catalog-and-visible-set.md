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
   `translate_target_lang_v1` is reconciled on load against the visible set (a
   target outside it becomes null, then resolves to locale → first visible). The
   manage UI's `effectiveTranslateTarget` auto-switches the active target to the
   first still-visible language when the user hides the active one.
5. **One resolver, one catalog.** `translateLanguageDisplayName(l10n, code)` is
   the single display-name resolver; the six duplicated private switches were
   deleted.

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
- `translation_service.dart` still injects `LanguageOption.displayName` (the
  English name) into the `{target_lang}` prompt; the two standalone translate
  pages use the localized resolver. This pre-existing split is intentionally
  left unchanged.
- Adding a future language is now: one catalog entry, one resolver case, and one
  `languageDisplay*` key in all four ARB files — no selector or settings change.
