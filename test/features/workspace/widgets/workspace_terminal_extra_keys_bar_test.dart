import 'package:Cuplivo/core/services/workspace/terminal_extra_keys.dart';
import 'package:Cuplivo/features/workspace/widgets/workspace_terminal_extra_keys_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('CTRL tap arms the modifier', (tester) async {
    final controller = TerminalExtraKeysController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WorkspaceTerminalExtraKeysBar(
            controller: controller,
            onEmit: (_, {required popup}) {},
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('workspace-terminal-key-CTRL')));
    await tester.pump();
    expect(controller.ctrl, ExtraKeyModifierState.armed);
  });

  testWidgets('minus swipe up emits popup pipe', (tester) async {
    final emitted = <({String id, bool popup})>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WorkspaceTerminalExtraKeysBar(
            controller: TerminalExtraKeysController(),
            onEmit: (key, {required popup}) {
              emitted.add((id: key.id, popup: popup));
            },
          ),
        ),
      ),
    );
    final center = tester.getCenter(
      find.byKey(const ValueKey('workspace-terminal-key--')),
    );
    final gesture = await tester.startGesture(center);
    await tester.pump();
    await gesture.moveBy(const Offset(0, -40));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(emitted, [(id: '-', popup: true)]);
  });

  testWidgets('extra keys expose semantics labels', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WorkspaceTerminalExtraKeysBar(
            controller: TerminalExtraKeysController(),
            onEmit: (_, {required popup}) {},
          ),
        ),
      ),
    );
    expect(
      tester.getSemantics(
        find.byKey(const ValueKey('workspace-terminal-key-ESC')),
      ),
      matchesSemantics(
        label: 'ESC',
        isButton: true,
        hasSelectedState: true,
        isSelected: false,
      ),
    );
    handle.dispose();
  });
}
