/// Narrow view over the list controller that the tool-extent coordinator
/// drives.
///
/// The coordinator must inspect whether the controller is attached or layout
/// locked when a height event arrives, and invalidate a slot once it can.
/// A production port wraps the real `ListController`; tests inject a
/// controllable view through [MessageListView.toolExtentPort] so the
/// detached/lock windows — which the framework never exposes between frames —
/// can be driven deterministically. The seam itself is marked
/// `@visibleForTesting` on the widget parameter; this type is consumed by
/// production code (the default wrapper) and therefore stays public.
abstract class ToolExtentInvalidationPort {
  bool get isAttached;

  bool get isLocked;

  (int, int)? get visibleRange;

  void invalidateExtent(int index);
}
