import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/desktop/widgets/desktop_select_dropdown.dart';

void _useDesktopSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

class _Harness extends StatefulWidget {
  const _Harness({super.key});

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  String _value = 'a';
  bool _withBeta = true;

  void removeBeta() => setState(() => _withBeta = false);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: DesktopSelectDropdown<String>(
            value: _value,
            options: [
              const DesktopSelectOption(
                value: 'a',
                label: 'Alpha',
                leading: 'A',
              ),
              if (_withBeta)
                const DesktopSelectOption(value: 'b', label: 'Beta'),
            ],
            onSelected: (v) => setState(() => _value = v),
            triggerFillColor: Colors.white,
            menuBackgroundColor: Colors.white,
            footer: const Text('Manage'),
            focusable: true,
            semanticLabel: 'Target language',
          ),
        ),
      ),
    );
  }
}

void main() {
  testWidgets('dropdown options render optional subtitles', (tester) async {
    _useDesktopSurface(tester);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: DesktopSelectDropdown<String>(
              value: 'a',
              options: const [
                DesktopSelectOption(
                  value: 'a',
                  label: 'Always global',
                  subtitle: 'New memories are shared with every assistant',
                ),
                DesktopSelectOption(
                  value: 'b',
                  label: 'Always this assistant',
                  subtitle: 'New memories stay private to this assistant',
                ),
              ],
              onSelected: (_) {},
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(DesktopSelectDropdown<String>));
    await tester.pumpAndSettle();

    expect(
      find.text('New memories are shared with every assistant'),
      findsOneWidget,
    );
    expect(
      find.text('New memories stay private to this assistant'),
      findsOneWidget,
    );
  });

  testWidgets('selecting an option updates the trigger and closes the menu', (
    tester,
  ) async {
    _useDesktopSurface(tester);
    await tester.pumpWidget(const _Harness());
    expect(find.text('Alpha'), findsOneWidget);

    await tester.tap(find.text('Alpha'));
    await tester.pumpAndSettle();
    expect(find.text('Manage'), findsOneWidget);

    await tester.tap(find.text('Beta'));
    await tester.pumpAndSettle();
    expect(find.text('Beta'), findsOneWidget);
    expect(find.text('Manage'), findsNothing);
  });

  testWidgets('open menu refreshes when options change underneath', (
    tester,
  ) async {
    _useDesktopSurface(tester);
    final key = GlobalKey<_HarnessState>();
    await tester.pumpWidget(_Harness(key: key));

    await tester.tap(find.text('Alpha'));
    await tester.pumpAndSettle();
    expect(find.text('Beta'), findsOneWidget);

    key.currentState!.removeBeta();
    await tester.pumpAndSettle();
    expect(find.text('Beta'), findsNothing);
  });

  testWidgets('Enter opens the menu and Escape closes it', (tester) async {
    _useDesktopSurface(tester);
    await tester.pumpWidget(const _Harness());

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('Manage'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Manage'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Escape with a focused tile closes without a focus error', (
    tester,
  ) async {
    _useDesktopSurface(tester);
    await tester.pumpWidget(const _Harness());

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.text('Manage'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('arrow keys move focus between options', (tester) async {
    _useDesktopSurface(tester);
    await tester.pumpWidget(const _Harness());

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    // First Down lands on Alpha, second on Beta; Enter activates Beta.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(find.text('Beta'), findsOneWidget);
    expect(find.text('Manage'), findsNothing);
  });
}
