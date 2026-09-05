import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/streaming_content_notifier.dart';
import 'package:Cuplivo/features/chat/widgets/chat_message_widget.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../../support/business_test_harness.dart';

void main() {
  testWidgets(
    'retry countdown renders and announces the correct placeholder order '
    '("{seconds}s until retry ({attempt}/{maxRetries})")',
    (tester) async {
      final settings = await createBusinessTestPreferences();
      addTearDown(settings.dispose);

      await tester.pumpWidget(
        ChangeNotifierProvider<SettingsProvider>.value(
          value: settings,
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: StatusInjectingMessage(),
          ),
        ),
      );

      // A few frames only: the 5s tween must stay at its begin value; do NOT
      // pumpAndSettle (that advances the countdown to zero).
      await tester.pump(const Duration(milliseconds: 10));
      await tester.pump(const Duration(milliseconds: 10));

      // Rendered countdown: 5s until retry (1/3) — args passed as
      // (attempt, maxRetries, seconds) matching the generated l10n signature.
      expect(find.text('5s until retry (1/3)'), findsOneWidget);
      // Accessibility announcement uses the same string (and the same
      // argument order) on the wrapping Semantics node.
      final sem = tester.widget<Semantics>(
        find
            .ancestor(
              of: find.text('5s until retry (1/3)'),
              matching: find.byType(Semantics),
            )
            .first,
      );
      expect(sem.properties.label, '5s until retry (1/3)');
    },
  );
}

/// Injects the live [RetryStatus] into an otherwise minimal streaming message
/// (RetryStatus holds a mutable DateTime, so the outer tree stays const).
class StatusInjectingMessage extends StatefulWidget {
  const StatusInjectingMessage({super.key});

  @override
  State<StatusInjectingMessage> createState() => _StatusInjectingMessageState();
}

class _StatusInjectingMessageState extends State<StatusInjectingMessage> {
  late final RetryStatus _status = RetryStatus(
    attempt: 1,
    maxRetries: 3,
    retryAt: DateTime.now().add(const Duration(seconds: 5)),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SingleChildScrollView(
        child: ChatMessageWidget(
          message: ChatMessage(
            role: 'assistant',
            content: '',
            conversationId: 'c1',
            isStreaming: true,
          ),
          retryStatus: _status,
        ),
      ),
    );
  }
}
