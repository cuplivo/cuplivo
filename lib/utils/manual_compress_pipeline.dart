import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:downsize/downsize.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// Parameters of one explicit, user-chosen compression in the manual editor.
///
/// A null [format] means 原图 (as-is): the stored bytes pass through
/// untouched. Unlike the automatic pipeline there are no skip guards — no
/// minimum size, no alpha gate, and the result may be larger than the input
/// (a PNG of a JPEG photo legitimately grows); the editor shows the result's
/// exact size before anything is applied.
class ManualCompressParams {
  const ManualCompressParams({
    this.format,
    this.quality = 80,
    this.maxLongEdge,
  });

  final DownsizeFormat? format;
  final int quality;
  final int? maxLongEdge;

  bool get isNoOp => format == null;

  @override
  bool operator ==(Object other) =>
      other is ManualCompressParams &&
      other.format == format &&
      other.quality == quality &&
      other.maxLongEdge == maxLongEdge;

  @override
  int get hashCode => Object.hash(format, quality, maxLongEdge);
}

enum ImageSourceFormat { jpeg, png, gif, other }

/// The container [bytes] actually hold, from their magic bytes. The decode
/// budget keys on this: the engine sub-scales JPEG at decode but decodes PNG
/// whole, whatever the output format will be.
ImageSourceFormat detectImageSourceFormat(Uint8List bytes) {
  if (bytes.lengthInBytes >= 3 &&
      bytes[0] == 0xff &&
      bytes[1] == 0xd8 &&
      bytes[2] == 0xff) {
    return ImageSourceFormat.jpeg;
  }
  if (bytes.lengthInBytes >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4e &&
      bytes[3] == 0x47 &&
      bytes[4] == 0x0d &&
      bytes[5] == 0x0a &&
      bytes[6] == 0x1a &&
      bytes[7] == 0x0a) {
    return ImageSourceFormat.png;
  }
  if (bytes.lengthInBytes >= 6 &&
      bytes[0] == 0x47 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x38 &&
      (bytes[4] == 0x37 || bytes[4] == 0x39) &&
      bytes[5] == 0x61) {
    return ImageSourceFormat.gif;
  }
  return ImageSourceFormat.other;
}

/// Budgets and the decode driver behind the manual compress editor.
///
/// The editor never materialises the source at full resolution. It decodes one
/// *working image* — the pixels the artifact will be encoded from — at the size
/// the user asked for, so peak memory tracks the chosen output, not the source.
/// A 200 MP photo whose target is a 1568 px long edge therefore costs the same
/// as a 1568 px image, while the previous pipeline (`Downsize.compress` on the
/// file bytes) full-decoded first and scaled afterwards.
///
/// Measured on a desktop build (`test/perf/manual_compress_bench.dart`), per
/// target pixel of the working image: ~11–12 bytes for a JPEG source (engine
/// texture + straight RGBA + the encoder's own copies). The [decodePeakBytes]
/// gate below adds the source-proportional term the engine charges when a codec
/// cannot sub-scale at decode — PNG does not, measured at +57 MB for a 13 MP
/// source against +13 MB for the same-sized JPEG.

/// Working-image pixel budget for one task: the largest artifact the editor
/// will offer. Sized so a 13 MP attachment (the largest everyday case) keeps its
/// full resolution at 100%, while a much larger source is still openable, just
/// with a reduced reachable long edge.
const int kWorkingPixelsMobile = 14 * 1000 * 1000;
const int kWorkingPixelsDesktop = 20 * 1000 * 1000;

/// Ceiling for what a single decode may allocate. Above it the editor refuses to
/// re-compress the image instead of risking a process abort: an out-of-memory
/// kill inside an isolate is not catchable from Dart.
///
/// Calibrated against `test/perf/manual_compress_bench.dart`:
///
/// | source | target | decode peak | status quo |
/// |---|---|---|---|
/// | 13 MP JPEG | 1568 | +13 MB | +157 MB |
/// | 50 MP JPEG | 1568 | +19 MB | +679 MB |
/// | 200 MP JPEG | 1568 | +19 MB | ~3 GB |
/// | 8.6 MP PNG (long screenshot) | 1568 | +32 MB | +86 MB |
/// | 13 MP PNG | 1568 | +57 MB | +134 MB |
/// | 50 MP PNG | 1568 | +198 MB | +290 MB |
/// | 200 MP PNG | 1568 | +768 MB | ~3 GB |
///
/// So the mobile budget admits every JPEG at any reachable target (the decode is
/// target-bounded, and the target is already bounded by [workingPixelBudget]),
/// and PNG up to roughly 70 MP — while refusing the 200 MP PNG that would
/// otherwise allocate 768 MB. The desktop budget is deliberately kept under half
/// of the ~800 MB working set the app is willing to spend, because two tasks can
/// run concurrently. The engine's decode is not cancelled when parameters change,
/// so a single in-flight encode is an invariant of the editor, not an
/// optimisation.
const int kDecodeBudgetBytesMobile = 300 * 1024 * 1024;
const int kDecodeBudgetBytesDesktop = 500 * 1024 * 1024;

