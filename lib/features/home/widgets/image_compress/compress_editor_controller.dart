import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:ui' show Rect, Size;

import 'package:downsize/downsize.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../../../../utils/image_compressor.dart';

/// Total pixels of the decoded preview cache. Larger images are cached at a
/// reduced size so a phone photo never materialises a full-resolution RGBA
/// copy in both Dart and GPU memory. Artifacts are always produced from the
/// original bytes, never from this cache.
const int _kMaxDecodedPixels = 4 * 1000 * 1000;

/// Longest edge of the decoded preview cache. A pixel budget alone still
/// leaves a 12 MP photo at full resolution, and every comparison tick then
/// crops the whole thing, so both dimensions are bounded. 2048 px stays above
/// the largest realistic preview viewport (about 1290 device pixels on a
/// phone, about 1400 on desktop), so the 1:1 comparison stays honest at the
/// resolution it is actually displayed at.
const int _kMaxPreviewLongEdge = 2048;

/// The size [width]×[height] is cached at: shrunk until it fits both the
/// pixel budget and the long-edge cap, never enlarged.
({int width, int height}) previewCacheSize(int width, int height) {
  if (width <= 0 || height <= 0) return (width: width, height: height);
  final pixels = width * height;
  final longEdge = math.max(width, height);
  var factor = 1.0;
  if (longEdge > _kMaxPreviewLongEdge) {
    factor = _kMaxPreviewLongEdge / longEdge;
  }
  if (pixels * factor * factor > _kMaxDecodedPixels) {
    factor = math.min(factor, math.sqrt(_kMaxDecodedPixels / pixels));
  }
  if (factor >= 1) return (width: width, height: height);
  return (
    width: math.max(1, (width * factor).round()),
    height: math.max(1, (height * factor).round()),
  );
}

/// Longest edge of the comparison tile rendered on the compressed side of the
/// divider: large enough to stay honest at 1:1, small enough to re-encode
/// while a slider moves.
const int _kTileLongEdgeCap = 1280;

const Duration _kTileDebounce = Duration(milliseconds: 180);
const Duration _kEstimateDebounce = Duration(milliseconds: 600);

/// Smallest long edge the editor offers for an image whose longest side is
/// [originalLongEdge]: the 25% preset has to stay reachable, so the slider's
/// minimum follows the image down instead of sitting at a flat 256 px and
/// disagreeing with a preset it cannot represent.
int minEditorLongEdge(int originalLongEdge) {
  if (originalLongEdge <= 0) return 1;
  return math.min(256, math.max(1, (originalLongEdge / 4).round()));
}

/// Decoded preview pixels: RGBA bytes plus both the cache size and the true
/// source size.
typedef PreviewDecode = ({
  Uint8List rgba,
  int width,
  int height,
  int sourceWidth,
  int sourceHeight,
});

/// Decodes [bytes] for the editor preview: orientation baked into the pixels,
/// EXIF dropped, oversized images reduced to the preview budget. Runs in a
/// background isolate.
PreviewDecode decodeForPreview(Uint8List bytes) {
  final decoded = img.decodeImage(bytes, frame: 0);
  if (decoded == null) throw StateError('unsupported image');
  var image = img.bakeOrientation(decoded);
  image.exif.clear();
  final sourceWidth = image.width;
  final sourceHeight = image.height;
  final cache = previewCacheSize(sourceWidth, sourceHeight);
  if (cache.width != sourceWidth || cache.height != sourceHeight) {
    image = img.copyResize(
      image,
      width: cache.width,
      height: cache.height,
      interpolation: img.Interpolation.average,
    );
  }
  if (image.numChannels != 4) {
    image = image.convert(numChannels: 4);
  }
  return (
    rgba: image.getBytes(order: img.ChannelOrder.rgba),
    width: image.width,
    height: image.height,
    sourceWidth: sourceWidth,
    sourceHeight: sourceHeight,
  );
}

/// One comparison-tile encode, run in a background isolate. Produced through
/// the same [Downsize.compressDecoded] pipeline as the artifact, restricted to
/// the region currently on screen.
typedef TileEncode = ({
  img.Image image,
  DownsizeFormat format,
  int quality,
  int maxLongEdge,
});

Uint8List encodeTile(TileEncode task) {
  return Downsize().compressDecoded(
    task.image,
    Config(
      format: task.format,
      quality: task.quality,
      maxLongEdge: task.maxLongEdge,
    ),
  );
}

/// Drives the manual compress editor: one decode per session, a debounced
/// 1:1 comparison tile for the region on screen, and a debounced full-image
/// size estimate.
class CompressEditorController extends ChangeNotifier {
  CompressEditorController({
    required this.imagePath,
    required ManualCompressParams initialParams,
  }) : _params = initialParams;

