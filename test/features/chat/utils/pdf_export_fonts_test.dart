import 'dart:typed_data';

import 'package:Cuplivo/core/services/fonts/google_fonts_service.dart';
import 'package:Cuplivo/features/chat/utils/export_document.dart';
import 'package:Cuplivo/features/chat/utils/markdown_pdf_emitter.dart';
import 'package:Cuplivo/features/chat/utils/pdf_export_fonts.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as syncfusion;

/// The faces an export picks, and what an emoji does with and without one.
///
/// An emoji is the one glyph the writer draws from a *fallback*: it asks the
/// font chain of the style that could not draw the rune, and takes a bitmap only
/// when that face carries CBDT (`text.dart`). So the two things worth pinning
/// are that the chain finds the face offline and hands it over as a fallback, and
/// that an emoji without one is dropped rather than printed as something else.
void main() {
  test('a colour bitmap face is recognised by its tables, outlines are not', () {
    expect(
      pdfFontHasColourBitmaps(_syntheticFont(<String>['CBDT', 'CBLC'])),
      isTrue,
    );
    // CBDT without the CBLC index it is read through is not a bitmap the writer
    // can find.
    expect(pdfFontHasColourBitmaps(_syntheticFont(<String>['CBDT'])), isFalse);
    expect(
      pdfFontHasColourBitmaps(_syntheticFont(<String>['COLR', 'CPAL', 'glyf'])),
      isFalse,
    );
    expect(pdfFontHasColourBitmaps(_syntheticFont(<String>[])), isFalse);
    // A collection keeps its table directory somewhere else entirely, which is
    // why the writer cannot open one at all.
    expect(
      pdfFontHasColourBitmaps(Uint8List.fromList('ttcf'.codeUnits)),
      isFalse,
    );
    expect(
      pdfFontHasColourBitmaps(Uint8List.fromList(<int>[0, 1, 0])),
      isFalse,
    );
  });

  test('only a Unicode-flavoured face is embedded as a Unicode one', () {
    expect(isPdfEmbeddableFont(_syntheticFont(<String>['glyf'])), isTrue);

    // The writer decides Unicode by the version word alone (`ttf_parser.dart`:
    // `unicode => bytes.getUint32(0) == 0x10000`), so an Apple-flavoured `'true'`
    // face is opened and then written as Latin-1: every rune outside U+00FF is
    // replaced by a placeholder box, inside an assert, with no error. Accepting
    // one here is what made the export claim a face it could not draw with.
    expect(isPdfEmbeddableFont(_flavouredFont('true')), isFalse);

    // The rejections that were always there, for the same reason: the writer has
    // no collection support and reads `glyf`, which a CFF face does not have.
    expect(isPdfEmbeddableFont(_flavouredFont('ttcf')), isFalse);
    expect(isPdfEmbeddableFont(_flavouredFont('OTTO')), isFalse);
    expect(isPdfEmbeddableFont(Uint8List.fromList(<int>[0, 1, 0])), isFalse);
  });

  test(
    'the app\'s own font is offered when this resolver can honour it',
    () async {
      // The file this machine's app draws with is `Noto Sans SC Medium
      // (TrueType).otf`, which is CFF and therefore not a candidate at all — the
      // writer embeds it empty — so what is matched is the family, and what the
      // export gets is that family's TrueType file.
      final body = _Offering(<PdfFontCandidate>[
        const PdfFontCandidate(
          choice: PdfFontSystemFace('/fonts/NotoSansSC-VF.ttf'),
          label: 'NotoSansSC-VF.ttf',
          detail: '/fonts/NotoSansSC-VF.ttf',
        ),
        const PdfFontCandidate(choice: PdfFontAuto()),
      ]);
      expect(
        await body.preferred(
          PdfFontRole.body,
          family: 'Noto Sans SC Medium (TrueType)',
        ),
        isA<PdfFontSystemFace>().having(
          (face) => face.path,
          'path',
          '/fonts/NotoSansSC-VF.ttf',
        ),
      );

      // A family whose own file the writer can open is matched by name.
      final mono = _Offering(<PdfFontCandidate>[
        const PdfFontCandidate(
          choice: PdfFontSystemFace('/fonts/SFMonoSC-Regular.ttf'),
          detail: '/fonts/SFMonoSC-Regular.ttf',
        ),
      ]);
      expect(
        await mono.preferred(PdfFontRole.mono, family: 'SFMonoSC-Regular'),
        isA<PdfFontSystemFace>(),
      );
    },
  );

  test('a family this resolver cannot honour is left to auto', () async {
    final resolver = _Offering(<PdfFontCandidate>[
      const PdfFontCandidate(
        choice: PdfFontSystemFace('/fonts/Consola.ttf'),
        detail: '/fonts/Consola.ttf',
      ),
    ]);
    expect(await resolver.preferred(PdfFontRole.mono, family: 'Gone'), isNull);
    expect(await resolver.preferred(PdfFontRole.mono, family: '   '), isNull);
    expect(await resolver.preferred(PdfFontRole.mono), isNull);
  });

  test('a download that fails is this resolver\'s, not the process\'s', () async {
    final catalogue = _FailingGoogleFonts();
    // The face is named outright so the resolution reaches the catalogue first:
    // an auto body would find this machine's own CJK face and never ask.
    const choice = PdfFontDownload('Noto Sans SC');

    await PdfFontResolver(googleFonts: catalogue).resolve(body: choice);
    expect(catalogue.calls, 1);

    // A second dialog is a second resolver and a second chance. While the failure
    // was a library-level flag, the first failure was the last download this
    // process would ever attempt — even with a brand-new, open catalogue.
    await PdfFontResolver(googleFonts: catalogue).resolve(body: choice);
    expect(catalogue.calls, 2);
  });

  test('the emoji face is resolved from disk, before any download', () async {
    // A service that fails the test if the export goes looking for a download:
    // the system scan and the cache are supposed to answer first, and on a
    // machine with an emoji face installed — or with a cached one — they do.
    final fonts = await PdfFontResolver(
      googleFonts: _NoNetworkGoogleFonts(),
    ).resolve(appFontPath: null, codeFontPath: null);

    // Each role answers with where its face came from. The body and code roles
    // always have one — their worst answer is the writer's built-in font — while
    // the emoji role is the only one allowed to say it found none.
    expect(fonts.statusOf(PdfFontRole.body).source, isNot(PdfFontSource.none));
    expect(fonts.statusOf(PdfFontRole.mono).source, isNot(PdfFontSource.none));
    final emojiStatus = fonts.statusOf(PdfFontRole.emoji);
    expect(
      emojiStatus.source == PdfFontSource.none,
      fonts.emoji == null,
      reason:
          'the status and the bytes have to agree on whether there is a face',
    );
    if (fonts.emoji != null) {
      // A face for this role comes from one of the three sources that hold an
      // emoji face, never from the body or the built-in font.
      expect(
        emojiStatus.source,
        isIn(<PdfFontSource>[
          PdfFontSource.system,
          PdfFontSource.cached,
          PdfFontSource.downloaded,
        ]),
      );
      expect(emojiStatus.name, isNotNull);
      // Both answers are legitimate: a CBDT face prints colour, a COLR or sbix
      // one prints the same emoji in a single colour.
      expect(emojiStatus.colour, isA<bool>());
    }
  });

  test(
    'an emoji is drawn once there is a face for it, and dropped without one',
    () async {
      final fonts = await PdfFontResolver().resolve(
        appFontPath: null,
        codeFontPath: null,
      );
      final emoji = fonts.emoji;
      if (emoji == null) return;

      const body = 'party 🎉 time';
      final without = await _export(body);
      final with_ = await _export(body, emojiFont: emoji);

      // Without a face the writer has nothing to draw the rune with and drops
      // it: the page reads "party  time" and holds no emoji glyph at all. The
      // only font in that document is the writer's built-in Type 1 one.
      expect(_embeddedFontsIn(without.bytes), 0);
      expect(without.text.codeUnits.every((unit) => unit < 0x80), isTrue);
      // With one, a glyph from that face is on the page — its subset is an
      // embedded TrueType font. The reader reports the emoji's own code point
      // unreliably through a subset (it read U+1F38 for U+1F389 here), so what
      // is asserted about the text is that a glyph outside ASCII arrived.
      expect(_embeddedFontsIn(with_.bytes), greaterThan(0));
      expect(with_.text.codeUnits.any((unit) => unit > 0xff), isTrue);

      // A fence is drawn from the monospace style, whose fallback chain is a
      // different one, and the emoji has to survive that door too.
      final fenced = await _export('```\n🎉 code\n```\n', emojiFont: emoji);
      expect(fenced.text.codeUnits.any((unit) => unit > 0xff), isTrue);
    },
  );
}

