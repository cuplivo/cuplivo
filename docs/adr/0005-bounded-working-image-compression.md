# ADR-0005: A bounded working image for manual compression

**Status:** Accepted (2026-09)
**Deciders:** cuplivo

## Context

ADR-0002 gave the manual editor a 1:1 split compare backed by a bounded decoded cache (≤ 2048 px
long edge, ≤ 4 MP), and made the artifact a separate `Downsize.compress(sourceBytes)` call. Two
problems followed from that split, both measured with `test/perf/manual_compress_bench.dart` on a
desktop build:

- **Peak memory was set by the source, not by the output.** The pure-Dart pipeline costs roughly
  **15 bytes per source pixel**: 13 MP → ~200 MB, 50 MP → ~730 MB, 200 MP → ~3 GB, and an
  out-of-memory kill inside an isolate is not catchable from Dart. `maxLongEdge` did not reduce the
  peak at all (50 MP: 744.8 MB at 1568 px vs 744.1 MB unresized), because `Downsize.compress`
  full-decodes in `decodeImage` before `dynamicResize` runs. The editor is aimed exactly at the
  images that hit this: ADR-0002 chose manual mode because the automatic preset caps destroy long
  screenshots.
- **The comparison was not the artifact.** The right half was a *re-encode of a crop of the
  2048-capped cache*, so for a 1000×8000 screenshot it showed a 0.256× proxy re-encoded — the block
  structure and detail loss on screen were not the ones being produced. Worse, `paramScale` was
  `min(1.0, maxLongEdge / cacheLongEdge)`, so every long edge between the cache's long edge and the
  source's (2048–8000 there, 2048–4032 for a 13 MP photo) produced **no visible change at all** while
  the size row kept moving. `CONTEXT.md` and ADR-0002 both claimed 1:1, which held only for images
  under the cap.

The engine, meanwhile, is cheap: the same measurement shows the decode the app *should* be doing is
not source-proportional. `ImageDecoderSkia::ImageFromCompressedData` allocates
`get_scaled_dimensions(...)` **only when the codec reports an efficient sub-pixel scale**, and falls
back to a full-size raster otherwise. Measured against an identical 1568 px target:

| source | decode peak | bytes per target pixel |
|---|---|---|
| 13 MP JPEG | +13 MB | 11.4 |
| 50 MP JPEG | +19 MB | 12.0 |
| 200 MP JPEG | +19 MB | 12.3 |
| 8.6 MP PNG (long screenshot) | +32 MB | — |
| 13 MP PNG | +57 MB | — |
| 50 MP PNG | +198 MB | — |
| 200 MP PNG | +768 MB | — |

