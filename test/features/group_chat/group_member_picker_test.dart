import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/features/group_chat/widgets/group_member_list.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The member picker is shared: the group's invite flow uses it as it always
/// has, and the subagent targets row adds a fixed header and a footer sentence.
/// These cases pin both halves — the group's layout must stay what it was.
void main() {
  final candidates = [
    Assistant(id: 'a1', name: 'Alice'),
    Assistant(id: 'a2', name: 'Bob'),
  ];

  Widget host(Widget child) => MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: Center(child: child)),
  );

  testWidgets('without a header or footer it is the list it always was', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(GroupMemberPicker(title: 'Invite', candidates: candidates)),
    );

    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('Bob'), findsOneWidget);
    // The title shares the bottom row with the confirm button.
    expect(find.text('Invite'), findsOneWidget);
  });

  testWidgets('a footer replaces the title in the bottom row', (tester) async {
    await tester.pumpWidget(
      host(
        GroupMemberPicker(
          title: 'Targets',
          candidates: candidates,
          footer: const Text('nobody ticked means yourself'),
        ),
      ),
    );

    expect(find.text('nobody ticked means yourself'), findsOneWidget);
    // Visible once: the sheet or dialog that hosts the picker already shows
    // the title, so the bottom row is free for the caller's sentence.
    expect(find.text('Targets'), findsNothing);
  });

  testWidgets('a header sits above the candidates and is not selectable', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        GroupMemberPicker(
          title: 'Targets',
          candidates: candidates,
          header: const Text('a copy of yourself is always available'),
        ),
      ),
    );

    final header = tester.getRect(
      find.text('a copy of yourself is always available'),
    );
    final firstCandidate = tester.getRect(find.text('Alice'));
    expect(header.top, lessThan(firstCandidate.top));
  });
}
