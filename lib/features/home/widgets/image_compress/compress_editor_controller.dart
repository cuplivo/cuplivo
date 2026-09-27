import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import '../../../../utils/manual_compress_pipeline.dart';

/// How long a parameter change waits before the editor decodes and encodes
/// again. Both stages of the pipeline are debounced together, so dragging a
/// slider costs one decode and one encode instead of one per frame.
const Duration _kEncodeDebounce = Duration(milliseconds: 200);

/// Drives the manual compress editor.
///
/// One working image per (source, target size) pair, one reference image for the
/// comparison's original side, one artifact per parameter set, and never more
/// than one decode/encode in flight: the engine's decode cannot be cancelled once
/// started, so starting a second one while the first runs is what would double
/// the peak, not the budget.
///
/// The artifact is not an estimate. It is the exact byte sequence the apply
/// writes and the right half of the comparison draws, so the size row, the
/// preview and the stored file are one value.
class CompressEditorController extends ChangeNotifier {
  CompressEditorController({
    required this.imagePath,
    required ManualCompressParams initialParams,
    bool? desktop,
    int? budgetPixels,
    int? budgetBytes,
  }) : _params = initialParams,
       _desktop = desktop ?? isDesktopPlatform,
       _budgetPixelsOverride = budgetPixels,
       _budgetBytesOverride = budgetBytes;

  final String imagePath;
  final bool _desktop;
  final int? _budgetPixelsOverride;
  final int? _budgetBytesOverride;

  /// Number of decode+encode passes started, and the most that were ever in
  /// flight at once. A pass cannot be cancelled once the engine has begun
  /// decoding, so more than one in flight is the doubling this design exists to
  /// prevent — asserted by the editor tests.
  @visibleForTesting
  int debugPassesStarted = 0;
  @visibleForTesting
  int debugMaxConcurrentPasses = 0;
  int _passesInFlight = 0;

  ManualCompressParams _params;
  ManualCompressParams get params => _params;

  WorkingImage? _working;

  /// What the header said about the source when its decode was refused. The gate
  /// must not hide dimensions that were known before any pixel was touched: the
  /// panel needs them to offer a working resolution that would fit, and to say
  /// which image it is refusing.
  ({int width, int height, int bytes})? _refusedSource;

  /// The long edge [_working] was decoded at, so a parameter change that does
  /// not move the target can reuse the pixels.
  int _workingEdge = 0;

  Uint8List? _artifact;
  ManualCompressParams? _artifactParams;
  ui.Image? _result;

  /// The left half's image: the source at the largest resolution the working
  /// budget reaches, decoded once and kept for the session.
  ///
  /// Without it the left half would draw [_working], which is decoded at the
  /// target the user picked: lowering the resolution would then blur 原图 along
  /// with the result, and the two halves would converge on the encode's own
  /// artifacts — hiding the loss the slider is actually causing behind a label
  /// that promises the original.
  ///
  /// It stays null while the working image already *is* the source at its
  /// largest reachable resolution: at that target the two hold the same pixels,
  /// and a second decode would only cost memory.
  ui.Image? _reference;
  bool _referenceInFlight = false;
  bool _referenceFailed = false;

  bool _preparing = true;
  bool _decodeFailed = false;
  bool _tooLarge = false;
  bool _busy = false;
  bool _pending = false;
  bool _disposed = false;

  Rect _visible = Rect.zero;
  double _divider = 0.5;
  Timer? _timer;

  /// Working images the preview may still be painting.
  ///
  /// A painter built before a swap keeps drawing the image it captured until
  /// the rebuild that publishes the replacement lands, and an animation
  /// repaints that painter without rebuilding it. Disposing at the swap
  /// therefore hands the engine a disposed image — it asserts on it — for as
  /// long as the pass that follows takes (a whole encode, seconds in a debug
  /// build). A replaced working image is retired instead, and released once
  /// the frame that publishes its replacement has been painted.
  final List<WorkingImage> _retired = [];

  void _retire(WorkingImage image) => _retired.add(image);

  /// Releases retired images at the end of the frame their replacement is
  /// built and painted in: after that frame no painter can still hold one.
  void _flushRetired() {
    if (_retired.isEmpty) return;
    final retired = List<WorkingImage>.of(_retired);
    _retired.clear();
    SchedulerBinding.instance.addPostFrameCallback((_) {
      for (final image in retired) {
        image.dispose();
      }
    });
  }

  /// Releases retired images immediately: only safe once no frame can paint
  /// them again, which is what tearing the preview down means.
  void _disposeRetired() {
    for (final image in _retired) {
      image.dispose();
    }
    _retired.clear();
  }

  bool get preparing => _preparing;