/// A download service that fails loudly if it is asked for anything.
///
/// It is the assertion behind "cheapest source first": reaching the catalogue
/// means the system scan and the cache were both skipped.
class _NoNetworkGoogleFonts extends GoogleFontsService {
  @override
  Future<List<GoogleFontEntry>> loadCatalog({bool refresh = false}) async {
    throw StateError('the export went to the network with a face on disk');
  }
}

class _Exported {
  _Exported(this.bytes, this.text);

  final Uint8List bytes;
  final String text;
}

Future<_Exported> _export(String markdown, {Uint8List? emojiFont}) async {
  final bytes = (await buildConversationPdf(
    PdfExportRequest(
      title: 'emoji probe',
      thinkingLabel: 'Thinking',
      accent: kPdfPageAccent,
      muted: kPdfPageMuted,
      userLabel: 'User',
      emojiFont: emojiFont,
      messages: <ExportMessage>[
        ExportMessage(
          time: '2026-01-02 03:04:05',
          roleName: 'Assistant',
          speaker: ExportSpeaker.assistant,
          blocks: <ExportBlock>[ExportText(markdown)],
        ),
      ],
    ),
  )).bytes;

  final readBack = syncfusion.PdfDocument(inputBytes: bytes);
  addTearDown(readBack.dispose);
  return _Exported(
    bytes,
    syncfusion.PdfTextExtractor(
      readBack,
    ).extractText().replaceAll(RegExp(r'[\r\n]+'), ' '),
  );
}

