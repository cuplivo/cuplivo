import 'package:flutter/widgets.dart';

/// Dispatched by a nested selection owner when its selection becomes non-empty,
/// so the enclosing [SelectionArea] stands its own copy override down.
///
/// A markdown surface nests selectables the framework copies itself — a
/// diagram's `SelectableText`, and on this line a code block's and a table
/// cell's too. Their selections never reach the enclosing area's
/// `onSelectionChanged`, so the area cannot tell "I own the selection" from "I
/// owned one a moment ago".
///
/// That distinction is load-bearing, because the framework's own copy actions
/// are `Action.overridable` (`selectable_region.dart`, `editable_text.dart`):
/// they forward to the nearest ancestor override, which is the area's own
/// [CopySelectionTextIntent] handler. While that override is registered it wins
/// over *any* nested owner, focused or not — so a selection made in a nested
/// owner would copy the area's stale text instead. Reporting the claim is what
/// retires the override, and the framework then copies the nested owner's own
/// text.
class NestedSelectionClaimedNotification extends Notification {
  const NestedSelectionClaimedNotification();
}

/// Lets a nested selection owner report that the selection is no longer the
/// enclosing area's. Does nothing when no area listens above [context].
///
/// Call it from the owner's own selection callback, and only for a selection
/// that carries text — a caret is not a claim.
void reportNestedSelectionClaimed(BuildContext context) {
  const NestedSelectionClaimedNotification().dispatch(context);
}