  /// The bytes cannot be decoded at all: nothing can be re-compressed.
  bool get decodeFailed => _decodeFailed;

  /// The decode would exceed the working budget. Distinct from [decodeFailed]
  /// because the reason, and what the user can do about it, is different.
  bool get tooLarge => _tooLarge;

  /// A decode or encode pass is running.
  bool get encoding => _busy;

  /// The original side: the reference once it has been decoded, and the working
  /// image until then (the same region, at the target resolution).
  ui.Image? get original => _reference ?? _working?.display;

  /// The reference image's size over the working image's, or 1:1 while there is
  /// no reference.
  ///
  /// The preview's region is expressed in working pixels — the artifact's own
  /// space — and the two images are different sizes, so the left half maps the
  /// region through this before drawing it.
  ui.Size get originalScale {
    final reference = _reference;
    final working = _working;
    if (reference == null ||
        working == null ||
        working.width <= 0 ||
        working.height <= 0) {
      return const ui.Size(1, 1);
    }
    return ui.Size(
      reference.width / working.width,
      reference.height / working.height,
    );
  }

  /// The working image the preview draws from before the reference lands, which
  /// is the image a parameter change replaces and retires.
  @visibleForTesting
  ui.Image? get debugWorkingDisplay => _working?.display;

  /// The result side: the artifact, decoded for display. Null while 原图 is
  /// selected or no artifact exists for the current parameters yet.
  ui.Image? get result => _result;

  /// The artifact the apply will write, or null when there is nothing to write.
  Uint8List? get artifact => _artifact;

  /// The artifact for the parameters currently selected, or null while the
  /// debounced pass for them is still running. An apply may only reuse bytes
  /// whose parameters still equal [params].
  Uint8List? get readyArtifact => _artifactParams == _params ? _artifact : null;

  /// The parameters [artifact] was produced with; the apply may only reuse it
  /// while this still equals [params].
  ManualCompressParams? get artifactParams => _artifactParams;

  /// Exact artifact size, which is also the exact size of the stored file.
  int? get artifactBytes => _artifact?.length;

  double get divider => _divider;

  // The source's facts survive a refused decode: the header provided them, and
  // the panel needs them to offer a working resolution that would fit.
  int get sourceWidth => _working?.sourceWidth ?? _refusedSource?.width ?? 0;
  int get sourceHeight => _working?.sourceHeight ?? _refusedSource?.height ?? 0;
  int get sourceBytes => _working?.sourceBytes ?? _refusedSource?.bytes ?? 0;
  int get sourceLongEdge => math.max(sourceWidth, sourceHeight);

  /// Coordinate space of [visibleSource]: the working image's size.
  int get workingWidth => _working?.width ?? 0;
  int get workingHeight => _working?.height ?? 0;
  int get workingLongEdge => math.max(workingWidth, workingHeight);

  /// True when the source had to be reduced to fit the working budget, so the
  /// panel has to say that 100% is the resolution this editor can reach, not the
  /// source's own.
  ///
  /// A target the user chose does not count: the slider and the result's
  /// dimensions already say what was asked for, while the reference side — the
  /// comparison's original — stays at the reachable edge either way.
  bool get budgetReducedSource =>
      reachableLongEdge > 0 && reachableLongEdge < sourceLongEdge;

  /// The largest long edge this image can be worked at: the source's own edge,
  /// capped by the working budget. It is also the long-edge slider's maximum, so
  /// the panel can never offer a resolution the pipeline will not produce — and
  /// it stays available after a refusal, because a smaller working resolution is
  /// exactly what can make a borderline source fit.
  int get reachableLongEdge => sourceLongEdge <= 0
      ? 0
      : resolveWorkingEdge(
          sourceWidth: sourceWidth,
          sourceHeight: sourceHeight,
          requestedLongEdge: sourceLongEdge,
          budgetPixels: _budgetPixels,
          floorAtQuarterOfSource: true,
        );

  /// The region of the working image currently mapped onto the viewport.
  Rect get visibleSource => _visible;

