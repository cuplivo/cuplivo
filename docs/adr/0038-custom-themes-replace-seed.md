# ADR-0038: Custom Themes Replace the Legacy Seed; Custom Theme Wins Over System Dynamic Color

Upstream Kelivo's custom-theme system (a `CustomTheme` model with primary/secondary/tertiary
colors generating a TONAL_SPOT M3 scheme via `material_color_utilities`, plus full HSV color
picker and JSON import/export) is ported to Cuplivo. It replaces the fork's single-hue
"custom dynamic seed" (`custom_dynamic` palette + `dynamic_color_seed_v1`), and a custom
theme takes precedence over Android system dynamic color — a deliberate divergence from
upstream, which lets the system scheme override a custom theme.

## Context

The fork shipped a single-color "Custom Dynamic" placeholder palette (`custom_dynamic`,
id `custom_dynamic`) that duplicated the default palette and was recolored at runtime from a
single hue-derived seed (`dynamic_color_seed_v1`). Upstream Kelivo meanwhile built a full
user custom-theme system: named themes, optional secondary/tertiary accents, a complete HSV
color picker, and JSON copy/import (RikkaHub-compatible). The fork's theme module had
deleted `custom_theme.dart` and `app_semantic_colors.dart` during its own theme migration, so
the two lineage diverged.

## Decisions

- **Custom themes replace the seed.** `custom_dynamic` and `HueSlider` are removed. The
  canonical concept is **Custom Theme / 自定义主题**; Dynamic Color (Android system) remains
  an independent, mobile-only toggle.
- **Migrate `dynamic_color_seed_v1` on first load.** If the legacy seed key exists, it becomes
  a Custom Theme with `primary = seed` and no secondary/tertiary. If the active palette was
  `custom_dynamic`, the migrated theme is selected and the palette becomes `'custom'`. The
  legacy key is removed after migration (mirrors upstream's own legacy migration, adapted to
  the fork's key name).
- **Adopt upstream prefs keys verbatim** (`custom_themes_v1`, `custom_theme_selected_v1`) and
  the upstream JSON export format. The keys ride `settings.json` backup/sync automatically
  (all prefs keys are dumped by `SharedPreferencesAsync`; they are not in `_localOnlyKeys`).
  Users can copy a theme JSON out of Cuplivo and import it into Kelivo/RikkaHub and vice
  versa.
- **Custom theme wins over system dynamic color.** When the active palette is `'custom'`,
  `useDynamicColor` is ignored. Upstream instead lets the system scheme override the custom
  theme (`dynamicScheme?.harmonized() ?? staticScheme`); that is treated as an upstream bug,
  not a behavior to copy. This preserves the fork's pre-port semantics (the seed palette
  already won over the system scheme).
- **Import activates the theme.** `importCustomTheme` saves AND selects the imported theme,
  matching the editor flow's save-then-select. Upstream's import only saves, leaving the
  imported theme inactive until the user finds it in the list — an inconsistent two-entry
  UX that the port deliberately unifies.
- **Deleting the active theme falls back to the default palette.** `deleteCustomTheme`
  deselects and returns to `'default'` when the deleted theme was selected. Upstream instead
  silently jumps the selection to the first remaining custom theme, changing the active
  colors without consent. The confirm dialog (mobile list and desktop right-click menu)
  warns that the active theme will switch to the default palette.
- **Phase 1 scope** is the custom-theme core only: model, palette changes, provider CRUD +
  migration, `main.dart` resolution, UI (editor/picker/dots/import-export), l10n, and removal
  of the seed picker residue. `AppSemanticColors` (95-file migration) and the derived
  `surfaceContainer*` roles are deferred to phase 2 — they affect every palette's existing
  rendering and are orthogonal to the custom-theme feature.

## Consequences

- Users with a saved seed get one migrated custom theme named with an empty name (displayed
  as the localized default name); their active color is preserved.
- Selecting a custom theme on Android disables system dynamic color for the session without
  toggling the settings switch — the switch stays visible but inert.
- `HueSlider` and the two seed-picker flows (`_showHuePickerSheet`, `_showDesktopHuePicker`)
  are deleted as dead code.
- Phase 2 remains a standalone, independently reviewable change.