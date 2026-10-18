import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:system_fonts/system_fonts.dart';

import '../../../core/services/fonts/google_fonts_service.dart';
import '../../../utils/app_directories.dart';
import '../../../utils/sandbox_path_resolver.dart';

/// Whether [bytes] are a font file the PDF writer can embed.
///
/// Only a single TrueType face works. A collection starts with `ttcf` and the
/// writer's parser has no collection support at all — that is every CJK font
/// iOS and Android ship, and Microsoft YaHei on Windows — while `OTTO` is CFF
/// outlines, and the writer's glyph loader reads `glyf`, which a CFF font does
/// not have. Both would embed a font with no glyphs rather than fail, so the
/// check is what keeps a "successful" export from being blanks.
///
/// The version word also has to be `0x00010000` and not Apple's `'true'`, for a
/// related reason: the writer decides a face is Unicode by that word alone
/// (`ttf_parser.dart`: `unicode => bytes.getUint32(0) == 0x10000`) and writes
/// every other face as Latin-1, so a `'true'` face is opened happily and then
/// drops every rune outside U+00FF — silently, and while still reporting itself
/// as a real face, which is the one thing this check exists to prevent.
///
/// Only the first bytes are read, so a caller may pass a file's head rather than
/// the file: enumerating a font directory costs a header read per font.
bool isPdfEmbeddableFont(Uint8List bytes) {
  if (bytes.length < 12) return false;
  return bytes[0] == 0 && bytes[1] == 1 && bytes[2] == 0 && bytes[3] == 0;
}

/// Whether [bytes] hold the colour bitmaps an emoji is drawn from.
///
/// The writer draws an emoji as a bitmap only out of CBDT, indexed by CBLC
/// (`ttf_parser.dart`: `getBitmap` reads those two tables and nothing else). A
/// face with outlines instead — Windows' Segoe UI Emoji is COLR — still prints
/// the emoji, in a single colour, so this is the difference between coloured and
/// monochrome rather than between working and blank.
bool pdfFontHasColourBitmaps(Uint8List bytes) {
  final tables = _fontTables(bytes);
  return tables != null && tables.contains('CBDT') && tables.contains('CBLC');
}

/// The table tags a single-face TrueType file declares, or null when it is not
/// one. Collections are not readable by the writer, and their directory is not
/// at this offset, which is the same reason [isPdfEmbeddableFont] rejects them.
Set<String>? _fontTables(Uint8List bytes) {
  if (bytes.length < 12) return null;
  if (bytes[0] != 0 || bytes[1] != 1 || bytes[2] != 0 || bytes[3] != 0) {
    return null;
  }
  final count = (bytes[4] << 8) | bytes[5];
  final tags = <String>{};
  for (var index = 0; index < count; index++) {
    final offset = 12 + index * 16;
    if (offset + 4 > bytes.length) return null;
    tags.add(String.fromCharCodes(bytes, offset, offset + 4));
  }
  return tags;
}

/// The three things one export draws with.
enum PdfFontRole { body, mono, emoji }

/// What the user asked an export to draw a role with.
///
/// [PdfFontAuto] is the chain whose order the writer forces (see
/// [PdfFontResolver.resolve]); the other three name a source outright, so the
/// dialog can offer exactly what the resolver can actually honour.
sealed class PdfFontChoice {
  const PdfFontChoice();
}

/// The cheapest usable source, in the order the writer's limits dictate.
final class PdfFontAuto extends PdfFontChoice {
  const PdfFontAuto();
}

/// One file on this machine, by path.
final class PdfFontSystemFace extends PdfFontChoice {
  const PdfFontSystemFace(this.path);
  final String path;
}

/// A family from the font catalogue, downloaded and cached on first use.
final class PdfFontDownload extends PdfFontChoice {
  const PdfFontDownload(this.family);
  final String family;
}

/// No face at all: the writer's built-in font, which covers Latin-1 only.
final class PdfFontBuiltIn extends PdfFontChoice {
  const PdfFontBuiltIn();
}