JPEG sub-scales at decode (Skia's JPEG codec reports scaled dimensions); `SkPngCodec` and
`SkPngCodecBase` declare no `onGetScaledDimensions`, so PNG allocates the whole source whatever the
target is. `ImageDescriptor.width`/`height` are EXIF-corrected (verified: a 400×200 JPEG tagged
orientation 6 reports 200×400 without decoding pixels).

## Decisions

1. **One working image, decoded at the artifact's own size.** The editor derives the target long edge
   from the source's header dimensions (never from pixels), decodes once through
   `ImageDescriptor.encoded` + `instantiateCodec(targetWidth/targetHeight)`, and treats those pixels
   as both the comparison's left half and the encoder's input. The source is never materialised at
   full resolution, so peak memory tracks **the chosen output**, not the file: a 200 MP JPEG worked at
   a 1568 px long edge costs ~19 MB to decode.
2. **Preview, size row and artifact are one value.** The artifact is encoded from the working pixels
   with `compressDecoded` and no Dart-side resize (the engine already decoded at the target, so a JPEG
   source is resampled once, in the DCT domain), and the right half is *that* byte sequence decoded
   for display. The size row shows its exact length. The previous "estimate" already was a
   byte-identical full encode whose result was discarded — proven, not assumed — so this is a
   reuse, not new work.
3. **Apply writes the cached artifact.** `CompressEditorApply` carries the bytes and the composer
   stores them through `writeManualArtifactToUploadDir`, so confirming costs a file write instead of a
   second decode and encode. Reuse is gated on the artifact's parameters still equalling the
   selected ones; a parameter change drops the artifact synchronously, so a stale encode can never be
   shown or written. `应用到全部` still runs the pipeline per image, now through the same budgeted
   path.
4. **One pass in flight, coalescing.** A started decode cannot be cancelled, so a parameter change
   during a pass only sets a pending flag: the pass re-runs once with the newest parameters. The
   editor exposes a test-only counter for this, since a second overlapping pass is what doubles the
   peak.
5. **Budgets, and a gate instead of a crash.** The working image is capped at **14 MP (mobile) /
   20 MP (desktop)** of working pixels — enough for a 13 MP attachment to keep 100% — and a decode may
   allocate at most **300 MB / 500 MB**. A source that cannot be decoded inside the budget is refused
   with an explanation and no apply action, which extends ADR-0002's "offered only where it can act"
   rule to memory. This is what refuses a 200 MP PNG (768 MB) while admitting any JPEG at any
   reachable target.
6. **The reachable range is the honest range.** The long-edge slider's maximum is
   `min(sourceLongEdge, budgetLongEdge)`, so the panel cannot offer a resolution the pipeline will not
   produce, and when the source had to be reduced the panel says so ("Source 20000×10000, loaded at
   37%…"). A remembered long edge is normalised into that range once the source's size is known —
   not before, when there is no range yet.
7. **Framing defaults to fit-to-width, capped at 1:1.** Contain-fit is always ≤ fit-to-width and the
   two differ only for tall images, which is precisely the failing case: a 1000×8000 screenshot in a
   390 px viewport was drawn 75 px wide. Fitting the width keeps it legible and pans vertically. 1:1
   now means one artifact pixel per logical pixel, which is true because the working image *is* at the
   artifact's resolution.
8. **The automatic pipeline shares the decode and keeps its own rules.** `auto` keeps its attach-time
   presets, its minimum-size guard, its transparency opt-in and its always-JPEG output; what changed is
   that it decodes through the same budgeted working image instead of `Downsize.compress(sourceBytes)`,
   and with the preset as an exact long-edge cap rather than the editor's 25% floor. A source too large
   for the decode budget is **skipped like any other skip** — the pristine copy stays in place — because
   "skip and keep" is already this pipeline's contract. Without this, a 200 MP attach in `auto` still
   materialised the full source at ~3 GB, which is the same crash the editor was fixed for.

## Consequences

- Peak memory for the editor is now ~12 bytes per working pixel plus a ~45 MB encode-isolate
  transient: measured ~65 MB above baseline for a 200 MP JPEG, where the old path extrapolates to
  ~3 GB. Two concurrent tasks (the composer's queue runs two) stay inside the stated working set.
- **The artifact's bytes can differ from the old pipeline's** for the same parameters: the source is
  now resampled by the codec to the target instead of by `copyResize(Interpolation.average)` from a
  full decode. The panel's promise — the size and pixels shown are the size and pixels written — is
  what holds, and it holds *because of* the reuse.
- The tile machinery is gone: no crop, no per-tick re-encode, no 1280 px tile cap, no stale-tile
  branch. `encodeManualBytes` and `decodeForPreview`/`previewCacheSize` are deleted rather than kept
  as compatibility shims.
- A PNG source above the budget loses its editor entry point (message, no action) instead of
  attempting a decode. Ordinary screenshots are far below it: the motivating 1080×8000 case needs
  ~40 MB.
- `dart:ui` owns the decode, so the editor's pipeline needs the UI isolate; only the encode runs in an
  isolate, and its pixels cross as `TransferableTypedData` (a move, not a copy).
- **`auto` mode is bounded too, and its resampling changed with it.** A 200 MP attach no longer
  full-decodes, and a source over the budget is skipped (pristine copy) instead of risking the process.
  Its artifact bytes can differ from an older build's for the same preset, for the same reason the
  editor's can: the target-size resample now happens in the codec. Output naming, the minimum-size
  guard, the transparency opt-in, the always-JPEG format and the "never larger than the input" skip are
  unchanged, and every existing automatic-pipeline test still passes.
- The automatic pipeline's decode now happens on the UI isolate through `dart:ui` (which does the work
  off-thread) rather than inside a `compute` isolate, because the engine's decoder needs a UI isolate.
  Only the encode still crosses into an isolate.

## Not in scope

- Cropping (still deferred per ADR-0002; the pipeline is decode → resize → encode).
- Native codecs (`flutter_image_compress`, platform thumbnail APIs): only needed if a >500 MB PNG
  source must be supported, and it would break the "estimate equals artifact" byte-for-byte identity
  unless the whole path moved.
- A user-facing budget setting, and provider-aware transcoding.
- Parallelising one encode across isolates: a single encode is serial in pure Dart, and measured
  isolate spawn is 0.2–0.5 ms, so core count is not the lever — the codec is.