bool get isDesktopPlatform =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux);

int workingPixelBudget({required bool desktop}) =>
    desktop ? kWorkingPixelsDesktop : kWorkingPixelsMobile;

int decodeByteBudget({required bool desktop}) =>
    desktop ? kDecodeBudgetBytesDesktop : kDecodeBudgetBytesMobile;

/// Smallest long edge the editor offers: the 25% preset has to stay reachable,
/// so the slider's minimum follows the image down instead of sitting at a flat
/// 256 px and disagreeing with a preset it cannot represent.
int minEditorLongEdge(int originalLongEdge) {
  if (originalLongEdge <= 0) return 1;
  return math.min(256, math.max(1, (originalLongEdge / 4).round()));
}

/// The largest long edge a [width]×[height] source can be worked at inside
/// [budgetPixels], preserving the aspect ratio and never upscaling.
int workingLongEdge(int width, int height, int budgetPixels) {
  final size = workingSize(width, height, budgetPixels);
  return math.max(size.width, size.height);
}

/// [width]×[height] fitted into [budgetPixels], aspect preserved, never
/// enlarged. The result's pixel count is never above [budgetPixels]: both sides
/// are floored, so independent rounding cannot push the budget back over.
({int width, int height}) workingSize(int width, int height, int budgetPixels) {
  if (width <= 0 || height <= 0) return (width: width, height: height);
  final pixels = width * height;
  if (pixels <= budgetPixels || budgetPixels <= 0) {
    return (width: width, height: height);
  }
  final factor = math.sqrt(budgetPixels / pixels);
  return (
    width: math.max(1, (width * factor).floor()),
    height: math.max(1, (height * factor).floor()),
  );
}

/// The long edge an artifact is actually produced at, given the user's choice
/// and what the working image can reach. A remembered value from another image
/// is normalised here so the panel's readout always equals what is applied.
///
/// The editor's view of [resolveWorkingEdge]: same math, with the 25% floor.
int targetLongEdge({
  required int sourceWidth,
  required int sourceHeight,
  required int? requestedLongEdge,
  required int budgetPixels,
}) {
  return resolveWorkingEdge(
    sourceWidth: sourceWidth,
    sourceHeight: sourceHeight,
    requestedLongEdge: requestedLongEdge,
    budgetPixels: budgetPixels,
    floorAtQuarterOfSource: true,
  );
}

/// The long edge a decode will actually use: the requested value (or the
/// source's own edge) clamped into the range the source and the working budget
/// leave open.
///
/// One implementation for the decoder, the panel's slider maximum and the
/// controller's normalisation, so the resolution the panel shows cannot drift
/// from the resolution the artifact is produced at. [floorAtQuarterOfSource] is
/// the editor's 25% floor; a preset passes false, because a preset is an exact
/// cap rather than a floor.
int resolveWorkingEdge({
  required int sourceWidth,
  required int sourceHeight,
  required int? requestedLongEdge,
  required int budgetPixels,
  required bool floorAtQuarterOfSource,
}) {
  final source = math.max(sourceWidth, sourceHeight);
  if (source <= 0) return 0;
  final reachable = math.min(
    source,
    workingLongEdge(sourceWidth, sourceHeight, budgetPixels),
  );
  final floor = floorAtQuarterOfSource ? minEditorLongEdge(source) : 1;
  // The floor can exceed what the budget reaches on a tightly-budgeted source;
  // clamping with a lower bound above the upper one throws, so the bounds are
  // ordered here rather than assumed.
  return (requestedLongEdge ?? source)
      .clamp(math.min(floor, reachable), reachable)
      .toInt();
}

