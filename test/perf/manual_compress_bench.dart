// Step 0 of the bounded-working-image plan: freeze the gate matrix and the
// working-pixel budgets from measurement instead of arithmetic.
//
// A benchmark, not a test: it prints timings and RSS, contains no expect(), and
// is named out of the default `_test.dart` glob. Run one case per process —
// `ProcessInfo.maxRss` is a process-wide high-water mark, so sharing a process
// between cases would attribute an earlier case's peak to the next one:
//
//   flutter test test/perf/manual_compress_bench.dart \
//     --dart-define=BENCH_DIR=C:/path/to/fixtures \
//     --dart-define=BENCH_CASE=jpeg-200     # or 'all'
//
// The questions it answers:
//   1. Does the engine sub-scale at decode? (JPEG vs PNG at the same source
//      size: compare the RSS delta of instantiateCodec(target:).)
//   2. Is ImageDescriptor.encoded dimension-only, and EXIF-correct?
//   3. What does the working image (texture + straight RGBA + img.Image) cost
//      per target pixel?
//   4. Is the pure-Dart status quo really ~15 B/source pixel?
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:downsize/downsize.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// The one place output leaves this benchmark.
// ignore: avoid_print
void _emit(String line) => print(line);

const int _targetLongEdge = 1568;

class _Case {
  const _Case(this.name, this.file, this.sourcePixels);
  final String name;
  final String file;
  final int sourcePixels;
}

const _cases = <_Case>[
  _Case('jpeg-13', 'photo_13mp.jpg', 4160 * 3120),
  _Case('png-13', 'shot_13mp.png', 4160 * 3120),
  _Case('png-tall', 'tall_1000x8000.png', 1000 * 8000),
  _Case('exif-rot', 'rot_o6.jpg', 400 * 200),
  _Case('jpeg-50', 'photo_50mp.jpg', 8000 * 6250),
  _Case('png-50', 'shot_50mp.png', 8000 * 6250),
  _Case('jpeg-200', 'photo_200mp.jpg', 17000 * 11765),
  _Case('png-200', 'shot_200mp.png', 17000 * 11765),
];

int _rssMB() => ProcessInfo.maxRss ~/ (1024 * 1024);
int _curMB() => ProcessInfo.currentRss ~/ (1024 * 1024);

void _say(String label, {String note = '', Stopwatch? sw, int? sinceRss}) {
  final rss = _rssMB();
  final delta = sinceRss == null ? '' : ' dRss=${rss - sinceRss}MB';
  final ms = sw == null ? '' : ' ms=${sw.elapsedMilliseconds}';
  _emit(
    'BENCH|$label|maxRssMB=$rss$delta|curRssMB=${_curMB()}$ms'
    '${note.isEmpty ? '' : '|$note'}',
  );
}

/// Aspect-preserving fit of [w]x[h] into a [longEdge] square, never upscaling.
({int width, int height}) _target(int w, int h) {
  final longEdge = w > h ? w : h;
  if (longEdge <= _targetLongEdge) return (width: w, height: h);
  final scale = _targetLongEdge / longEdge;
  return (
    width: (w * scale).round().clamp(1, 1 << 30),
    height: (h * scale).round().clamp(1, 1 << 30),
  );
}