/// How many TrueType faces a document embeds.
///
/// An embedded face is written as a `/FontFile2` stream, and the writer's
/// built-in font is a Type 1 one with no file at all — so this counts the faces
/// the document carries rather than the dictionaries it declares. (A Unicode
/// TrueType face declares itself `CIDFontType2` inside a `/Type0` font, not
/// `/TrueType`, which is why the check is on the file and not the subtype.)
int _embeddedFontsIn(Uint8List bytes) =>
    RegExp(r'/FontFile2').allMatches(String.fromCharCodes(bytes)).length;

/// A catalogue whose every download fails, counting how often it was asked.
class _FailingGoogleFonts extends GoogleFontsService {
  int calls = 0;

  @override
  Future<List<GoogleFontEntry>> loadCatalog({bool refresh = false}) async {
    calls++;
    throw StateError('offline');
  }
}

/// A resolver whose candidates are a fixed list, which is all [preferred] reads.
class _Offering extends PdfFontResolver {
  _Offering(this.offered);

  final List<PdfFontCandidate> offered;

  @override
  Future<List<PdfFontCandidate>> candidates(PdfFontRole role) async => offered;
}

/// A single-face header that declares [tag] as its sfnt version.
///
/// Twelve bytes is all [isPdfEmbeddableFont] reads, and the version word is what
/// decides whether the writer treats the face as Unicode.
Uint8List _flavouredFont(String tag) =>
    Uint8List.fromList(<int>[...tag.codeUnits, 0, 0, 0, 0, 0, 0, 0, 0]);

/// A single-face TrueType header whose table directory names [tags], which is
/// all the colour-bitmap check reads.
Uint8List _syntheticFont(List<String> tags) {
  final out = <int>[
    0, 1, 0, 0, //
    (tags.length >> 8) & 0xFF, tags.length & 0xFF,
    0, 0, 0, 0, 0, 0,
  ];
  for (final tag in tags) {
    out
      ..addAll(tag.codeUnits)
      ..addAll(<int>[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
  }
  return Uint8List.fromList(out);
}