/// Where a resolved face came from, which is what the dialog names.
enum PdfFontSource {
  /// The font the settings picked for the app or for code.
  picked,

  /// A face found on this machine.
  system,

  /// A face a previous export downloaded and left in the cache.
  cached,

  /// A face this resolution downloaded.
  downloaded,

  /// A monospace role drawn in the body face.
  body,

  /// The writer's built-in font.
  builtIn,

  /// No face at all, which is only the emoji role: its runes are dropped.
  none,
}

/// What one role resolved to, without its bytes.
///
/// The bytes are what the layout needs; this is what a person reads, so the two
/// travel together and the dialog never has to guess which face it is looking
/// at. [pending] marks a face an export would go and get: the dialog shows the
/// download it is about to make instead of a face it does not have yet.
class PdfFontStatus {
  const PdfFontStatus(
    this.source, {
    this.name,
    this.fallback,
    this.pending = false,
    this.colour = false,
  });

  final PdfFontSource source;

  /// The file name or family name the face is known by, when it has one.
  final String? name;

  /// Why a face the user asked for was not used, when it was not.
  final String? fallback;

  /// Whether resolving this role needs the network.
  final bool pending;

  /// Whether the face draws emoji from colour bitmaps (the emoji role).
  final bool colour;

  PdfFontStatus withFallback(String reason) => PdfFontStatus(
    source,
    name: name,
    fallback: reason,
    pending: pending,
    colour: colour,
  );
}

/// Why a request could not be honoured, for the row's second line.
const String kPdfFontChosenUnusable = 'the chosen font could not be read';

/// One row of the font picker.
class PdfFontCandidate {
  const PdfFontCandidate({
    required this.choice,
    this.label,
    this.detail,
    this.note,
  });

  final PdfFontChoice choice;

  /// The file or family name; null for [PdfFontAuto] and [PdfFontBuiltIn],
  /// which the dialog names itself because those names are translated.
  final String? label;

  /// The absolute path, for the tooltip and the log rather than the row.
  final String? detail;

  final PdfFontNote? note;
}

/// What a candidate's second line says about it.
///
/// [PdfFontNote.cjk] comes from the file name matching a CJK hint rather than
/// from the font's character map: reading coverage means parsing `cmap`, and a
/// name hint is what the resolver itself goes by. A face that matches no hint
/// gets no note, rather than claiming to be Latin-only.
enum PdfFontNote { cjk, colour, monochrome }

/// The fonts one export writes with.
///
/// A null face means the writer's built-in font: it covers Latin-1 only, so an
/// export that falls back to it prints CJK as blanks. That is a degrade the
/// export reports rather than a failure, because a conversation of plain English
/// is still worth exporting on a machine with no usable CJK font.
class PdfExportFonts {
  const PdfExportFonts({
    required this.body,
    required this.mono,
    required this.emoji,
    required this.status,
  });

  final Uint8List? body;
  final Uint8List? mono;

  /// The face an emoji is drawn from.
  ///
  /// It has to be a *fallback* rather than a base face: the writer looks for an
  /// emoji's bitmap on the fallback chain of the style that could not draw the
  /// rune, so an emoji face set as `base` is never consulted for a bitmap.
  final Uint8List? emoji;

  /// What each role resolved to, keyed as the dialog asks for it.
  final Map<PdfFontRole, PdfFontStatus> status;

  Uint8List? bytesOf(PdfFontRole role) => switch (role) {
    PdfFontRole.body => body,
    PdfFontRole.mono => mono,
    PdfFontRole.emoji => emoji,
  };

  PdfFontStatus statusOf(PdfFontRole role) =>
      status[role] ?? const PdfFontStatus(PdfFontSource.none);

  /// Whether the emoji role draws in colour, which is what a CBDT face does.
  bool colourOf(PdfFontRole role) => statusOf(role).colour;
}