/// What a decode of [sourcePixels] into [targetPixels] allocates, split into the
/// part the gate is about and the part it is not.
///
/// [rasterBytes] is the raster the decode itself allocates: the bitmap the engine
/// decodes — bounded by `4 * targetPixels` when the codec sub-scales at decode,
/// the whole source when it does not — plus the target bitmap. This is the
/// allocation that can abort the process, so [decodeByteBudget] bounds it.
///
/// [fileBytesHeld] is the source file, held twice while the descriptor is alive
/// (the `Uint8List` read from disk and the `ImmutableBuffer` the descriptor
/// owns). It is bounded separately and generously: gating it with the raster
/// refused sources that decode cheaply — a 200 MP JPEG with a 30 MB file needs
/// 280 MB of raster, well inside the budget, and was refused before this split
/// only because its file size was added to that number.
///
/// The engine decodes at a codec-supported scale when the codec offers one
/// (`ImageDecoderSkia::ImageFromCompressedData` allocates
/// `get_scaled_dimensions(...)` only when it differs from the source) and
/// otherwise decodes the full image and scales it afterwards. JPEG is in the
/// first group, PNG in the second.
({int rasterBytes, int fileBytesHeld}) decodePeakBytes({
  required bool sourceCanSubScale,
  required int sourcePixels,
  required int targetPixels,
  required int fileBytes,
}) {
  final decodedPixels = sourceCanSubScale
      ? math.min(sourcePixels, 4 * targetPixels)
      : sourcePixels;
  return (
    rasterBytes: (decodedPixels + targetPixels) * 4,
    fileBytesHeld: 2 * fileBytes,
  );
}

/// Raised when re-compressing this image would exceed the decode budget.
///
/// It carries the facts the header already provided, because the panel needs the
/// source's size to offer a working resolution that would fit: a refusal is not a
/// reason to hide dimensions that were known before any pixel was touched.
class WorkingImageTooLargeException implements Exception {
  const WorkingImageTooLargeException({
    required this.sourceWidth,
    required this.sourceHeight,
    required this.sourceBytes,
    required this.requiredBytes,
    required this.budgetBytes,
  });

  final int sourceWidth;
  final int sourceHeight;
  final int sourceBytes;

  /// The number that violated [budgetBytes].
  final int requiredBytes;
  final int budgetBytes;

  @override
  String toString() =>
      '$sourceWidth×$sourceHeight would need $requiredBytes bytes to decode, '
      'budget $budgetBytes';
}

/// The decoded working image: the preview texture plus the straight RGBA bytes
/// the artifact is encoded from.
///
/// These are the *same* pixels on purpose — the right half of the comparison
/// draws the artifact produced from [rgba], so what is compared is what is
/// written, and 1:1 means one artifact pixel per logical pixel.
class WorkingImage {
  WorkingImage({
    required this.display,
    required this.rgba,
    required this.width,
    required this.height,
    required this.sourceWidth,
    required this.sourceHeight,
    required this.sourceBytes,
    required this.sourceMayHaveAlpha,
  });

  /// The preview texture for the original side, at the working resolution.
  final ui.Image display;

  /// Straight (un-premultiplied) RGBA pixels of the working image. Transferable
  /// to the encode isolate without an intermediate `img.Image` copy.
  final Uint8List rgba;

  final int width;
  final int height;
  final int sourceWidth;
  final int sourceHeight;
  final int sourceBytes;

  /// Whether the source format can carry transparency; a JPEG source cannot,
  /// which lets the JPEG encoder skip flattening entirely.
  final bool sourceMayHaveAlpha;

  int get sourceLongEdge => math.max(sourceWidth, sourceHeight);
  int get longEdge => math.max(width, height);

  void dispose() => display.dispose();
}

/// Decodes the working image for [path] at exactly the size the artifact will
/// have: header-first (dimensions come from the container, EXIF-corrected, with
/// no pixel work), then one engine decode at the target size.
///
/// Throws [WorkingImageTooLargeException] when the source cannot be decoded
/// inside [decodeBudgetBytes], and [WorkingImageTooLargeException] is the only
/// expected rejection; an undecodable image surfaces as a decode error.
Future<WorkingImage> decodeWorkingImage(
  String path, {
  required ManualCompressParams params,
  required int budgetPixels,
  required int budgetBytes,
}) {
  return decodeWorkingImageBytes(
    File(path).readAsBytesSync(),
    // 原图 is display-only, so it is always worked at the reachable size.
    requestedLongEdge: params.isNoOp ? null : params.maxLongEdge,
    // The editor floors the long edge at its 25% preset, so the slider's own
    // minimum always represents something it can produce.
    floorAtQuarterOfSource: true,
    budgetPixels: budgetPixels,
    budgetBytes: budgetBytes,
  );
}