Future<void> _run(_Case c, String dir) async {
  final path = '$dir/${c.file}';
  _emit(
    'BENCH|${c.name}|start|maxRssMB=${_rssMB()}|ratio='
    '${(c.sourcePixels / 1000000).toStringAsFixed(1)}MP',
  );

  var sw = Stopwatch()..start();
  final bytes = File(path).readAsBytesSync();
  final fileBytes = bytes.length;
  _say('${c.name}|readFile', sw: sw, note: 'fileBytes=$fileBytes');

  // --- 1. header-only, EXIF-correct dimensions -----------------------------
  final rssBeforeHeader = _rssMB();
  sw = Stopwatch()..start();
  final headerBuffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  final headerDescriptor = await ui.ImageDescriptor.encoded(headerBuffer);
  final headerW = headerDescriptor.width;
  final headerH = headerDescriptor.height;
  _say(
    '${c.name}|headerDims',
    sw: sw,
    sinceRss: rssBeforeHeader,
    note: 'w=$headerW h=$headerH',
  );
  headerDescriptor.dispose();
  headerBuffer.dispose();

  // --- 2. engine decode at the artifact target ----------------------------
  final target = _target(headerW, headerH);
  final rssBeforeDecode = _rssMB();
  sw = Stopwatch()..start();
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  final descriptor = await ui.ImageDescriptor.encoded(buffer);
  final codec = await descriptor.instantiateCodec(
    targetWidth: target.width,
    targetHeight: target.height,
  );
  final frame = await codec.getNextFrame();
  final decoded = frame.image;
  _say(
    '${c.name}|engineDecode',
    sw: sw,
    sinceRss: rssBeforeDecode,
    note:
        'target=${target.width}x${target.height} '
        'got=${decoded.width}x${decoded.height}',
  );
  final rssAfterDecode = _rssMB();

  // --- 3. straight RGBA extraction (the working-image pixel source) -------
  sw = Stopwatch()..start();
  final raw = await decoded.toByteData(
    format: ui.ImageByteFormat.rawStraightRgba,
  );
  _say(
    '${c.name}|toByteData',
    sw: sw,
    sinceRss: rssAfterDecode,
    note: 'bytes=${raw?.lengthInBytes ?? -1}',
  );
  final rssAfterRaw = _rssMB();

  // --- 4. img.Image (package:image) built from those pixels ---------------
  sw = Stopwatch()..start();
  final working = img.Image.fromBytes(
    width: decoded.width,
    height: decoded.height,
    bytes: raw!.buffer,
    numChannels: 4,
    order: img.ChannelOrder.rgba,
  );
  _say(
    '${c.name}|imgImage',
    sw: sw,
    sinceRss: rssAfterRaw,
    note: 'w=${working.width} h=${working.height}',
  );
  final rssAfterWorking = _rssMB();

  // The model behind the budget: bytes per *target* pixel for the working set.
  final targetPixels = working.width * working.height;
  _emit(
    'BENCH|${c.name}|workingSet'
    '|targetMP=${(targetPixels / 1000000).toStringAsFixed(2)}'
    '|workingDeltaMB=${rssAfterWorking - rssBeforeDecode}'
    '|bytesPerTargetPixel='
    '${((rssAfterWorking - rssBeforeDecode) * 1024 * 1024 / targetPixels).toStringAsFixed(2)}',
  );

  // --- 5. the new artifact path: encode the working image, no resize ------
  sw = Stopwatch()..start();
  final artifact = Downsize().compressDecoded(
    working,
    Config(format: DownsizeFormat.jpeg, quality: 80),
  );
  _say(
    '${c.name}|encodeWorking',
    sw: sw,
    sinceRss: rssAfterWorking,
    note: 'artifactBytes=${artifact.length}',
  );

  decoded.dispose();
  codec.dispose();
  descriptor.dispose();
  buffer.dispose();

  // --- 6. the status quo: Downsize.compress(source bytes) -----------------
  // Skipped at 200 MP on purpose: that is the ~3 GB path this plan replaces,
  // and letting it run here would abort the process mid-benchmark.
  if (c.sourcePixels <= 60 * 1000 * 1000) {
    final rssBeforeLegacy = _rssMB();
    sw = Stopwatch()..start();
    final legacy = Downsize().compress(
      Config(
        data: Uint8List.fromList(bytes),
        format: DownsizeFormat.jpeg,
        quality: 80,
        maxLongEdge: _targetLongEdge,
      ),
    );
    _say(
      '${c.name}|legacyDownsize',
      sw: sw,
      sinceRss: rssBeforeLegacy,
      note:
          'bytes=${legacy?.length} '
          'bytesPerSourcePixel='
          '${((_rssMB() - rssBeforeLegacy) * 1024 * 1024 / c.sourcePixels).toStringAsFixed(2)}',
    );
  } else {
    _emit(
      'BENCH|${c.name}|legacyDownsize|SKIPPED|'
      'reason=would allocate ~${(c.sourcePixels * 15 / 1000000).round()}MB',
    );
  }
  _emit('BENCH|${c.name}|end|maxRssMB=${_rssMB()}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const dir = String.fromEnvironment('BENCH_DIR');
  if (dir.isEmpty) {
    test('BENCH_DIR not set', () {
      _emit('BENCH|ERROR|pass --dart-define=BENCH_DIR=<fixture dir>');
    });
    return;
  }
  const only = String.fromEnvironment('BENCH_CASE', defaultValue: 'all');
  for (final c in _cases) {
    if (only != 'all' && only != c.name) continue;
    test(
      'bench ${c.name}',
      () => _run(c, dir),
      timeout: const Timeout(Duration(minutes: 10)),
    );
  }
}
