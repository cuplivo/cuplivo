import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:ui' show Rect, Size;

import 'package:downsize/downsize.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../../../../utils/image_compressor.dart';

/// Longest edge of the decoded preview cache. Larger images are cached at a
/// reduced size so a phone photo never materialises a full-resolution RGBA
/// copy in both Dart and GPU memory. Artifacts are always produced from the
/// original bytes, never from this cache.
const int _kMaxDecodedPixels = 16 * 1000 * 1000;

/// Longest edge of the comparison tile rendered on the compressed side of the
/// divider: large enough to stay honest at 1:1, small enough to re-encode
/// while a slider moves.
const int _kTileLongEdgeCap = 1280;

const Duration _kTileDebounce = Duration(milliseconds: 180);
const Duration _kEstimateDebounce = Duration(milliseconds: 600);

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
  final pixels = sourceWidth * sourceHeight;
  if (pixels > _kMaxDecodedPixels) {
    final factor = math.sqrt(_kMaxDecodedPixels / pixels);
    image = img.copyResize(
      image,
      width: math.max(1, (image.width * factor).round()),
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
    notifyListeners();
    _scheduleTile();
    _scheduleEstimate();
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
    if (decoded == null || format == null) return;
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

  Future<ui.Image> _decodeUiImage(Uint8List bytes) {
    final completer = Completer<ui.Image>();
    ui.instantiateImageCodec(bytes).then((codec) {
      codec.getNextFrame().then((frame) {
        completer.complete(frame.image);
        codec.dispose();
      }, onError: completer.completeError);
    }, onError: completer.completeError);
    return completer.future;
  }

  static Future<ui.Image> _uiImageFromRgba(
    Uint8List rgba,
    int width,
    int height,
  ) {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      rgba,
      width,
      height,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }
}