/// Resolves the faces an export needs, and lists what it could use instead.
///
/// The resolver is an object because the dialog needs the same rules twice: once
/// to show what is already available (no network), and once to run the export.
/// It is not `final` because a test substitutes one rather than enumerate the
/// machine's fonts.
class PdfFontResolver {
  PdfFontResolver({this.googleFonts});

  /// The catalogue a resolution may download from; null means "what is already
  /// on disk", which is what the dialog's first pass asks for.
  final GoogleFontsService? googleFonts;

  /// The catalogue this resolver downloads through, carrying whether a download
  /// has already failed for *this* resolver.
  late final _Catalogue _catalogue = _Catalogue(googleFonts);

  final Map<PdfFontRole, List<PdfFontCandidate>> _candidates =
      <PdfFontRole, List<PdfFontCandidate>>{};

  /// Resolves all three roles.
  ///
  /// The order is a consequence of what the writer can open, not a preference:
  ///
  /// 1. **The font the user picked**, when it is a file. A family name is not
  ///    something to embed, so a system-family choice is skipped.
  /// 2. **A single-face CJK font already on the machine.** Instant, offline, and
  ///    on a desktop it is the face the system itself draws CJK with.
  /// 3. **A downloaded CJK face, cached on disk.** The only path that works on
  ///    iOS and Android, whose system CJK fonts are collections the writer cannot
  ///    open — and the reason the download is last rather than first: it is three
  ///    round trips, and a first export should not wait behind them when the
  ///    answer is already on disk.
  ///
  /// The emoji face is resolved the same way and for the same reason. Its system
  /// scan prefers a face with colour bitmaps, but a machine that only has an
  /// outline emoji face (Windows) keeps it rather than downloading ten megabytes
  /// to colour the emoji in: which face is used is something the export dialog
  /// shows, so the coloured download is a choice there rather than a surprise
  /// here.
  ///
  /// [allowDownload] false answers with what is already on disk: a role that
  /// would need the network comes back [PdfFontStatus.pending] instead, which is
  /// what the dialog shows before the user asks for the check.
  Future<PdfExportFonts> resolve({
    PdfFontChoice body = const PdfFontAuto(),
    PdfFontChoice mono = const PdfFontAuto(),
    PdfFontChoice emoji = const PdfFontAuto(),
    String? appFontPath,
    String? codeFontPath,
    bool allowDownload = true,
  }) async {
    // A resolution that may not download is handed no catalogue at all, which is
    // what makes "already on disk" a property of this call rather than a flag
    // the deeper helpers have to remember to check.
    final catalogue = allowDownload ? _catalogue : null;
    final bodyFace = await _resolveBody(
      appFontPath,
      choice: body,
      catalogue: catalogue,
    );
    final monoFace = await _resolveMono(
      codeFontPath,
      choice: mono,
      body: bodyFace,
    );
    final emojiFace = await _resolveEmoji(choice: emoji, catalogue: catalogue);
    return PdfExportFonts(
      body: bodyFace.bytes,
      mono: monoFace.bytes,
      emoji: emojiFace.bytes,
      status: <PdfFontRole, PdfFontStatus>{
        PdfFontRole.body: bodyFace.status,
        PdfFontRole.mono: monoFace.status,
        PdfFontRole.emoji: emojiFace.status,
      },
    );
  }