  final String imagePath;

  ManualCompressParams _params;
  ManualCompressParams get params => _params;

  Uint8List? _sourceBytes;
  img.Image? _decoded;
  ui.Image? _original;
  ui.Image? _tile;
  Rect? _tileSource;

  bool _preparing = true;
  bool _decodeFailed = false;
  bool _tileBusy = false;

  int? _estimatedBytes;
  bool _estimating = false;
  bool _estimateFailed = false;

  int _sourceWidth = 0;
  int _sourceHeight = 0;

  Rect _visible = Rect.zero;
  Size _viewport = Size.zero;
  double _divider = 0.5;

  Timer? _tileTimer;
  Timer? _estimateTimer;
  int _tileGeneration = 0;
  bool _disposed = false;

  bool get preparing => _preparing;
  bool get decodeFailed => _decodeFailed;
  bool get tileBusy => _tileBusy;
  ui.Image? get original => _original;
  ui.Image? get tile => _tile;
  Rect? get tileSource => _tileSource;
  double get divider => _divider;
  int? get estimatedBytes => _estimatedBytes;
  bool get estimating => _estimating;
  bool get estimateFailed => _estimateFailed;
  int? get sourceBytes => _sourceBytes?.lengthInBytes;
  int get sourceWidth => _sourceWidth;
  int get sourceHeight => _sourceHeight;
  int get sourceLongEdge => math.max(_sourceWidth, _sourceHeight);

  /// Preview-cache dimensions, which are also the coordinate space of
  /// [visibleSource]. They equal the source dimensions unless the image
  /// exceeded the preview budget.
  int get previewWidth => _decoded?.width ?? 0;
  int get previewHeight => _decoded?.height ?? 0;

  /// The region of the preview cache currently mapped onto the viewport.
  Rect get visibleSource => _visible;

  @override
  void dispose() {
    _disposed = true;
    _tileTimer?.cancel();
    _estimateTimer?.cancel();
    _original?.dispose();
    _tile?.dispose();
    super.dispose();
  }

