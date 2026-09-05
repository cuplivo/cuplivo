import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/input_status_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/providers/world_book_provider.dart';
import 'package:Cuplivo/features/chat/widgets/bottom_tools_sheet.dart';
import 'package:Cuplivo/features/home/services/input_draft_persistence.dart';
import 'package:Cuplivo/features/home/utils/input_bar_button_layout.dart';
import 'package:Cuplivo/features/home/widgets/chat_input_bar.dart';
import 'package:Cuplivo/icons/lucide_adapter.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';

void main() {
  var businessPrefs = BusinessPreferences.memoryForTests();
  late SharedPreferences prefs;
  InputDraftPersistence? draftPersistence;

  setUp(() async {
    businessPrefs = BusinessPreferences.memoryForTests();
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    draftPersistence = InputDraftPersistence(prefs);
  });

  tearDown(() {
    draftPersistence?.disposeInternal();
    draftPersistence = null;
  });

  Widget buildBar({
    ChatInputBarController? mediaController,
    ChatInputBar? bar,
  }) {
    return MultiProvider(
      providers: [
        Provider<BusinessPreferences>.value(value: businessPrefs),
        Provider<InputDraftPersistence>.value(value: draftPersistence!),
        ChangeNotifierProvider.value(
          value: SettingsProvider(preferences: businessPrefs),
        ),
        ChangeNotifierProvider.value(
          value: AssistantProvider(preferences: businessPrefs),
        ),
        ChangeNotifierProvider.value(value: InputStatusProvider()),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body:
              bar ??
              ChatInputBar(
                controller: TextEditingController(),
                focusNode: FocusNode(),
                mediaController: mediaController,
              ),
        ),
      ),
    );
  }

  double xOf(WidgetTester tester, IconData icon) =>
      tester.getCenter(find.byIcon(icon)).dx;

  testWidgets('custom order renders in saved sequence (tablet row)', (
    tester,
  ) async {
    final mediaController = ChatInputBarController();
    await tester.pumpWidget(
      buildBar(
        mediaController: mediaController,
        bar: ChatInputBar(
          controller: TextEditingController(),
          focusNode: FocusNode(),
          mediaController: mediaController,
          showMoreButton: false,
          inputBarButtonOrder: const [
            inputBarButtonCamera,
            inputBarButtonPhotos,
            inputBarButtonModel,
            inputBarButtonSearch,
          ],
          inputBarMoreIds: const <String>{},
          onPickCamera: () {},
          onPickPhotos: () {},
          onSelectModel: () {},
          onOpenSearch: () {},
        ),
      ),
    );
    await tester.pump();

    // Search renders the default globe when no provider search is active.
    expect(xOf(tester, Lucide.Camera), lessThan(xOf(tester, Lucide.Image)));
    expect(xOf(tester, Lucide.Image), lessThan(xOf(tester, Lucide.Boxes)));
    expect(xOf(tester, Lucide.Boxes), lessThan(xOf(tester, Lucide.Globe)));
  });

  testWidgets('in-more ids are hidden from the tablet row', (tester) async {
    final mediaController = ChatInputBarController();
    await tester.pumpWidget(
      buildBar(
        mediaController: mediaController,
        bar: ChatInputBar(
          controller: TextEditingController(),
          focusNode: FocusNode(),
          mediaController: mediaController,
          showMoreButton: false,
          inputBarButtonOrder: const [
            inputBarButtonModel,
            inputBarButtonCamera,
          ],
          inputBarMoreIds: const {inputBarButtonCamera},
          onPickCamera: () {},
          onSelectModel: () {},
        ),
      ),
    );
    await tester.pump();

    expect(find.byIcon(Lucide.Camera), findsNothing);
    expect(find.byIcon(Lucide.Boxes), findsOneWidget);
  });

  testWidgets('phone layout reports non-fitted direct ids to the sheet merge', (
    tester,
  ) async {
    final mediaController = ChatInputBarController();
    // Narrow surface so direct items cannot all fit.
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      buildBar(
        mediaController: mediaController,
        bar: ChatInputBar(
          controller: TextEditingController(),
          focusNode: FocusNode(),
          mediaController: mediaController,
          inputBarButtonOrder: defaultInputBarButtonIds,
          inputBarMoreIds: const <String>{},
          inputBarCustomized: true,
          showMoreButton: true,
          showDocumentProcessingButton: true,
          showToolsHubButton: true,
          onPickCamera: () {},
          onPickPhotos: () {},
          onUploadFiles: () {},
          onOpenSkills: () {},
          onClearContext: () {},
          onDocumentProcessing: () {},
          onSelectModel: () {},
          onOpenSearch: () {},
          onOpenToolsHub: () {},
        ),
      ),
    );
    await tester.pump();

    // Bucket (right "+") stays visible and overflow ids are exposed.
    expect(mediaController.nonFittedDirectIds, isNotEmpty);
    // The last direct id that could not fit must be reported.
    expect(
      mediaController.nonFittedDirectIds,
      contains(inputBarButtonDocument),
    );
  });

  testWidgets('phone shows exactly one "+" when a row-capable id is in-more', (
    tester,
  ) async {
    final mediaController = ChatInputBarController();
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      buildBar(
        mediaController: mediaController,
        bar: ChatInputBar(
          controller: TextEditingController(),
          focusNode: FocusNode(),
          mediaController: mediaController,
          showMoreButton: true,
          inputBarCustomized: true,
          inputBarButtonOrder: defaultInputBarButtonIds,
          inputBarMoreIds: const {inputBarButtonSearch},
          onOpenSearch: () {},
          onSelectModel: () {},
        ),
      ),
    );
    await tester.pump();

    // The right "+" sheet is the single bucket surface on phone; the left
    // row-end "+" must not appear (ADR-0042: never two "+"s on screen).
    expect(find.byIcon(Lucide.Plus), findsOneWidget);
  });

  testWidgets('bottom sheet renders bucket rows in configured order', (
    tester,
  ) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(
            value: AssistantProvider(preferences: businessPrefs),
          ),
          ChangeNotifierProvider.value(
            value: WorldBookProvider(preferences: businessPrefs),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: BottomToolsSheet(
              moreIds: const [
                inputBarButtonPhotos,
                inputBarButtonCamera,
                inputBarButtonUpload,
                inputBarButtonSkills,
              ],
              onPhotos: () {},
              onCamera: () {},
              onUpload: () {},
              onOpenSkills: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // Grid slots follow the configured order, not a fixed camera-first one.
    expect(
      tester.getCenter(find.byIcon(Lucide.Image)).dx,
      lessThan(tester.getCenter(find.byIcon(Lucide.Camera)).dx),
    );
    expect(
      tester.getCenter(find.byIcon(Lucide.Camera)).dx,
      lessThan(tester.getCenter(find.byIcon(Lucide.Paperclip)).dx),
    );
    // Non-bucketed ids never show.
    expect(find.byIcon(Lucide.Boxes), findsNothing);
    // List rows sit below the grid.
    expect(
      tester.getCenter(find.byIcon(Lucide.Sparkles)).dy,
      greaterThan(tester.getCenter(find.byIcon(Lucide.Paperclip)).dy),
    );
  });

  testWidgets('bottom sheet renders the customize row when bucketed', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    var customizeTapped = false;
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(
            value: AssistantProvider(preferences: businessPrefs),
          ),
          ChangeNotifierProvider.value(
            value: WorldBookProvider(preferences: businessPrefs),
          ),
          ChangeNotifierProvider.value(
            value: SettingsProvider(preferences: businessPrefs),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: BottomToolsSheet(
              moreIds: const [inputBarButtonCustomize],
              onCustomize: () => customizeTapped = true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byIcon(Lucide.Settings2), findsOneWidget);
    await tester.tap(find.byIcon(Lucide.Settings2));
    await tester.pump();
    expect(customizeTapped, isTrue);
  });

  testWidgets(
    'bucket "+" slot is reserved up front — no overflow, no clipping',
    (tester) async {
      final mediaController = ChatInputBarController();
      tester.view.physicalSize = const Size(220, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        buildBar(
          mediaController: mediaController,
          bar: ChatInputBar(
            controller: TextEditingController(),
            focusNode: FocusNode(),
            mediaController: mediaController,
            showMoreButton: false,
            inputBarCustomized: true,
            inputBarButtonOrder: const [
              inputBarButtonModel,
              inputBarButtonSearch,
              inputBarButtonReasoning,
              inputBarButtonTools,
              inputBarButtonQuickPhrase,
            ],
            // Bucket non-empty → the row-end "+" must fit inside maxW.
            inputBarMoreIds: const {inputBarButtonCustomize},
            onSelectModel: () {},
            onOpenSearch: () {},
            onConfigureReasoning: () {},
            showQuickPhraseButton: true,
            onQuickPhrase: () {},
          ),
        ),
      );
      await tester.pump();

      // Old behavior overflowed by a few px here and clipped an item; the
      // fitted row keeps the direct items + the "+" inside the slot.
      expect(tester.takeException(), isNull);
      expect(find.byIcon(Lucide.Plus), findsOneWidget);
    },
  );
}