  /// Every face the export could draw [role] with, in the order to offer them.
  ///
  /// The list is the resolver's own vocabulary — auto, the machine's embeddable
  /// faces, the families it can download, the built-in font — so the picker
  /// cannot offer a choice [resolve] would not honour. It is computed once per
  /// role per resolver: enumerating fonts reads every file's header.
  Future<List<PdfFontCandidate>> candidates(PdfFontRole role) async {
    final cached = _candidates[role];
    if (cached != null) return cached;

    final out = <PdfFontCandidate>[
      const PdfFontCandidate(choice: PdfFontAuto()),
    ];
    final hints = switch (role) {
      PdfFontRole.body => _cjkFontNameHints,
      PdfFontRole.mono => _monoFontNameHints,
      PdfFontRole.emoji => _emojiFontNameHints,
    };
    for (final face in await _systemFaces()) {
      final matches = hints.any((hint) => face.key.contains(hint));
      final note = role == PdfFontRole.emoji
          ? (face.colour ? PdfFontNote.colour : PdfFontNote.monochrome)
          : (matches ? PdfFontNote.cjk : null);
      out.add(
        PdfFontCandidate(
          choice: PdfFontSystemFace(face.path),
          label: face.name,
          detail: face.path,
          note: note,
        ),
      );
    }
    for (final family in _downloadFamilies(role)) {
      out.add(PdfFontCandidate(choice: PdfFontDownload(family), label: family));
    }
    out.add(const PdfFontCandidate(choice: PdfFontBuiltIn()));
    _candidates[role] = out;
    return out;
  }

  /// The choice the app's own font settings name, or null when this resolver
  /// cannot honour it.
  ///
  /// The settings hold what the app's picker called a family, and the export
  /// embeds *files*, so the family is matched against the candidates this resolver
  /// would offer anyway — the same list the picker shows, which is what keeps a
  /// default from naming a face [resolve] would refuse.
  ///
  /// The match is the file's own name first. A family often ships more than one
  /// file, though, and only some of them are faces the writer can open: Noto Sans
  /// SC arrives here as `Noto Sans SC Medium (TrueType).otf`, which is CFF and
  /// which the writer would embed empty, beside `NotoSansSC-VF.ttf`, which is
  /// TrueType and which it can draw. So a family match falls back to the same
  /// family's first usable file.
  Future<PdfFontChoice?> preferred(PdfFontRole role, {String? family}) async {
    final name = family?.trim() ?? '';
    if (name.isEmpty) return null;
    final candidates = await this.candidates(role);

    final wanted = _normaliseName(name);
    for (final candidate in candidates) {
      final detail = candidate.detail;
      if (detail == null) continue;
      if (_normaliseName(p.basenameWithoutExtension(detail)) == wanted) {
        return candidate.choice;
      }
    }
    for (final candidate in candidates) {
      final choice = candidate.choice;
      if (choice is PdfFontDownload &&
          _normaliseName(choice.family) == wanted) {
        return choice;
      }
    }
    final stem = _familyStem(name);
    if (stem.isEmpty) return null;
    for (final candidate in candidates) {
      final detail = candidate.detail;
      if (detail == null) continue;
      if (_normaliseName(p.basenameWithoutExtension(detail)).startsWith(stem)) {
        return candidate.choice;
      }
    }
    return null;
  }
}

/// [name] as something to compare: lower case, without what only spells how a
/// font is packaged.
String _normaliseName(String name) =>
    name.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');

/// The family part of a picker's name: without its style and without the type in
/// brackets, both of which a picker adds to the file's own name.
///
/// `Noto Sans SC Medium (TrueType)` is the family `Noto Sans SC` in one style, and
/// matching on the whole string would find nothing at all: the file is called
/// `NotoSansSC-VF.ttf`.
String _familyStem(String name) {
  final withoutType = name.replaceFirst(
    RegExp(r'\s*\((?:true|open)type\)\s*$', caseSensitive: false),
    '',
  );
  final withoutStyle = withoutType.replaceFirst(
    RegExp(
      r'\s+(?:regular|medium|semibold|semi light|light|thin|black|heavy|book'
      r'|bold|italic|oblique)$',
      caseSensitive: false,
    ),
    '',
  );
  return _normaliseName(withoutStyle);
}

/// The families the export is willing to download for [role], best first.
///
/// A monospace role has none: a code block drawn in the body face is the
/// deliberate answer there, and no download makes it better.
List<String> _downloadFamilies(PdfFontRole role) => switch (role) {
  PdfFontRole.body => _cjkFamilies,
  PdfFontRole.emoji => _emojiFamilies,
  PdfFontRole.mono => const <String>[],
};

