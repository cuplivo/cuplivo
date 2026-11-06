import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/group_chat.dart';
import 'package:Cuplivo/features/group_chat/widgets/group_member_cluster.dart';
import 'package:Cuplivo/features/group_chat/widgets/group_member_list.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/home/widgets/assistant_avatar.dart';
import 'package:Cuplivo/icons/lucide_adapter.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../support/business_test_harness.dart';

/// The composer's group identity is one target, not one per avatar: the whole
/// collapsed stack opens the member list, and the list is where a member is
/// edited and the group is configured.
void main() {
  Assistant assistant(String id, String name) =>
      Assistant(id: id, name: name, chatModelProvider: 'p', chatModelId: 'm');

  final members = [
    assistant('a1', 'Alice'),
    assistant('a2', 'Bob'),
    assistant('a3', 'Carol'),
  ];

  GroupChat panel(List<String> memberIds) => GroupChat(
    id: 'g1',
    name: 'Panel',
    memberIds: memberIds,
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026),
  );

  Widget host(Widget child) => ChangeNotifierProvider(
    // The tactile card reads the haptics preference on tap.
    create: (_) => SettingsProvider(createBusinessTestPreferences()),
    child: MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: Center(child: child)),
    ),
  );

  group('cluster', () {
    test('its extent grows with the members it folds in', () {
      // An empty group wears one glyph, so it takes the same single slot as one
      // member: no trailing invite circle is reserved.
      expect(GroupMemberCluster.extentFor(0), GroupMemberCluster.extentFor(1));
      expect(
        GroupMemberCluster.extentFor(1),
        lessThan(GroupMemberCluster.extentFor(3)),
      );
      // Beyond four members the fourth slot becomes a count, so the cluster
      // stops growing and the composer's text row stops shifting.
      expect(GroupMemberCluster.extentFor(4), GroupMemberCluster.extentFor(9));
    });

    testWidgets('one tap on the whole stack opens the member list', (
      tester,
    ) async {
      var taps = 0;
      await tester.pumpWidget(
        host(GroupMemberCluster(members: members, onTap: () => taps++)),
      );
      expect(find.byType(AssistantAvatar), findsNWidgets(3));
      // Two different points of the stack — the left-most face and the last one
      // — are the same control.
      final box = tester.getRect(find.byType(GroupMemberCluster));
      await tester.tapAt(box.centerLeft + const Offset(4, 0));
      expect(taps, 1);
      await tester.tapAt(box.center);
      expect(taps, 2);
    });

    testWidgets('a populated cluster draws no plus of its own', (tester) async {
      // The stack opens the member list; inviting is the first row there. A plus
      // here would promise an action this target does not have.
      await tester.pumpWidget(host(GroupMemberCluster(members: members)));
      expect(find.byIcon(Lucide.Plus), findsNothing);
    });

    testWidgets('more than four members fold into a count', (tester) async {
      final many = [for (var i = 1; i <= 6; i++) assistant('a$i', 'Member $i')];
      await tester.pumpWidget(host(GroupMemberCluster(members: many)));
      expect(find.text('+3'), findsOneWidget);
      expect(find.byType(AssistantAvatar), findsNWidgets(3));
    });

    testWidgets('an empty group wears the group glyph, not an invite plus', (
      tester,
    ) async {
      await tester.pumpWidget(host(const GroupMemberCluster(members: [])));
      expect(find.byType(AssistantAvatar), findsNothing);
      expect(find.byIcon(Lucide.Users), findsOneWidget);
      expect(find.byIcon(Lucide.Plus), findsNothing);
    });
  });

  group('member list', () {
    testWidgets('offers one row per member plus invite and settings', (
      tester,
    ) async {
      var invited = 0;
      var openedSettings = 0;
      await tester.pumpWidget(
        host(
          GroupMemberList(
            group: panel(members.map((member) => member.id).toList()),
            members: members,
            onInvite: () => invited++,
            onOpenSettings: () => openedSettings++,
          ),
        ),
      );
      expect(find.text('Alice'), findsOneWidget);
      expect(find.text('Bob'), findsOneWidget);
      expect(find.text('Carol'), findsOneWidget);

      await tester.tap(find.text('Invite assistants'));
      expect(invited, 1);
      await tester.tap(find.text('Group settings'));
      expect(openedSettings, 1);
    });

    testWidgets('a group without members says so instead of looking broken', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          GroupMemberList(
            group: panel(const []),
            members: const [],
            onInvite: () {},
            onOpenSettings: () {},
          ),
        ),
      );
      expect(find.text('No members yet'), findsOneWidget);
    });
  });

  group('create form', () {
    testWidgets('needs a name and at least one member', (tester) async {
      await tester.pumpWidget(
        host(
          Material(
            child: SizedBox(
              height: 400,
              child: GroupCreateForm(candidates: members),
            ),
          ),
        ),
      );
      final create = find.widgetWithText(FilledButton, 'New group chat');
      expect(tester.widget<FilledButton>(create).onPressed, isNull);

      await tester.enterText(find.byType(TextField), 'Panel');
      await tester.pump();
      expect(tester.widget<FilledButton>(create).onPressed, isNull);

      await tester.tap(find.text('Alice'));
      await tester.pump();
      expect(tester.widget<FilledButton>(create).onPressed, isNotNull);
    });
  });
}
