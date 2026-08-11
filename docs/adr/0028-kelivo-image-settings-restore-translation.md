# ADR-0028: Bidirectional Kelivo Image-Compression Settings Translation

Cuplivo's image-compression settings (`one_click_compress_*`, four orthogonal
params) and Kelivo's (`image_upload_quality_v1` enum + custom quality +
transparent toggle) are structurally different models. `KelivoImageSettingsMapper`
bridges them across backup import/export so both sides' backups restore the
compression settings in the other app (issue #124).

## Decision

- **Import (Kelivo → Cuplivo)**: `DataSync._restoreFromBackupFile` (the single
  funnel for local/WebDAV/S3 restores) translates upstream keys into Cuplivo's
  native keys. Trigger: String `image_upload_quality_v1` present AND no
  `one_click_compress_*` keys in the file. The second guard makes a Cuplivo
  export (which carries BOTH key sets) restore its own values verbatim instead
  of being re-translated — re-translation would overwrite the file's own
  maxLongEdge with 1568. Unknown enum values fall back to `balanced` with a
  `debugPrint`; out-of-range custom quality (upstream clamps 10–100) is
  clamped to Cuplivo's 50–95 with a `debugPrint`.
- **Export (Cuplivo → Kelivo)**: `_exportSettingsJson` derives the upstream
  keys at export time from the current `one_click_compress_*` values
  (`enabled=false` → `original`; `true` → `custom` + quality passthrough +
  transparent toggle). Derived, never mirror-written — prefs hold no dual
  truth and no staleness is possible when the user later changes Cuplivo
  settings.
- **Lossy in one dimension only**: upstream persists NO long-edge field —
  `custom` is hardcoded at 1568 px (1568/2048/1024 are per-preset constants).
  A Cuplivo long edge collapses to 1568 in Kelivo and stays there if the
  backup returns. `enabled`, `quality` (Cuplivo 50–95 ⊂ upstream 10–100) and
  the transparent toggle round-trip losslessly.
- **Upstream keys are always stripped on import** (whether or not a
  translation fired) — they never linger inert in prefs; exports re-derive
  them.
- **Precedence**: overwrite mode — translated keys win (a Kelivo zip implies
  migration); merge mode — only absent slots fill, local user preferences win.

## Considered Options

1. **Full port of the upstream model** (presets + add-time compression +
   vendored `downsize`): maximum parity, but replaces a working UX and changes
   behavior — rejected as scope creep for a backup-interop feature.
2. **Literal rename of Cuplivo's storage keys to upstream names**: impossible —
   the value domains do not map 1:1 (4 orthogonal params vs 1 enum).
3. **Restore-only translation** (v1 of this ADR): Kelivo→Cuplivo only.
   Superseded — once upstream's `custom` was analyzed, `quality`/`enabled`/
   `transparent` round-trip losslessly, making full "两边备份能够同步"
   achievable at ~40 lines of cost; the only loss is the long edge.
4. **Mirror-writes in SettingsProvider setters** (upstream keys updated on
   every `oneClickCompress*` setter): rejected — dual truth in prefs, stale
   after any non-setter write path, and churns a 5470-line file. Export-time
   derivation is the single source of truth.
5. **Nearest-preset export** (map long edge onto the closest upstream preset):
   rejected — adds mapping complexity for marginal fidelity; `custom` covers
   the general case.

## Consequences

- A Kelivo backup restores its compression settings in Cuplivo (approximated
  only for `custom` quality → clamped to Cuplivo range, long edge → 1568).
- A Cuplivo backup restores its compression settings in Kelivo natively
  (`custom` + quality + transparent); the long edge lands at 1568 in Kelivo.
- Existing Cuplivo users keep their precise local `one_click_*` config in
  merge mode; migration (overwrite) replaces it with the translated values.
- The translation table is documented in CONTEXT.md; if Kelivo changes its
  enum values, unknown values degrade to `balanced` rather than failing the
  restore.