class _Face {
  const _Face(this.bytes, this.status);

  final Uint8List? bytes;
  final PdfFontStatus status;

  _Face withFallback(String reason) =>
      _Face(bytes, status.withFallback(reason));
}

/// The catalogue one resolver may download from, and whether a download has
/// already failed for it.
///
/// Each attempt costs three round trips' worth of timeout, and this runs before
/// any visible progress, so a role that has failed is not asked again by the next
/// role of the same resolution. It is deliberately *not* a library-level flag: a
/// second dialog is a second resolver and gets a second chance, because the first
/// failure can be a network that came back, or a catalogue that was closed by
/// whoever owned it.
class _Catalogue {
  _Catalogue(this.service);

  final GoogleFontsService? service;

  bool failed = false;
}

Future<_Face> _resolveBody(
  String? appFontPath, {
  required PdfFontChoice choice,
  required _Catalogue? catalogue,
}) async {
  switch (choice) {
    case PdfFontBuiltIn():
      return const _Face(null, PdfFontStatus(PdfFontSource.builtIn));
    case PdfFontSystemFace(:final path):
      final face = await _faceFromPath(path, PdfFontSource.picked);
      if (face != null) return face;
    case PdfFontDownload(:final family):
      final face = await _downloadFace(
        family: family,
        role: PdfFontRole.body,
        catalogue: catalogue,
      );
      if (face != null) return face;
      // Nothing was asked of the network, so the row says what the check would
      // fetch rather than naming a face this resolution never had.
      if (catalogue == null) {
        return _Face(
          null,
          PdfFontStatus(PdfFontSource.downloaded, name: family, pending: true),
        );
      }
    case PdfFontAuto():
      break;
  }

  final auto = await _autoBody(appFontPath, catalogue: catalogue);
  return choice is PdfFontAuto
      ? auto
      : auto.withFallback(kPdfFontChosenUnusable);
}

Future<_Face> _autoBody(
  String? appFontPath, {
  required _Catalogue? catalogue,
}) async {
  final picked = await _faceFromPath(appFontPath, PdfFontSource.picked);
  if (picked != null) return picked;

  final system = await _firstSystemFace(_cjkFontNameHints, PdfFontRole.body);
  if (system != null) return system;

  final cached = await _cachedFace(PdfFontRole.body);
  if (cached != null) return cached;

  final downloaded = await _downloadFace(
    role: PdfFontRole.body,
    catalogue: catalogue,
  );
  if (downloaded != null) return downloaded;

  return const _Face(null, PdfFontStatus(PdfFontSource.builtIn));
}

/// The emoji face, which is a fallback rather than a base face because that is
/// where the writer looks for an emoji's bitmap.
Future<_Face> _resolveEmoji({
  required PdfFontChoice choice,
  required _Catalogue? catalogue,
}) async {
  switch (choice) {
    case PdfFontBuiltIn():
      return const _Face(null, PdfFontStatus(PdfFontSource.none));
    case PdfFontSystemFace(:final path):
      final face = await _faceFromPath(
        path,
        PdfFontSource.picked,
        colour: true,
      );
      if (face != null) return face;
    case PdfFontDownload(:final family):
      final face = await _downloadFace(
        family: family,
        role: PdfFontRole.emoji,
        catalogue: catalogue,
      );
      if (face != null) return face;
      if (catalogue == null) {
        return _Face(
          null,
          PdfFontStatus(PdfFontSource.downloaded, name: family, pending: true),
        );
      }
    case PdfFontAuto():
      break;
  }

  final auto = await _autoEmoji(catalogue: catalogue);
  return choice is PdfFontAuto
      ? auto
      : auto.withFallback(kPdfFontChosenUnusable);
}