/// The same decode for callers that already hold the source bytes: the automatic
/// pipeline reads them for its size and transparency guards, and must not make
/// the engine hold a second copy.
///
/// [requestedLongEdge] is the wanted longest side, or null for the source's own
/// edge; either way the working budget caps it. [floorAtQuarterOfSource] is the
/// editor's 25% floor and stays off for a preset, whose value is an exact cap
/// rather than a floor.
Future<WorkingImage> decodeWorkingImageBytes(
  Uint8List bytes, {
  required int? requestedLongEdge,
  required bool floorAtQuarterOfSource,
  required int budgetPixels,
  required int budgetBytes,
}) async {
  final sourceFormat = detectImageSourceFormat(bytes);
  final decoded = await _decodeAtEdge(
    bytes,
    requestedLongEdge: requestedLongEdge,
    floorAtQuarterOfSource: floorAtQuarterOfSource,
    budgetPixels: budgetPixels,
    budgetBytes: budgetBytes,
    includePixels: true,
  );
  final display = decoded.image;
  try {
    final raw = decoded.rgba;
    if (raw == null) throw StateError('image has no readable pixels');
    return WorkingImage(
      display: display,
      rgba: raw,
      width: display.width,
      height: display.height,
      sourceWidth: decoded.sourceWidth,
      sourceHeight: decoded.sourceHeight,
      sourceBytes: bytes.length,
      sourceMayHaveAlpha: sourceFormat != ImageSourceFormat.jpeg,
    );
  } catch (_) {
    display.dispose();
    rethrow;
  }
}

/// Decodes the reference image: the source at the largest long edge the working
/// budget reaches, for the comparison's left half.
///
/// The artifact is encoded from the working image at the size the user chose, so
/// this side is what that choice is measured against — the untouched 原图, not a
/// re-decode at the target resolution, which is what would blur both halves
/// together as the resolution is lowered.
///
/// It is display-only: nothing is ever encoded from these pixels, so the straight
/// RGBA copy the encode path needs is not read back, and the reference costs its
/// texture and nothing else. It is decoded once per session.
Future<ui.Image> decodeReferenceImage(
  String path, {
  required int budgetPixels,
  required int budgetBytes,
}) async {
  final decoded = await _decodeAtEdge(
    File(path).readAsBytesSync(),
    requestedLongEdge: null,
    floorAtQuarterOfSource: true,
    budgetPixels: budgetPixels,
    budgetBytes: budgetBytes,
    includePixels: false,
  );
  return decoded.image;
}

/// One engine decode of [bytes] at the edge the source and the budget leave
/// open, plus the facts the header supplied.
///
/// [includePixels] reads the straight RGBA copy back as well; only the encode
/// path needs it — the reference image is display-only, and skipping the readback
/// keeps a full-resolution pixel copy off the peak.
Future<({ui.Image image, Uint8List? rgba, int sourceWidth, int sourceHeight})>
_decodeAtEdge(
  Uint8List bytes, {
  required int? requestedLongEdge,
  required bool floorAtQuarterOfSource,
  required int budgetPixels,
  required int budgetBytes,
  required bool includePixels,
}) async {
  final sourceFormat = detectImageSourceFormat(bytes);

  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    // Width and height are EXIF-corrected by the engine, so a rotated JPEG
    // needs no orientation arithmetic here.
    final sourceWidth = descriptor.width;
    final sourceHeight = descriptor.height;
    if (sourceWidth <= 0 || sourceHeight <= 0) {
      throw StateError('image reports an empty size');
    }

    final edge = resolveWorkingEdge(
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
      requestedLongEdge: requestedLongEdge,
      budgetPixels: budgetPixels,
      floorAtQuarterOfSource: floorAtQuarterOfSource,
    );
    final target = _scaleToLongEdge(sourceWidth, sourceHeight, edge);

    final peak = decodePeakBytes(
      sourceCanSubScale: sourceFormat == ImageSourceFormat.jpeg,
      sourcePixels: sourceWidth * sourceHeight,
      targetPixels: target.width * target.height,
      fileBytes: bytes.length,
    );
    // Two judgements, because they are two different risks. The raster is what
    // can abort the process, so it is measured against the whole budget. The file
    // is held twice and is unavoidable on any path, so it gets a generous ceiling
    // of its own: it may not consume the budget the raster still needs, but it no
    // longer refuses a source whose decode is cheap.
    final rasterRefused = peak.rasterBytes > budgetBytes;
    final fileRefused = peak.fileBytesHeld > budgetBytes ~/ 2;
    if (rasterRefused || fileRefused) {
      throw WorkingImageTooLargeException(
        sourceWidth: sourceWidth,
        sourceHeight: sourceHeight,
        sourceBytes: bytes.length,
        requiredBytes: rasterRefused ? peak.rasterBytes : peak.fileBytesHeld,
        budgetBytes: rasterRefused ? budgetBytes : budgetBytes ~/ 2,
      );
    }

    codec = await descriptor.instantiateCodec(
      targetWidth: target.width,
      targetHeight: target.height,
    );
    final frame = await codec.getNextFrame();
    final display = frame.image;
    try {
      Uint8List? rgba;
      if (includePixels) {
        final raw = await display.toByteData(
          format: ui.ImageByteFormat.rawStraightRgba,
        );
        if (raw == null) throw StateError('image has no readable pixels');
        // `ByteData.buffer` is the whole underlying buffer and `asUint8List()`
        // would start at 0, ignoring the offset; today the engine hands back
        // `encoded.buffer.asByteData()` (offset 0, exactly the image), so the
        // contract is stated and asserted rather than assumed — a shifted window
        // or a pooling buffer would otherwise produce wrong pixels silently.
        final expected = display.width * display.height * 4;
        if (raw.lengthInBytes != expected) {
          throw StateError(
            'decoded pixels are ${raw.lengthInBytes} bytes, expected $expected '
            'for ${display.width}x${display.height}',
          );
        }
        rgba = raw.buffer.asUint8List(raw.offsetInBytes, raw.lengthInBytes);
      }
      return (
        image: display,
        rgba: rgba,
        sourceWidth: sourceWidth,
        sourceHeight: sourceHeight,
      );
    } catch (_) {
      display.dispose();
      rethrow;
    }
  } finally {
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
}