  int get _budgetPixels =>
      _budgetPixelsOverride ?? workingPixelBudget(desktop: _desktop);
  int get _budgetBytes =>
      _budgetBytesOverride ?? decodeByteBudget(desktop: _desktop);

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _working?.dispose();
    _reference?.dispose();
    _result?.dispose();
    _disposeRetired();
    super.dispose();
  }

  /// Reads the source's dimensions from the container, then produces the first
  /// working image and artifact. Dimensions are available before the pixels are,
  /// because the header carries them — including when the pixels are refused.
  Future<void> prepare() async {
    try {
      final working = await _workingFor(_params);
      if (_disposed || working == null) return;
      // The remembered long edge is normalised once the source's own size is
      // known, so the panel opens on the value that will actually be applied.
      // The pipeline already clamped the decode to the reachable edge, so this
      // never costs a second decode.
      _params = _normalize(_params);
      _preparing = false;
      notifyListeners();
      unawaited(_rebuild());
    } on WorkingImageTooLargeException catch (error) {
      // The refusal carries what the header already knew, so the panel can show
      // the source's size and offer a working resolution that fits instead of
      // collapsing to a dead end.
      debugPrint('[CompressEditor] Decode refused for $imagePath: $error');
      if (_disposed) return;
      _preparing = false;
      _tooLarge = true;
      _refusedSource = (
        width: error.sourceWidth,
        height: error.sourceHeight,
        bytes: error.sourceBytes,
      );
      _params = _normalize(_params);
      notifyListeners();
    } catch (error, stackTrace) {
      debugPrint('[CompressEditor] Prepare failed for $imagePath: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (_disposed) return;
      _preparing = false;
      _decodeFailed = true;
      notifyListeners();
    }
  }

  void setParams(ManualCompressParams value) {
    final next = _normalize(value);
    if (next == _params) return;
    _params = next;
    // The stored artifact encodes the previous parameters: keeping it on screen
    // (or letting an apply write it) would present a stale result as the
    // current one.
    _dropArtifact();
    notifyListeners();
    _scheduleRebuild();
  }

  /// The remembered long edge can come from a different image and therefore sit
  /// outside this image's reachable range. Clamping keeps the panel's readout
  /// and the applied value identical.
  ManualCompressParams _normalize(ManualCompressParams value) {
    final longEdge = value.maxLongEdge;
    if (longEdge == null || value.isNoOp) return value;
    // Before the source's size is known there is no range to clamp into, and
    // clamping into an empty one would silently destroy the value.
    if (sourceLongEdge <= 0 || reachableLongEdge <= 0) return value;
    // The pipeline resolves the edge a decode will actually use; asking it keeps
    // the panel's readout and the produced resolution on one implementation.
    final clamped = resolveWorkingEdge(
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
      requestedLongEdge: longEdge,
      budgetPixels: _budgetPixels,
      floorAtQuarterOfSource: true,
    );
    if (clamped == longEdge) return value;
    return ManualCompressParams(
      format: value.format,
      quality: value.quality,
      maxLongEdge: clamped,
    );
  }

  void _dropArtifact() {
    _artifact = null;
    _artifactParams = null;
    _result?.dispose();
    _result = null;
  }

  /// Called by the preview whenever the region it maps onto the viewport
  /// changes. The preview owns the framing; the controller records what is on
  /// screen and notifies, so a pan or a zoom is painted on the frame it happens
  /// on instead of waiting for whatever rebuilds the page next.
  void updateViewport({required Rect visible}) {
    if (_visible == visible) return;
    _visible = visible;
    notifyListeners();
  }

  void setDivider(double value) {
    final next = value.clamp(0.0, 1.0);
    if ((next - _divider).abs() < 0.0005) return;
    _divider = next;
    notifyListeners();
  }

  void _scheduleRebuild() {
    _timer?.cancel();
    if (_params.isNoOp) return;
    _timer = Timer(_kEncodeDebounce, () => unawaited(_rebuild()));
  }

  /// One decode pass: the working image at the target size, reusing the current
  /// pixels when the target has not moved.
  Future<WorkingImage?> _workingFor(ManualCompressParams params) async {
    final current = _working;
    if (current != null) {
      // Compared in the same space as the value stored below, so a parameter
      // that does not move the target can never cause a re-decode.
      final edge = _edgeFor(params, current.sourceWidth, current.sourceHeight);
      if (_workingEdge == edge) return current;
    }

    final WorkingImage next;
    try {
      next = await decodeWorkingImage(
        imagePath,
        params: params,
        budgetPixels: _budgetPixels,
        budgetBytes: _budgetBytes,
      );
    } on WorkingImageTooLargeException {
      _tooLarge = true;
      rethrow;
    }
    if (_disposed) {
      next.dispose();
      return null;
    }
    _tooLarge = false;
    // The source is no longer being refused, so the facts now come from the
    // decoded image itself.
    _refusedSource = null;
    _workingEdge = _edgeFor(params, next.sourceWidth, next.sourceHeight);
    final previous = _working;
    _working = next;
    // The viewport is measured in working pixels, so a re-decode at another
    // resolution has to carry the framing over rather than snap back to fit.
    if (previous != null) {
      final factor = next.longEdge / math.max(1, previous.longEdge);
      _visible = Rect.fromLTWH(
        _visible.left * factor,
        _visible.top * factor,
        _visible.width * factor,
        _visible.height * factor,
      );
      // Retired, not disposed: the preview's painter still holds these pixels
      // until the pass that follows publishes this replacement.
      _retire(previous);
    }
    return next;
  }

  int _edgeFor(ManualCompressParams params, int sourceWidth, int sourceHeight) {
    if (sourceWidth <= 0 || sourceHeight <= 0) return 0;
    return targetLongEdge(
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
      requestedLongEdge: params.isNoOp ? null : params.maxLongEdge,
      budgetPixels: _budgetPixels,
    );
  }

  Future<void> _rebuild() async {
    // While the first working image is on its way, no pass may start: a
    // parameter change arriving in that window would decode beside that first
    // decode, and the same source would be decoded twice at once. `prepare`
    // runs the first pass itself once it lands, on whatever parameters are
    // current then.
    if (_preparing) return;
    if (_busy || _referenceInFlight) {
      // A decode/encode — or the reference's own decode — is already running and
      // cannot be cancelled: remember that the parameters moved and re-run once
      // it finishes.
      _pending = true;
      return;
    }
    final params = _params;
    if (params.isNoOp) {
      _dropArtifact();
      notifyListeners();
      return;
    }
    _busy = true;
    notifyListeners();
    debugPassesStarted++;
    _passesInFlight++;
    if (_passesInFlight > debugMaxConcurrentPasses) {
      debugMaxConcurrentPasses = _passesInFlight;
    }
    try {
      final working = await _workingFor(params);
      if (working == null || _disposed || params != _params) return;
      final bytes = await encodeArtifact(working, params);
      if (_disposed || params != _params) return;
      final image = await _decodeUiImage(bytes);
      if (_disposed || params != _params) {
        image.dispose();
        return;
      }
      _result?.dispose();
      _result = image;
      _artifact = bytes;
      _artifactParams = params;
    } on WorkingImageTooLargeException catch (error) {
      // A parameter change can newly hit the gate: a longer edge needs a bigger
      // decode. The gate is reported through `tooLarge`, there is no artifact to
      // apply, and the source's facts are kept so the panel can still offer a
      // working resolution that would fit.
      _tooLarge = true;
      _refusedSource = (
        width: error.sourceWidth,
        height: error.sourceHeight,
        bytes: error.sourceBytes,
      );
    } catch (error, stackTrace) {
      debugPrint('[CompressEditor] Encode failed for $imagePath: $error');
      debugPrintStack(stackTrace: stackTrace);
    } finally {
      _passesInFlight--;
      _busy = false;
      if (!_disposed) {
        notifyListeners();
        // The frame this notify schedules is the one that stops the preview
        // from referencing the image this pass replaced.
        _flushRetired();
        if (_pending) {
          // The newest parameters win, and the pass they start may decode beside
          // nothing: the reference waits for the parameters to settle instead of
          // holding up the pass the user is waiting for.
          _pending = false;
          unawaited(_rebuild());
        } else {
          unawaited(_ensureReference());
        }
      }
    }
  }

  /// Decodes the reference image, once, as soon as the working image is smaller
  /// than the source's reachable edge.
  ///
  /// At the reachable edge the left half already *is* the source at its largest
  /// resolution, so nothing is decoded; below it, drawing the working image on
  /// the left would present a reduced 原图 as the original. Its own decode is a
  /// second decode of the same source, so it may not run beside a pass — and a
  /// pass may not run beside it; [_rebuild] records the parameters that arrive
  /// while it is in flight and re-runs them here.
  Future<void> _ensureReference() async {
    if (_disposed || _reference != null || _referenceFailed) return;
    assert(!_busy, 'the reference decode may not start beside a pass');
    final working = _working;
    if (working == null || _workingEdge >= reachableLongEdge) return;
    _referenceInFlight = true;
    try {
      final reference = await decodeReferenceImage(
        imagePath,
        budgetPixels: _budgetPixels,
        budgetBytes: _budgetBytes,
      );
      if (_disposed) {
        reference.dispose();
        return;
      }
      _reference = reference;
    } on WorkingImageTooLargeException catch (error) {
      // The gate can refuse the reference at the reachable edge while the
      // target-sized working image fits. The left half then stays at the target
      // resolution rather than showing nothing at all.
      debugPrint('[CompressEditor] Reference refused for $imagePath: $error');
      _referenceFailed = true;
    } catch (error, stackTrace) {
      debugPrint('[CompressEditor] Reference failed for $imagePath: $error');
      debugPrintStack(stackTrace: stackTrace);
      _referenceFailed = true;
    } finally {
      _referenceInFlight = false;
      if (!_disposed) {
        notifyListeners();
        if (_pending) {
          _pending = false;
          unawaited(_rebuild());
        }
      }
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
}