Future<_Face> _autoEmoji({required _Catalogue? catalogue}) async {
  final system = await _firstSystemFace(_emojiFontNameHints, PdfFontRole.emoji);
  if (system != null) return system;

  final cached = await _cachedFace(PdfFontRole.emoji);
  if (cached != null) return cached;

  final downloaded = await _downloadFace(
    role: PdfFontRole.emoji,
    catalogue: catalogue,
  );
  if (downloaded != null) return downloaded;

  // An export without an emoji face is not an export without emoji: the writer
  // draws a box where a rune no font can draw would have been.
  return const _Face(null, PdfFontStatus(PdfFontSource.none));
}

/// The code role, which has no download: the body face is its answer.
Future<_Face> _resolveMono(
  String? codeFontPath, {
  required PdfFontChoice choice,
  required _Face body,
}) async {
  switch (choice) {
    case PdfFontBuiltIn():
      return const _Face(null, PdfFontStatus(PdfFontSource.builtIn));
    case PdfFontSystemFace(:final path):
      final face = await _faceFromPath(path, PdfFontSource.picked);
      if (face != null) return face;
    case PdfFontDownload():
      // The picker offers no monospace download, so this can only arrive from a
      // session option written by an older build; the auto answer is the honest
      // one rather than a silent no-op.
      break;
    case PdfFontAuto():
      break;
  }

  final auto = await _autoMono(codeFontPath, body: body);
  return choice is PdfFontAuto
      ? auto
      : auto.withFallback(kPdfFontChosenUnusable);
}

Future<_Face> _autoMono(String? codeFontPath, {required _Face body}) async {
  final picked = await _faceFromPath(codeFontPath, PdfFontSource.picked);
  if (picked != null) return picked;

  final system = await _firstSystemFace(_monoFontNameHints, PdfFontRole.mono);
  if (system != null) return system;

  // A code block drawn in the body face is wrong rather than unreadable, and it
  // keeps the CJK inside a code block legible, which a Latin-only monospace face
  // would not.
  return _Face(
    body.bytes,
    body.bytes == null
        ? body.status
        : PdfFontStatus(PdfFontSource.body, name: body.status.name),
  );
}

/// The whole bytes of one file, or null when it is missing or unusable.
Future<_Face?> _faceFromPath(
  String? path,
  PdfFontSource source, {
  bool colour = false,
}) async {
  if (path == null || path.isEmpty) return null;
  try {
    final file = File(SandboxPathResolver.fix(path));
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    if (!isPdfEmbeddableFont(bytes)) return null;
    return _Face(
      bytes,
      PdfFontStatus(
        source,
        name: p.basename(file.path),
        colour: colour && pdfFontHasColourBitmaps(bytes),
      ),
    );
  } catch (_) {
    return null;
  }
}

/// One file on this machine the writer can open.
class _SystemFace {
  const _SystemFace({
    required this.name,
    required this.key,
    required this.path,
    required this.colour,
  });

  final String name;
  final String key;
  final String path;
  final bool colour;
}

List<_SystemFace>? _systemFacesCache;

/// Every system font the writer can open, read once per run.
///
/// The match is on the file name because that is what the platform enumerates: a
/// family name does not name a file, and the file behind a family is often a
/// collection this writer cannot open. Enumerating already drops collections —
/// the plugin lists `.ttf` and `.otf` only — and [isPdfEmbeddableFont] rejects
/// the CFF ones. Only each file's header is read, because a directory holds
/// hundreds of fonts and every one of them would otherwise be loaded whole.
Future<List<_SystemFace>> _systemFaces() async {
  final cached = _systemFacesCache;
  if (cached != null) return cached;
  final out = <_SystemFace>[];
  try {
    final byName = <String, String>{};
    for (final path in SystemFonts().getFontPaths()) {
      byName[p.basenameWithoutExtension(path).toLowerCase()] = path;
    }
    for (final entry in byName.entries) {
      try {
        final head = await _headOf(File(entry.value), 1024);
        if (!isPdfEmbeddableFont(head)) continue;
        out.add(
          _SystemFace(
            name: p.basename(entry.value),
            key: entry.key,
            path: entry.value,
            colour: pdfFontHasColourBitmaps(head),
          ),
        );
      } catch (_) {
        // An unreadable file is not a candidate.
      }
    }
  } catch (_) {
    // An unreadable font directory is the same as having no font there.
  }
  _systemFacesCache = out;
  return out;
}