  Future<void> prepare() async {
    try {
      final bytes = await File(imagePath).readAsBytes();
      final outcome = await compute(decodeForPreview, bytes);
      if (_disposed) return;
      final decoded = img.Image.fromBytes(
        width: outcome.width,
        height: outcome.height,
        bytes: outcome.rgba.buffer,
        numChannels: 4,
        order: img.ChannelOrder.rgba,
      );
      final display = await _uiImageFromRgba(
        outcome.rgba,
        outcome.width,
        outcome.height,
      );
      if (_disposed) {
        display.dispose();
        return;
      }
      _sourceBytes = bytes;
      _decoded = decoded;
      _sourceWidth = outcome.sourceWidth;
      _sourceHeight = outcome.sourceHeight;
      _original = display;
      _params = _normalizedParams(outcome.sourceWidth, outcome.sourceHeight);
      _preparing = false;
      notifyListeners();
      _scheduleEstimate();
    } catch (error, stackTrace) {
      debugPrint('[CompressEditor] Decode failed for $imagePath: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (_disposed) return;
      _preparing = false;
      _decodeFailed = true;
      notifyListeners();
    }
  }

  void setParams(ManualCompressParams value) {
    if (value == _params) return;
    _params = value;
    // The tile encodes the previous parameters: showing it next to the new
    // ones would present a stale result as the current one.
    _invalidateTile();
    notifyListeners();
    _scheduleTile();
    _scheduleEstimate();
  }

  /// The remembered long edge can come from a different image and therefore
  /// sit outside this image's slider range. Clamping keeps the readout and the
  /// applied value identical; a cap above the source only ever means "do not
  /// downscale", so clamping it down never changes the result.
  ManualCompressParams _normalizedParams(int sourceWidth, int sourceHeight) {
    final longEdge = _params.maxLongEdge;
    if (longEdge == null) return _params;
    final source = math.max(sourceWidth, sourceHeight);
    final clamped = longEdge.clamp(minEditorLongEdge(source), source);
    if (clamped == longEdge) return _params;
    return ManualCompressParams(
      format: _params.format,
      quality: _params.quality,
      maxLongEdge: clamped,
    );
  }

  void _invalidateTile() {
    if (_tile == null && _tileSource == null) return;
    _tile?.dispose();
    _tile = null;
    _tileSource = null;
  }

  /// Called by the preview whenever its layout or transform changes.
  void updateViewport({required Rect visible, required Size viewport}) {
    final changed = visible != _visible || viewport != _viewport;
    _visible = visible;
    _viewport = viewport;
    if (changed) _scheduleTile();
  }

  void setDivider(double value) {
    final next = value.clamp(0.0, 1.0);
    if ((next - _divider).abs() < 0.0005) return;
    _divider = next;
    notifyListeners();
  }

  void _scheduleTile() {
    _tileTimer?.cancel();
    _tileTimer = Timer(_kTileDebounce, () => unawaited(_computeTile()));
  }

  Future<void> _computeTile() async {
    final decoded = _decoded;
    final format = _params.format;
    if (decoded == null) return;
    if (format == null) {
      final hadTile = _tile != null || _tileSource != null;
      _invalidateTile();
      if (hadTile) notifyListeners();
      return;
    }
    final source = _clampedVisible(decoded);
    if (source == null) return;

    final generation = ++_tileGeneration;
    final fullLongEdge = math.max(decoded.width, decoded.height);
    final paramScale = _params.maxLongEdge == null
        ? 1.0
        : math.min(1.0, _params.maxLongEdge! / fullLongEdge);
    final artifactLongEdge = math.max(source.width, source.height) * paramScale;
    final renderScale = math.min(1.0, _kTileLongEdgeCap / artifactLongEdge);
    final targetLongEdge = math.max(
      1,
      (artifactLongEdge * renderScale).round(),
    );

    _tileBusy = true;
    notifyListeners();
    try {
      final tileImage = img.copyCrop(
        decoded,
        x: source.left.floor(),
        y: source.top.floor(),
        width: math.max(1, source.width.round()),
        height: math.max(1, source.height.round()),
      );
      final encoded = await compute(encodeTile, (
        image: tileImage,
        format: format,
        quality: _params.quality,
        maxLongEdge: targetLongEdge,
      ));
      if (_disposed || generation != _tileGeneration) return;
      final image = await _decodeUiImage(encoded);
      if (_disposed || generation != _tileGeneration) {
        image.dispose();
        return;
      }
      _tile?.dispose();
      _tile = image;
      _tileSource = source;
      _tileBusy = false;
      notifyListeners();
    } catch (error) {
      debugPrint('[CompressEditor] Preview tile failed: $error');
      if (_disposed || generation != _tileGeneration) return;
      _tileBusy = false;
      notifyListeners();
    }
  }

  Rect? _clampedVisible(img.Image decoded) {
    final visible = _visible;
    if (visible.isEmpty || _viewport.isEmpty) return null;
    final imageRect = Rect.fromLTWH(
      0,
      0,
      decoded.width.toDouble(),
      decoded.height.toDouble(),
    );
    final clamped = visible.intersect(imageRect);
    if (clamped.width < 1 || clamped.height < 1) return null;
    return clamped;
  }

  void _scheduleEstimate() {
    _estimateTimer?.cancel();
    _estimateTimer = Timer(_kEstimateDebounce, () => unawaited(_estimate()));
  }

  Future<void> _estimate() async {
    final bytes = _sourceBytes;
    if (bytes == null) return;
    final params = _params;
    if (params.isNoOp) {
      _estimatedBytes = bytes.lengthInBytes;
      _estimating = false;
      _estimateFailed = false;
      notifyListeners();
      return;
    }
    _estimating = true;
    _estimateFailed = false;
    notifyListeners();
    try {
      final encoded = await ImageCompressor.encodeManualBytes(bytes, params);
      if (_disposed || params != _params) return;
      _estimatedBytes = encoded?.lengthInBytes ?? bytes.lengthInBytes;
      _estimating = false;
      notifyListeners();
    } catch (error) {
      debugPrint('[CompressEditor] Size estimate failed: $error');
      if (_disposed || params != _params) return;
      _estimating = false;
      _estimateFailed = true;
      notifyListeners();
    }
  }

  Future<ui.Image> _decodeUiImage(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    try {
      final frame = await codec.getNextFrame();
      return frame.image;
    } finally {
      codec.dispose();
    }
  }

  /// Builds the preview texture from raw pixels. The descriptor API reports
  /// a rejected buffer as an error, where `decodeImageFromPixels` would leave
  /// its callback pending and the editor spinning forever.
  static Future<ui.Image> _uiImageFromRgba(
    Uint8List rgba,
    int width,
    int height,
  ) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(rgba);
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    try {
      descriptor = ui.ImageDescriptor.raw(
        buffer,
        width: width,
        height: height,
        pixelFormat: ui.PixelFormat.rgba8888,
      );
      codec = await descriptor.instantiateCodec();
      final frame = await codec.getNextFrame();
      return frame.image;
    } finally {
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
  }
}
