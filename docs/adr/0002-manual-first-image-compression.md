# ADR-0002: Manual-first image compression with three exclusive modes

**Status:** Accepted (2026-09)
**Deciders:** cuplivo

## Context

Upstream Kelivo re-encodes images at attach time: a settings preset (quality + max long edge) is
resolved when an image is added, the original bytes are discarded, and the result is always a JPEG
named `.jpg`. Cuplivo 3.x instead shipped manual compression — a per-image dialog reached from the
file-size badge on the composer's image chips — with an alpha detector deciding whether a PNG could
be flattened.

The v4 line re-baselined on Kelivo v1.3.0, so the manual path was gone. Rebuilding it surfaced three
problems with the inherited automatic pipeline:

- **Format control is vendor-facing.** DeepSeek rejects files named `.jpg` and accepts only `jpeg`,
  and some providers reject WebP outright. The automatic pipeline emits `.jpg` unconditionally and
  offers no way to choose PNG.
- **Alpha detection guesses where the user can see.** The inherited `_pngNeedsOptIn` header scan (and
  Cuplivo 3.x's `hasRealAlpha` full-pixel decode) decide on the user's behalf whether transparency
  matters. The editor shows the actual image, so the format can simply be asked for.
- **Long-edge caps destroy long screenshots.** A 1080×8000 screenshot under the `balanced` preset
  (long edge 1568) becomes 211×1568 — unreadable. The cap is applied before the user ever sees the
  image.

## Decisions

1. **Three mutually exclusive compression modes** — `manual` (default), `auto`, `off`:
   - `auto`: Kelivo's attach-time pipeline, preset-driven, unchanged except that the artifact is named
     `.jpeg`. No editor.
   - `manual`: attachments are stored as pristine originals; the compress editor is the only
     compression surface. Tapping an image chip opens it.
   - `off`: pristine originals and no compression UI at all.
   Per-image attachment identity (the draft image id) is stable across a path change, so a compression
   never disturbs the draft's ordering or pending-paste bookkeeping.
2. **Manual is the default.** A fresh install keeps originals until the user asks for a different
   result; the motivation above (long screenshots, clarity-sensitive images) outweighs the
   bandwidth savings of automatic re-encoding, and `auto` remains one setting away.
3. **No alpha detection.** The editor offers JPEG / PNG / 原图 explicitly. JPEG flattens alpha onto
   white; PNG preserves it; 原图 re-encodes nothing. The inherited automatic pipeline keeps its own
   conservative transparency opt-in, because that is upstream behaviour and `auto` is not the default.
4. **WebP is never produced.** The user-facing format set is JPEG and PNG only.
5. **Artifacts are named `.jpeg`/`.png`, never `.jpg`.** MIME inference already maps both spellings to
   `image/jpeg`, but the extension itself reaches provider-facing surfaces, so the safe spelling wins.
6. **The preview is a 1:1 split compare.** The image is decoded once per editor session; the left of a
   draggable divider shows original pixels, the right shows the current parameters' result for the
   region on screen (re-encoded on a debounce), and a full-image size estimate follows the parameters.
   The preview and the artifact run the same pipeline, so what is compared is what is produced.
7. **Cropping is deferred, not rejected.** The pipeline is staged (decode → resize → encode) so a crop
   stage can be inserted later. The existing mobile-only `image_cropper` at pick time is untouched.
8. **`downsize` is extended, not replaced.** The vendored package gains a format parameter and a real
   PNG encode (`compressPng` previously emitted JPEG). Its orientation bake, EXIF strip and
   only-shrink resize are kept.

## Consequences

- `manual` and `off` both store byte-identical copies in the upload directory; they differ only in
  whether the editor is offered. `auto` keeps its presets, its minimum-size guard and its
  transparency opt-in.
- Manual compression is one-way: the editor re-encodes from the image's current stored bytes, so the
  pristine original is not recoverable after an apply. The chip badge shows the current size, which is
  what the user is choosing from.
- `ImageCompressionMode`, the manual parameters and the editor's vocabulary are now part of the domain
  language; `CONTEXT.md` documents them and an ADR is required to change the mode semantics.
- The automatic pipeline's artifact extension changes from `.jpg` to `.jpeg`. Files already on disk and
  paths recorded in existing conversations are untouched; nothing rewrites history.
- A PNG artifact of a photographic source can be larger than its input. This is a deliberate
  consequence of removing the automatic guards from the manual path; the size estimate is shown before
  the apply so the user can back out.

## Not in scope

- Cropping inside the editor (staged pipeline reserved for it).
- Send-layer, vendor-aware transcoding: if a provider rejects a format the user chose, the fix is the
  user's format choice, not a silent rewrite at send time.
- Editing images that have already been sent, and any undo back to a pristine original.
- Migrating settings from Kelivo installs; v4 installs side by side and starts fresh.