Future<Uint8List> _headOf(File file, int length) async {
  final handle = await file.open();
  try {
    return await handle.read(length);
  } finally {
    await handle.close();
  }
}

/// The first system font whose file name matches one of [hints], most desirable
/// hint first, and among a hint's matches in enumeration order.
Future<_Face?> _firstSystemFace(List<String> hints, PdfFontRole role) async {
  final faces = await _systemFaces();
  if (faces.isEmpty) return null;
  for (final hint in hints) {
    for (final face in faces) {
      if (!face.key.contains(hint)) continue;
      final loaded = await _faceFromPath(
        face.path,
        PdfFontSource.system,
        colour: role == PdfFontRole.emoji,
      );
      if (loaded != null) return loaded;
    }
  }
  return null;
}

/// The roles a downloaded face is cached under, one file each: a face is cached
/// because it was chosen for a *purpose*, and the family behind that purpose can
/// change with the catalogue.
String _roleKey(PdfFontRole role) => switch (role) {
  PdfFontRole.body => 'body',
  PdfFontRole.mono => 'mono',
  PdfFontRole.emoji => 'emoji',
};

/// The download cache, and the offline path read before any network is touched.
Future<Directory> _downloadCacheDirectory() async {
  final dir = Directory(
    '${(await AppDirectories.getCacheDirectory()).path}/pdf_export_fonts',
  );
  await dir.create(recursive: true);
  return dir;
}

Future<_Face?> _cachedFace(PdfFontRole role) async {
  try {
    final dir = await _downloadCacheDirectory();
    final file = File('${dir.path}/${_roleKey(role)}.ttf');
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    if (!isPdfEmbeddableFont(bytes)) return null;
    return _Face(
      bytes,
      PdfFontStatus(
        PdfFontSource.cached,
        name: await _cachedFaceFamily(file),
        colour: role == PdfFontRole.emoji && pdfFontHasColourBitmaps(bytes),
      ),
    );
  } catch (_) {
    // A cache that cannot be read is a cache miss.
  }
  return null;
}

/// The family a cached face was downloaded as, kept beside it so the dialog can
/// name it after a restart.
Future<String> _cachedFaceFamily(File face) async {
  try {
    final line = await File('${face.path}.family.txt').readAsString();
    if (line.trim().isNotEmpty) return line.trim();
  } catch (_) {
    // A cache written before the family was recorded still has its bytes.
  }
  return 'a font';
}

Future<_Face?> _downloadFace({
  required PdfFontRole role,
  String? family,
  required _Catalogue? catalogue,
}) async {
  final service = catalogue?.service;
  if (service == null || catalogue!.failed) return null;
  try {
    final entries = await service.loadCatalog();
    final entry = family == null
        ? _pickEntry(entries, role)
        : _entryNamed(entries, family);
    if (entry == null) return null;
    final downloaded = await service.download(entry);
    try {
      final bytes = await downloaded.file.readAsBytes();
      if (!isPdfEmbeddableFont(bytes)) return null;
      final dir = await _downloadCacheDirectory();
      final face = File('${dir.path}/${_roleKey(role)}.ttf');
      await face.writeAsBytes(bytes, flush: true);
      await File(
        '${face.path}.family.txt',
      ).writeAsString(entry.family, flush: true);
      // The licence travels beside the file, as it does for an imported font:
      // the cached copy outlives the dialog that downloaded it.
      await File(
        '${face.path}.license.txt',
      ).writeAsString(downloaded.license, flush: true);
      return _Face(
        bytes,
        PdfFontStatus(
          PdfFontSource.downloaded,
          name: entry.family,
          colour: role == PdfFontRole.emoji && pdfFontHasColourBitmaps(bytes),
        ),
      );
    } finally {
      await downloaded.dispose();
    }
  } catch (_) {
    // Offline, rate-limited, or a family the catalogue no longer lists: the
    // system scan and the built-in font are the fallbacks. A failure is
    // remembered for the rest of this resolver's resolution, so the other roles
    // do not wait behind the same three timeouts.
    catalogue.failed = true;
    return null;
  }
}

