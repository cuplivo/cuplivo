import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// Adds the one mouse pointer a test may own, so cursor resolution runs.
///
/// A second `addPointer` for device 1 inside the same test trips
/// MouseTracker's PointerAdded/PointerRemoved assertion, so add a single
/// pointer per test and move it with [hoverAt].
Future<TestGesture> addMousePointer(WidgetTester tester) async {
  final mouse = await tester.createGesture(kind: ui.PointerDeviceKind.mouse);
  await mouse.addPointer(location: Offset.zero);
  addTearDown(mouse.removePointer);
  await tester.pump();
  return mouse;
}

/// Moves [mouse] onto [target] so the cursor is re-resolved.
Future<void> hoverAt(
  WidgetTester tester,
  TestGesture mouse,
  Offset target,
) async {
  await mouse.moveTo(target);
  await tester.pump();
}

/// The cursor the tracker currently shows; a mouse pointer is device 1
/// (flutter_test's `TestPointer` hard-codes device 1 for mouse pointers).
MouseCursor? activeMouseCursor() =>
    RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1);
