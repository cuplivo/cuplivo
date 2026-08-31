import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/home/widgets/conversation_proactive_care_sheet.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/ios_switch.dart';

void main() {
  Future<void> pumpSheet(
    WidgetTester tester, {
    required Conversation conversation,
    required Assistant assistant,
    required Future<void> Function(bool?) onOverrideChanged,
    required Future<void> Function(DateTime?) onNextMessageAtChanged,
  }) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final preferences = BusinessPreferences.memoryForTests();
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => SettingsProvider(preferences: preferences),
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ConversationProactiveCareSheet(
              conversation: conversation,
              assistant: assistant,
              onOverrideChanged: onOverrideChanged,
              onNextMessageAtChanged: onNextMessageAtChanged,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('inherited state toggles explicitly and can restore following', (
    tester,
  ) async {
    final overrides = <bool?>[];
    await pumpSheet(
      tester,
      conversation: Conversation(
        id: 'conversation',
        title: 'Conversation',
        assistantId: 'assistant',
      ),
      assistant: Assistant(
        id: 'assistant',
        name: 'Assistant',
        enableProactiveCare: false,
      ),
      onOverrideChanged: (value) async => overrides.add(value),
      onNextMessageAtChanged: (_) async {},
    );

    final context = tester.element(find.byType(ConversationProactiveCareSheet));
    final l10n = AppLocalizations.of(context)!;
    expect(
      find.text(l10n.conversationProactiveCareFollowingAssistantOff),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('conversation-proactive-care-restore')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('conversation-proactive-care-time')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('conversation-proactive-care-clear-time')),
      findsOneWidget,
    );
    expect(tester.widget<IosSwitch>(find.byType(IosSwitch)).value, isFalse);

    await tester.tap(
      find.byKey(const ValueKey('conversation-proactive-care-switch')),
    );
    await tester.pump();

    expect(overrides, <bool?>[true]);
    expect(tester.widget<IosSwitch>(find.byType(IosSwitch)).value, isTrue);
    expect(find.text(l10n.conversationProactiveCareExplicitOn), findsOneWidget);
    expect(
      find.byKey(const ValueKey('conversation-proactive-care-restore')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey('conversation-proactive-care-restore')),
    );
    await tester.pump();

    expect(overrides, <bool?>[true, null]);
    expect(tester.widget<IosSwitch>(find.byType(IosSwitch)).value, isFalse);
    expect(
      find.text(l10n.conversationProactiveCareFollowingAssistantOff),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('conversation-proactive-care-restore')),
      findsNothing,
    );
  });

  testWidgets('explicit off toggles opposite effective state and time clears', (
    tester,
  ) async {
    final overrides = <bool?>[];
    final times = <DateTime?>[];
    await pumpSheet(
      tester,
      conversation: Conversation(
        id: 'conversation',
        title: 'Conversation',
        assistantId: 'assistant',
        proactiveCareEnabledOverride: false,
        proactiveCareNextMessageAt: DateTime.now().add(
          const Duration(hours: 2),
        ),
      ),
      assistant: Assistant(
        id: 'assistant',
        name: 'Assistant',
        enableProactiveCare: true,
      ),
      onOverrideChanged: (value) async => overrides.add(value),
      onNextMessageAtChanged: (value) async => times.add(value),
    );

    final l10n = AppLocalizations.of(
      tester.element(find.byType(ConversationProactiveCareSheet)),
    )!;
    expect(
      find.text(l10n.conversationProactiveCareExplicitOff),
      findsOneWidget,
    );
    expect(tester.widget<IosSwitch>(find.byType(IosSwitch)).value, isFalse);

    await tester.tap(
      find.byKey(const ValueKey('conversation-proactive-care-switch')),
    );
    await tester.pump();
    expect(overrides, <bool?>[true]);

    await tester.tap(
      find.byKey(const ValueKey('conversation-proactive-care-clear-time')),
    );
    await tester.pump();
    expect(times, <DateTime?>[null]);
    expect(
      find.text(l10n.assistantEditProactiveCareNextMessageTimeUnset),
      findsOneWidget,
    );
  });
}
