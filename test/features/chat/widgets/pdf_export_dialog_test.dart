import 'dart:async';
import 'dart:typed_data';

import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/services/fonts/google_fonts_service.dart';
import 'package:Cuplivo/features/chat/utils/markdown_pdf_emitter.dart';
import 'package:Cuplivo/features/chat/utils/pdf_export_fonts.dart';
import 'package:Cuplivo/features/chat/utils/pdf_export_options.dart';
import 'package:Cuplivo/features/chat/widgets/pdf_export_dialog.dart';
import 'package:Cuplivo/features/chat/widgets/pdf_font_picker.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:provider/provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/providers/settings_provider.dart';

import '../../../support/business_test_harness.dart';

/// The export dialog: what it shows, what it asks for, and what it does with the
/// answer.
///
/// A resolver and a runner are substituted, so the test never enumerates this
/// machine's fonts, never downloads, and never opens a save dialog.
void main() {
  tearDown(() {
    pdfExportSessionOptions = PdfExportOptions();
  });

  testWidgets('the dialog names the face each role resolved to', (
    tester,
  ) async {
    final resolver = _FakeResolver(_faces(emojiColour: false));
    await _open(tester, resolver: resolver);

    expect(find.text('Body font'), findsOneWidget);
    expect(find.text('Deng.ttf'), findsOneWidget);
    expect(find.text('consola.ttf'), findsOneWidget);
    // The emoji row says which kind of emoji face it is: that is the difference
    // between colour and monochrome on the page.
    expect(find.text('seguiemj.ttf · Monochrome'), findsOneWidget);
    // Opening asks what is on disk and does not go to the network to find out.
    expect(resolver.resolves, 1);
    expect(resolver.downloads, 0);
  });

  testWidgets('a colour emoji face is named as one', (tester) async {
    await _open(tester, resolver: _FakeResolver(_faces(emojiColour: true)));
    expect(find.text('NotoColorEmoji.ttf · Colour'), findsOneWidget);
  });

  testWidgets('the body font falling back to the built-in one is stated', (
    tester,
  ) async {
    final resolver = _FakeResolver(const {
      PdfFontRole.body: PdfFontStatus(PdfFontSource.builtIn),
      PdfFontRole.mono: PdfFontStatus(PdfFontSource.body, name: 'Deng.ttf'),
      PdfFontRole.emoji: PdfFontStatus(PdfFontSource.none),
    });
    await _open(tester, resolver: resolver);

    expect(find.text('Built-in font'), findsOneWidget);
    expect(find.text('Not embedded'), findsOneWidget);
    // The one thing a reader has to know before exporting: CJK will be blank.
    expect(
      find.text('No embeddable CJK font was found; CJK text may print blank.'),
      findsOneWidget,
    );
  });

  testWidgets('the check asks the network, and only the check does', (
    tester,
  ) async {
    final resolver = _FakeResolver(_faces());
    await _open(tester, resolver: resolver);
    expect(resolver.downloads, 0);

    await tester.tap(find.text('Check fonts'));
    await tester.pumpAndSettle();

    expect(resolver.resolves, 2);
    expect(resolver.downloads, 1);
    expect(find.text('Check fonts'), findsOneWidget);
  });

  testWidgets('a chosen face is exported with, and remembered for the session', (
    tester,
  ) async {
    final resolver = _FakeResolver(_faces(), offered: _candidates());
    PdfExportOptions? used;
    await _open(
      tester,
      resolver: resolver,
      thinking: true,
      run:
          (
            context, {
            required conversation,
            required messages,
            required options,
            googleFonts,
            resolver,
          }) async {
            used = options;
            return _result();
          },
    );

    // The switch the export menu showed is the one the dialog starts with.
    expect(pdfExportSessionOptions.showThinkingAndToolCards, isTrue);
    expect(find.text('Show Deep Thinking and tool cards'), findsOneWidget);

    await tester.tap(find.text('Body font'));
    await tester.pumpAndSettle();
    expect(find.text('Automatic'), findsOneWidget);
    await tester.tap(find.text('simhei.ttf'));
    await tester.pumpAndSettle();

    // Picking a face resolves again — offline — and the row names the new one.
    expect(find.text('simhei.ttf'), findsOneWidget);
    expect(resolver.downloads, 0);

    await tester.tap(find.text('Export PDF').last);
    await tester.pumpAndSettle();

    expect(used, same(pdfExportSessionOptions));
    expect(
      used!.body,
      isA<PdfFontSystemFace>().having(
        (choice) => choice.path,
        'path',
        endsWith('simhei.ttf'),
      ),
    );
    expect(find.text('Export complete'), findsOneWidget);
    expect(find.text('42 pages · 2.0 MB'), findsOneWidget);
    // One formula and one picture: two things the export could not draw.
    expect(find.text('2 item(s) not fully exported'), findsOneWidget);
    expect(find.text('1 formula(s) shown as plain text'), findsOneWidget);
    expect(
      find.text(
        '1 image(s) could not be read and are shown as their reference',
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('Export complete'), findsNothing);
  });

  testWidgets('a cancelled save reports nothing at all', (tester) async {
    await _open(
      tester,
      resolver: _FakeResolver(_faces()),
      run:
          (
            context, {
            required conversation,
            required messages,
            required options,
            googleFonts,
            resolver,
          }) async => null,
    );
    await tester.tap(find.text('Export PDF').last);
    await tester.pumpAndSettle();
    expect(find.text('Export complete'), findsNothing);
    // And the dialog it came from is gone rather than left behind the save.
    expect(find.text('Body font'), findsNothing);
  });

  testWidgets('starts the export only once the options have left the screen', (
    tester,
  ) async {
    final gate = Completer<void>();
    var surfaceStillUp = true;
    await _open(
      tester,
      resolver: _FakeResolver(_faces()),
      run:
          (
            context, {
            required conversation,
            required messages,
            required options,
            googleFonts,
            resolver,
          }) async {
            // The moment the export starts is the moment a reader stops seeing the
            // configuration: the overlay and the save dialog are raised from the
            // page, and a dialog still sliding out behind them is what reads as one
            // that never closed.
            surfaceStillUp = find.text('Body font').evaluate().isNotEmpty;
            await gate.future;
            return _result();
          },
    );

    await tester.tap(find.text('Export PDF').last);
    await tester.pumpAndSettle();
    await tester.pump();

    // The export is under way — its runner is holding — and nothing of the dialog
    // is on screen.
    expect(surfaceStillUp, isFalse);
    expect(find.text('Body font'), findsNothing);
    expect(find.text('Export PDF'), findsNothing);

    gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('Export complete'), findsOneWidget);
  });

  testWidgets('reports an export that outlives the dialog it was asked from', (
    tester,
  ) async {
    final gate = Completer<void>();
    var mountedAfterwards = false;
    await _open(
      tester,
      resolver: _FakeResolver(_faces()),
      run:
          (
            context, {
            required conversation,
            required messages,
            required options,
            googleFonts,
            resolver,
          }) async {
            // A real export takes seconds, and every surface it raises — the
            // progress overlay, the save dialog, the result — is the page's. A run
            // launched from the dialog's own context would find it disposed here,
            // and the result would never be shown.
            await gate.future;
            mountedAfterwards = context.mounted;
            return _result();
          },
    );

    await tester.tap(find.text('Export PDF').last);
    await tester.pumpAndSettle();
    gate.complete();
    await tester.pumpAndSettle();

    expect(mountedAfterwards, isTrue);
    expect(find.text('Export complete'), findsOneWidget);
    expect(find.text('42 pages · 2.0 MB'), findsOneWidget);
  });

  testWidgets('an export with nothing to report says only the size', (
    tester,
  ) async {
    await _open(
      tester,
      resolver: _FakeResolver(_faces()),
      run:
          (
            context, {
            required conversation,
            required messages,
            required options,
            googleFonts,
            resolver,
          }) async => PdfExportResult(
            bytes: Uint8List(1024),
            pages: 1,
            degradedMath: const <String>[],
            degradedDiagrams: const <String>[],
            undrawnImages: const <String>[],
          ),
    );
    await tester.tap(find.text('Export PDF').last);
    await tester.pumpAndSettle();
    expect(find.text('1 pages · 1 KB'), findsOneWidget);
    expect(find.textContaining('not fully exported'), findsNothing);
  });

  testWidgets('the catalogue outlives the export that downloads from it', (
    tester,
  ) async {
    final catalogue = _SpyCatalogue();
    final gate = Completer<void>();
    final closedWhenRunStarted = <bool>[];
    GoogleFontsService? handedOver;

    await _open(
      tester,
      resolver: _FakeResolver(_faces()),
      createCatalogue: () => catalogue,
      run:
          (
            context, {
            required conversation,
            required messages,
            required options,
            googleFonts,
            resolver,
          }) async {
            closedWhenRunStarted.add(catalogue.closed);
            handedOver = googleFonts;
            await gate.future;
            return _result();
          },
    );

    await tester.tap(find.text('Export PDF').last);
    await tester.pumpAndSettle();

    // The export runs from the page, after this route is gone — so the service it
    // downloads from has to still be open when it starts. The dialog's own
    // `finally` used to close it as soon as the route popped, which is before
    // `run` is called: every download then failed, and the failure was permanent.
    expect(closedWhenRunStarted, <bool>[false]);
    expect(identical(handedOver, catalogue), isTrue);
    expect(catalogue.closed, isFalse);

    gate.complete();
    await tester.pumpAndSettle();
    // The export's own surfaces — the result dialog among them — are part of the
    // export, so the catalogue is held until they are done with too.
    expect(catalogue.closed, isFalse);

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(catalogue.closed, isTrue);
  });

  testWidgets('a dialog dismissed without exporting closes its own catalogue', (
    tester,
  ) async {
    final catalogue = _SpyCatalogue();
    await _open(
      tester,
      resolver: _FakeResolver(_faces()),
      createCatalogue: () => catalogue,
    );
    expect(catalogue.closed, isFalse);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // Nothing claimed it, so the dialog is the one still responsible for it.
    expect(catalogue.closed, isTrue);
  });

  testWidgets('opens with the faces the app itself is drawn with', (
    tester,
  ) async {
    // The page is meant to look like the screen, so the first dialog of a session
    // offers the screen's own faces rather than whatever the resolver would reach
    // for — and matching the family is the resolver's job, which is why this only
    // supplies what it can honour.
    final resolver = _FakeResolver(
      _faces(),
      offered: <PdfFontCandidate>[
        const PdfFontCandidate(
          choice: PdfFontSystemFace('/fonts/NotoSansSC-VF.ttf'),
          label: 'NotoSansSC-VF.ttf',
          detail: '/fonts/NotoSansSC-VF.ttf',
        ),
      ],
    );
    await _open(
      tester,
      resolver: resolver,
      appFontFamily: 'Noto Sans SC Medium (TrueType)',
    );

    expect(
      pdfExportSessionOptions.body,
      isA<PdfFontSystemFace>().having(
        (face) => face.path,
        'path',
        '/fonts/NotoSansSC-VF.ttf',
      ),
    );
  });

  testWidgets('a face the user chose is not seeded over', (tester) async {
    const chosen = PdfFontSystemFace('/fonts/chosen.ttf');
    pdfExportSessionOptions.body = chosen;
    await _open(
      tester,
      resolver: _FakeResolver(
        _faces(),
        offered: <PdfFontCandidate>[
          const PdfFontCandidate(
            choice: PdfFontSystemFace('/fonts/NotoSansSC-VF.ttf'),
            detail: '/fonts/NotoSansSC-VF.ttf',
          ),
        ],
      ),
      appFontFamily: 'Noto Sans SC Medium (TrueType)',
    );
    expect(pdfExportSessionOptions.body, same(chosen));

    // And a session that has already been offered them keeps what it has: picking
    // automatic is a choice too.
    pdfExportSessionOptions.body = const PdfFontAuto();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await _open(
      tester,
      resolver: _FakeResolver(
        _faces(),
        offered: <PdfFontCandidate>[
          const PdfFontCandidate(
            choice: PdfFontSystemFace('/fonts/NotoSansSC-VF.ttf'),
            detail: '/fonts/NotoSansSC-VF.ttf',
          ),
        ],
      ),
      appFontFamily: 'Noto Sans SC Medium (TrueType)',
    );
    expect(pdfExportSessionOptions.body, isA<PdfFontAuto>());
  });

  testWidgets('a family this resolver cannot honour leaves the role alone', (
    tester,
  ) async {
    await _open(
      tester,
      resolver: _FakeResolver(_faces(), offered: const <PdfFontCandidate>[]),
      appFontFamily: 'Gone',
    );
    expect(pdfExportSessionOptions.body, isA<PdfFontAuto>());
  });

  testWidgets('the picker offers what the resolver can honour', (tester) async {
    final resolver = _FakeResolver(_faces(), offered: _candidates());
    PdfFontChoice? picked;
    _tallSurface(tester);
    await tester.pumpWidget(
      _app(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                picked = await showPdfFontPicker(
                  context,
                  role: PdfFontRole.body,
                  current: const PdfFontAuto(),
                  resolver: resolver,
                );
              },
              child: const Text('pick'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('pick'));
    await tester.pumpAndSettle();

    expect(find.text('Automatic'), findsOneWidget);
    expect(find.text('System fonts'), findsOneWidget);
    expect(find.text('Download'), findsOneWidget);
    expect(find.text('Other'), findsOneWidget);
    expect(find.text('Deng.ttf'), findsOneWidget);
    // Both the machine's faces carry the note; the download does not need it.
    expect(find.text('Includes CJK'), findsNWidgets(2));
    expect(find.text('Noto Sans SC'), findsOneWidget);
    expect(find.text('Embeds no font; CJK prints blank'), findsOneWidget);

    await tester.tap(find.text('simhei.ttf'));
    await tester.pumpAndSettle();
    expect(picked, isA<PdfFontSystemFace>());
  });

  testWidgets('a font list that cannot be read says so instead of spinning', (
    tester,
  ) async {
    final resolver = _FakeResolver(
      _faces(),
      candidatesError: StateError('no font directory'),
    );
    _tallSurface(tester);
    await tester.pumpWidget(
      _app(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showPdfFontPicker(
                context,
                role: PdfFontRole.body,
                current: const PdfFontAuto(),
                resolver: resolver,
              ),
              child: const Text('pick'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('pick'));
    await tester.pumpAndSettle();

    // The failure state has to be reachable: it used to sit behind a check for
    // "still loading", so a load that threw spun for ever.
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Could not read the font list'), findsOneWidget);
  });
}

Map<PdfFontRole, PdfFontStatus> _faces({bool emojiColour = false}) => {
  PdfFontRole.body: const PdfFontStatus(PdfFontSource.system, name: 'Deng.ttf'),
  PdfFontRole.mono: const PdfFontStatus(
    PdfFontSource.system,
    name: 'consola.ttf',
  ),
  PdfFontRole.emoji: PdfFontStatus(
    PdfFontSource.system,
    name: emojiColour ? 'NotoColorEmoji.ttf' : 'seguiemj.ttf',
    colour: emojiColour,
  ),
};

List<PdfFontCandidate> _candidates() => const <PdfFontCandidate>[
  PdfFontCandidate(choice: PdfFontAuto()),
  PdfFontCandidate(
    choice: PdfFontSystemFace('/fonts/Deng.ttf'),
    label: 'Deng.ttf',
    note: PdfFontNote.cjk,
  ),
  PdfFontCandidate(
    choice: PdfFontSystemFace('/fonts/simhei.ttf'),
    label: 'simhei.ttf',
    note: PdfFontNote.cjk,
  ),
  PdfFontCandidate(
    choice: PdfFontDownload('Noto Sans SC'),
    label: 'Noto Sans SC',
  ),
  PdfFontCandidate(choice: PdfFontBuiltIn()),
];

PdfExportResult _result() => PdfExportResult(
  bytes: Uint8List(2 * 1024 * 1024),
  pages: 42,
  degradedMath: const <String>['x'],
  degradedDiagrams: const <String>[],
  undrawnImages: const <String>['a.png'],
);

Future<void> _open(
  WidgetTester tester, {
  required PdfFontResolver resolver,
  PdfExportRunner? run,
  bool thinking = false,
  String? appFontFamily,
  String? codeFontFamily,
  GoogleFontsService Function()? createCatalogue,
}) async {
  _tallSurface(tester);
  await tester.pumpWidget(
    _app(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showPdfExportDialog(
              context,
              conversation: Conversation(id: 'c', title: 'a chat'),
              messages: const <ChatMessage>[],
              showThinkingAndToolCards: thinking,
              expandThinkingContent: false,
              resolver: resolver,
              run: run,
              appFontFamily: appFontFamily,
              codeFontFamily: codeFontFamily,
              createCatalogue: createCatalogue,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

/// A catalogue that records the one thing the dialog is responsible for: when it
/// is closed relative to the export that downloads from it.
class _SpyCatalogue extends GoogleFontsService {
  bool closed = false;

  @override
  void close() {
    closed = true;
  }
}

/// A resolver that answers from a table and counts what it was asked to do.
class _FakeResolver extends PdfFontResolver {
  _FakeResolver(
    this.status, {
    List<PdfFontCandidate>? offered,
    this.candidatesError,
  }) : offered = offered ?? const <PdfFontCandidate>[];

  final Map<PdfFontRole, PdfFontStatus> status;
  final List<PdfFontCandidate> offered;

  /// What [candidates] throws, when the list itself is what is under test.
  final Object? candidatesError;

  /// How many times a resolution ran, and how many of those were allowed to
  /// reach the network. The second number is the whole point of the peek pass.
  int resolves = 0;
  int downloads = 0;

  @override
  Future<PdfExportFonts> resolve({
    PdfFontChoice body = const PdfFontAuto(),
    PdfFontChoice mono = const PdfFontAuto(),
    PdfFontChoice emoji = const PdfFontAuto(),
    String? appFontPath,
    String? codeFontPath,
    bool allowDownload = true,
  }) async {
    resolves++;
    if (allowDownload) downloads++;
    // A face named outright is the face that is used — that is the one thing the
    // dialog has to get right, so the fake honours it the way the real resolver
    // does rather than answering from its table.
    final bodyStatus = body is PdfFontSystemFace
        ? PdfFontStatus(PdfFontSource.picked, name: body.path.split('/').last)
        : status[PdfFontRole.body] ?? const PdfFontStatus(PdfFontSource.none);
    return PdfExportFonts(
      body: allowDownload ? Uint8List.fromList(<int>[0, 1, 0, 0]) : null,
      mono: null,
      emoji: null,
      status: <PdfFontRole, PdfFontStatus>{
        ...status,
        PdfFontRole.body: bodyStatus,
      },
    );
  }

  @override
  Future<List<PdfFontCandidate>> candidates(PdfFontRole role) async {
    if (candidatesError != null) throw candidatesError!;
    return offered;
  }
}

/// A shell with the providers the settings-style rows read: [IosCardPress]
/// consults the haptics setting when it is pressed, and [SectionCard] reads the
/// layered-tile setting when it paints.
Widget _app({required Widget home}) => ChangeNotifierProvider<SettingsProvider>(
  create: (_) => SettingsProvider(createBusinessTestPreferences()),
  child: MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: home,
  ),
);

/// A surface tall enough for the whole dialog.
///
/// The default 800×600 test window is shorter than this form, and a row that is
/// clipped away is one `tester.tap` cannot reach — which would make a passing test
/// say nothing about the row it tapped.
void _tallSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1000, 1800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}