GoogleFontEntry? _entryNamed(List<GoogleFontEntry> entries, String family) {
  for (final entry in entries) {
    if (entry.family.toLowerCase() == family.toLowerCase()) return entry;
  }
  return null;
}

GoogleFontEntry? _pickEntry(List<GoogleFontEntry> entries, PdfFontRole role) =>
    switch (role) {
      PdfFontRole.emoji => _pickEmojiEntry(entries),
      PdfFontRole.body => _pickCjkEntry(entries),
      PdfFontRole.mono => null,
    };

/// The CJK families the export is willing to download, best first.
const List<String> _cjkFamilies = <String>[
  'Noto Sans SC',
  'Noto Sans Simplified Chinese',
];

/// The emoji families the export is willing to download, best first.
///
/// Noto Color Emoji first because it is the one that carries colour bitmaps; the
/// monochrome outline face is the fallback for a catalogue that lacks it.
const List<String> _emojiFamilies = <String>['Noto Color Emoji', 'Noto Emoji'];

GoogleFontEntry? _pickEmojiEntry(List<GoogleFontEntry> entries) {
  for (final family in _emojiFamilies) {
    for (final entry in entries) {
      if (entry.family.toLowerCase() == family.toLowerCase()) return entry;
    }
  }
  for (final entry in entries) {
    if (entry.family.toLowerCase().contains('emoji')) return entry;
  }
  return null;
}

GoogleFontEntry? _pickCjkEntry(List<GoogleFontEntry> entries) {
  for (final family in _cjkFamilies) {
    for (final entry in entries) {
      if (entry.family.toLowerCase() == family.toLowerCase()) return entry;
    }
  }
  for (final entry in entries) {
    final family = entry.family.toLowerCase();
    if (!family.contains('noto sans')) continue;
    if (entry.subsets.contains('chinese-simplified')) return entry;
  }
  for (final entry in entries) {
    if (entry.subsets.contains('chinese-simplified')) return entry;
  }
  return null;
}

/// Single-face CJK fonts, most desirable first, matched against the *file* name
/// the platform enumerates.
const List<String> _cjkFontNameHints = <String>[
  'deng',
  'dengxian',
  'simhei',
  'simkai',
  'simfang',
  'arialuni',
  'notosanssc',
  'notosanshans',
  'notosanscjk',
  'sourcehansans',
  'droidsansfallback',
];

/// Single-face emoji fonts, most desirable first, matched against the *file*
/// name the platform enumerates.
///
/// The order prefers a face the writer can draw in colour: Noto Color Emoji
/// carries CBDT bitmaps, while Windows' Segoe UI Emoji is a COLR face whose
/// emoji are outlines, which the writer prints in a single colour.
const List<String> _emojiFontNameHints = <String>[
  'notocoloremoji',
  'notoemoji',
  'applecoloremoji',
  'seguiemj',
  'segoeuiemoji',
  'emojione',
  'twemoji',
];

/// Single-face monospace fonts, most desirable first.
const List<String> _monoFontNameHints = <String>[
  'consola',
  'cascadiacode',
  'monaco',
  'sfnsmono',
  'menlo',
  'cour',
  'lucon',
  'dejavusansmono',
  'liberationmono',
  'notosansmono',
  'robotomono',
  'jetbrainsmono',
  'sourcecodepro',
  'firacode',
  'hack',
  'ubuntumono',
];
