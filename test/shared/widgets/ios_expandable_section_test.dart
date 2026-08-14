import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/icons/lucide_adapter.dart';
import 'package:Cuplivo/shared/widgets/ios_expandable_section.dart';

/// Harness that mirrors a real caller: owns the expanded state and drives
/// the controlled component through `expanded` + `onToggle`.
class _Harness extends StatefulWidget {
  const _Harness({required this.showDivider, this.initialExpanded = false});

  final bool showDivider;
  final bool initialExpanded;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  late bool _expanded;

  @override
  void initState() {
    super.initState();
    _expanded = widget.initialExpanded;
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: IosExpandableSection(
          icon: Lucide.Wrench,
          title: 'Section title',
          expanded: _expanded,
          showDivider: widget.showDivider,
          onToggle: () => setState(() => _expanded = !_expanded),
          children: const [Text('child A'), Text('child B')],
        ),
      ),
    );
  }
}

/// The body Column inside the section that actually holds the children.
Column _bodyColumn(WidgetTester tester) {
  final columns = tester.widgetList<Column>(
    find.descendant(
      of: find.byType(IosExpandableSection),
      matching: find.byType(Column),
    ),
  );
  return columns.firstWhere(
    (c) => c.children.any((w) => w is Text && w.data == 'child A'),
  );
}

void main() {
  testWidgets('collapsed by default: children hidden, tap fires onToggle', (
    tester,
  ) async {
    await tester.pumpWidget(const _Harness(showDivider: true));

    expect(find.text('Section title'), findsOneWidget);
    expect(find.text('child A'), findsNothing);
    expect(find.text('child B'), findsNothing);

    await tester.tap(find.text('Section title'));
    await tester.pumpAndSettle();

    expect(find.text('child A'), findsOneWidget);
    expect(find.text('child B'), findsOneWidget);
  });

  testWidgets('expanding then collapsing hides the children again', (
    tester,
  ) async {
    await tester.pumpWidget(const _Harness(showDivider: false));

    await tester.tap(find.text('Section title'));
    await tester.pumpAndSettle();
    expect(find.text('child A'), findsOneWidget);

    await tester.tap(find.text('Section title'));
    await tester.pumpAndSettle();
    expect(find.text('child A'), findsNothing);
    expect(find.text('child B'), findsNothing);
  });

  testWidgets('controlled contract: a parent rebuild with expanded: true '
      'renders the children without any tap', (tester) async {
    await tester.pumpWidget(
      const _Harness(showDivider: false, initialExpanded: true),
    );
    await tester.pumpAndSettle();

    expect(find.text('child A'), findsOneWidget);
    expect(find.text('child B'), findsOneWidget);
  });

  testWidgets('showDivider: false (the default) renders no divider between '
      'children', (tester) async {
    await tester.pumpWidget(
      const _Harness(showDivider: false, initialExpanded: true),
    );
    await tester.pumpAndSettle();

    final body = _bodyColumn(tester);
    expect(body.children.whereType<Divider>(), isEmpty);
  });

  testWidgets('showDivider: true inserts exactly one divider between the '
      'children', (tester) async {
    await tester.pumpWidget(const _Harness(showDivider: true));

    // Collapsed: no divider anywhere in the body.
    expect(
      find.descendant(
        of: find.byType(IosExpandableSection),
        matching: find.byType(Divider),
      ),
      findsNothing,
    );

    await tester.tap(find.text('Section title'));
    await tester.pumpAndSettle();

    // The divider sits between child A and child B, not above the first or
    // below the last child.
    final body = _bodyColumn(tester);
    expect(body.children.map((w) => w.runtimeType).toList(), [
      Text,
      Divider,
      Text,
    ]);
  });

  testWidgets('zero children: no crash and onToggle still fires', (
    tester,
  ) async {
    var toggled = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: IosExpandableSection(
            icon: Lucide.Wrench,
            title: 'Empty section',
            expanded: false,
            onToggle: () => toggled = true,
          ),
        ),
      ),
    );

    expect(find.text('Empty section'), findsOneWidget);
    await tester.tap(find.text('Empty section'));
    await tester.pumpAndSettle();
    expect(toggled, isTrue);
    expect(tester.takeException(), isNull);
  });
}