({int width, int height}) _scaleToLongEdge(int width, int height, int edge) {
  final source = math.max(width, height);
  if (source <= 0 || edge <= 0 || edge >= source) {
    return (width: width, height: height);
  }
  final factor = edge / source;
  return (
    width: math.max(1, (width * factor).round()),
    height: math.max(1, (height * factor).round()),
  );
}

/// Encodes the artifact from the working pixels in a background isolate.
///
/// [WorkingImage.rgba] crosses the isolate boundary as a [TransferableTypedData]
/// (a move, not a copy) and is turned back into an image only on the far side.
/// No resize happens here: the engine already decoded at the artifact's size, so
/// the artifact costs exactly one resample (in the codec, for a JPEG source).
Future<Uint8List> encodeArtifact(
  WorkingImage working,
  ManualCompressParams params,
) {
  assert(!params.isNoOp, '原图 has no artifact to encode');
  return compute(
    _encodeArtifactTask,
    _EncodeArtifactTask(
      rgba: TransferableTypedData.fromList([working.rgba]),
      width: working.width,
      height: working.height,
      format: params.format!,
      quality: params.quality,
      // The working pixels came from the engine with straight alpha, so a JPEG
      // artifact still has to be flattened onto white — downsize does exactly
      // that, and skipping the flatten for an opaque source saves a full-size
      // composite.
      flattenAlpha:
          params.format == DownsizeFormat.jpeg && working.sourceMayHaveAlpha,
    ),
  );
}

class _EncodeArtifactTask {
  const _EncodeArtifactTask({
    required this.rgba,
    required this.width,
    required this.height,
    required this.format,
    required this.quality,
    required this.flattenAlpha,
  });

  final TransferableTypedData rgba;
  final int width;
  final int height;
  final DownsizeFormat format;
  final int quality;
  final bool flattenAlpha;
}

Uint8List _encodeArtifactTask(_EncodeArtifactTask task) {
  var image = img.Image.fromBytes(
    width: task.width,
    height: task.height,
    bytes: task.rgba.materialize().asUint8List().buffer,
    numChannels: 4,
    order: img.ChannelOrder.rgba,
  );
  final config = Config(format: task.format, quality: task.quality);
  if (task.format == DownsizeFormat.png) {
    return Downsize().compressPng(image: image, config: config);
  }
  if (task.flattenAlpha) {
    final background = img.Image(
      width: image.width,
      height: image.height,
      numChannels: 3,
    )..clear(img.ColorRgb8(255, 255, 255));
    image = img.compositeImage(background, image);
  }
  // Orientation is already baked and EXIF is gone (the engine supplied these
  // pixels), so downsize's own pre-treatment would only copy them again.
  return Downsize().compressJpg(
    image: image,
    config: config,
    preTreatment: false,
  );
}
