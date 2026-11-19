import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/features/harness/models/dsh_remote.dart';
import 'package:Cuplivo/features/harness/state/dsh_gateway.dart';
import 'package:Cuplivo/features/harness/widgets/dsh_owner_card.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';

void main() {
  Widget host(Widget child) => MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: child),
  );

  DshRemote remote({String name = 'Studio'}) => DshRemote(
    id: 'r1',
    name: name,
    baseUrl: 'http://192.168.1.20:3080',
    authority: '192.168.1.20:3080',
    secure: false,
    createdAt: DateTime.utc(2026, 11, 19),
  );

  testWidgets('the card shows the remote name and the remote subtitle', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        DshOwnerCard(
          key: const Key('dsh-owner-card'),
          remote: remote(),
          subtitle: 'DeepSeek Harness over a remote connection',
          status: const DshLinkStatus.ready(),
          onTap: () {},
        ),
      ),
    );
    expect(find.text('Studio'), findsOneWidget);
    expect(
      find.text('DeepSeek Harness over a remote connection'),
      findsOneWidget,
    );
  });

  testWidgets('an unnamed remote falls back to the product name', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        DshOwnerCard(
          remote: remote(name: '   '),
          subtitle: 'DeepSeek Harness over a remote connection',
          onTap: () {},
        ),
      ),
    );
    expect(find.text('DeepSeek Harness'), findsOneWidget);
  });

  testWidgets('tapping the card opens the assistant page', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      host(
        DshOwnerCard(
          key: const Key('dsh-owner-card'),
          remote: remote(),
          subtitle: 'DeepSeek Harness over a remote connection',
          onTap: () => taps++,
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('dsh-owner-card')));
    expect(taps, 1);
  });
}
