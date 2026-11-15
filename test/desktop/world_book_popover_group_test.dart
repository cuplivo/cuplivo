// A group's panels edit one member at a time: the strip says whose picks the
// rows below are, and a tap writes through the same call the 1:1 panel makes for
// its single assistant. This is the world book's copy of that contract; the
// instruction-injection and skills popovers share it.
import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/world_book.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/world_book_provider.dart';
import 'package:Cuplivo/desktop/world_book_popover.dart';
import 'package:Cuplivo/features/group_chat/widgets/group_member_strip.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../support/business_test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BusinessPreferences preferences;
  late AssistantProvider assistants;
  late WorldBookProvider books;

  const alice = Assistant(id: 'a1', name: 'Alice');
  const bob = Assistant(id: 'a2', name: 'Bob');

  setUp(() async {
    preferences = createBusinessTestPreferences();
    await preferences.load();
    await preferences.setString(
      'assistants_v1',
      Assistant.encodeList(const [alice, bob]),
    );
    await preferences.setString('current_assistant_id_v1', alice.id);
    assistants = AssistantProvider(preferences: preferences);
    await assistants.loaded;
    books = WorldBookProvider(preferences: preferences);
  });

  Future<void> openPopover(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.runAsync(() async {
      await books.initialize();
      await books.addBook(const WorldBook(id: 'wb1', name: 'Lore'));
    });

    final anchorKey = GlobalKey();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<BusinessPreferences>.value(value: preferences),
          ChangeNotifierProvider<AssistantProvider>.value(value: assistants),
          ChangeNotifierProvider<WorldBookProvider>.value(value: books),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => Stack(
                children: [
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: TextButton(
                      onPressed: () => showDesktopWorldBookPopover(
                        context,
                        anchorKey: anchorKey,
                        books: books.books,
                        assistantId: alice.id,
                        members: const [alice, bob],
                      ),
                      child: const Text('open'),
                    ),
                  ),
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    child: SizedBox(key: anchorKey, height: 24),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  /// Taps a row and lets the provider's write settle: the row commits through
  /// the provider's store, which is a real future rather than a frame.
  Future<void> tapAndSettleWrite(WidgetTester tester, Finder row) async {
    await tester.tap(row);
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }

  testWidgets('the strip starts on the composer assistant and writes for it', (
    tester,
  ) async {
    await openPopover(tester);

    expect(find.byType(GroupMemberStrip), findsOneWidget);

    // Alice is the composer's assistant, so she starts selected: picking a book
    // writes her list, exactly as the 1:1 popover would.
    await tapAndSettleWrite(tester, find.text('Lore'));

    expect(books.isBookActive('wb1', assistantId: alice.id), isTrue);
    expect(books.isBookActive('wb1', assistantId: bob.id), isFalse);
  });

  testWidgets('picking the other chip moves the write to that member', (
    tester,
  ) async {
    await openPopover(tester);

    await tester.tap(find.byKey(GroupMemberStrip.chipKey(bob.id)));
    await tester.pump();
    await tapAndSettleWrite(tester, find.text('Lore'));

    expect(books.isBookActive('wb1', assistantId: bob.id), isTrue);
    expect(books.isBookActive('wb1', assistantId: alice.id), isFalse);
  });
}
