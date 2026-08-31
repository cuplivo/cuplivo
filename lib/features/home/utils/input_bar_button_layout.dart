/// Input bar button customization layout.
///
/// Mirrors the assistant edit tab layout pattern
/// (`lib/features/assistant/utils/assistant_edit_tab_layout.dart`): the user's
/// saved order wins, missing ids are appended as defaults, and unknown ids are
/// dropped. While nothing is saved (sentinel unset), every platform keeps its
/// legacy split (phone = first 5 direct + rest in the More bucket; tablet /
/// desktop = all direct except newly introduced default-More actions).
library;

const String inputBarButtonModel = 'model';
const String inputBarButtonSearch = 'search';
const String inputBarButtonReasoning = 'reasoning';
const String inputBarButtonTools = 'tools';
const String inputBarButtonQuickPhrase = 'quickPhrase';
const String inputBarButtonCamera = 'camera';
const String inputBarButtonPhotos = 'photos';
const String inputBarButtonUpload = 'upload';
const String inputBarButtonLearning = 'learning';
const String inputBarButtonWorldBook = 'worldBook';
const String inputBarButtonSkills = 'skills';
const String inputBarButtonContext = 'context';
const String inputBarButtonMiniMap = 'miniMap';
const String inputBarButtonDocument = 'document';
const String inputBarButtonProactiveCare = 'proactiveCare';
const String inputBarButtonCustomize = 'customize';

/// Canonical order — matches the hardcoded order the row used before
/// customization existed. The customize button is deliberately LAST and
/// defaults into the More bucket (see [resolveInputBarButtonLayout]).
const List<String> defaultInputBarButtonIds = [
  inputBarButtonModel,
  inputBarButtonSearch,
  inputBarButtonReasoning,
  inputBarButtonTools,
  inputBarButtonQuickPhrase,
  inputBarButtonCamera,
  inputBarButtonPhotos,
  inputBarButtonUpload,
  inputBarButtonLearning,
  inputBarButtonWorldBook,
  inputBarButtonSkills,
  inputBarButtonContext,
  inputBarButtonMiniMap,
  inputBarButtonDocument,
  inputBarButtonProactiveCare,
  inputBarButtonCustomize,
];

/// Phone (narrow layout) legacy direct set when the user never customized.
const List<String> defaultPhoneDirectInputBarButtonIds = [
  inputBarButtonModel,
  inputBarButtonSearch,
  inputBarButtonReasoning,
  inputBarButtonTools,
  inputBarButtonQuickPhrase,
];

/// Tablet/desktop bucket when the user never customized. Newly introduced
/// opt-in actions and customize default into More for discoverability.
const List<String> defaultTabletMoreInputBarButtonIds = [
  inputBarButtonProactiveCare,
  inputBarButtonCustomize,
];

/// Saved order wins; defaults appended for ids the user never touched;
/// unknown ids dropped.
List<String> orderedInputBarButtonIds({required List<String> savedOrder}) {
  final validIds = defaultInputBarButtonIds.toSet();
  final seen = <String>{};
  final result = <String>[];
  for (final id in savedOrder) {
    if (validIds.contains(id) && seen.add(id)) result.add(id);
  }
  for (final id in defaultInputBarButtonIds) {
    if (seen.add(id)) result.add(id);
  }
  return List.unmodifiable(result);
}

/// Resolved platform layout: the full 15-button order plus the ids tucked into
/// the platform More bucket.
class InputBarButtonLayout {
  const InputBarButtonLayout({required this.orderedIds, required this.moreIds});

  /// Full order across all canonical ids (saved order first, defaults appended).
  final List<String> orderedIds;

  /// Ids tucked into the platform More bucket.
  final Set<String> moreIds;
}

InputBarButtonLayout resolveInputBarButtonLayout({
  required List<String> savedOrder,
  required List<String> savedMoreIds,
  required bool tabletLayout,
}) {
  final ordered = orderedInputBarButtonIds(savedOrder: savedOrder);
  final Set<String> more;
  if (savedOrder.isEmpty && savedMoreIds.isEmpty) {
    more = tabletLayout
        // Tablet legacy = all direct except the customize entry (see
        // defaultTabletMoreInputBarButtonIds).
        ? defaultTabletMoreInputBarButtonIds.toSet()
        : defaultInputBarButtonIds
              .where((id) => !defaultPhoneDirectInputBarButtonIds.contains(id))
              .toSet();
  } else {
    final moreSet = savedMoreIds.toSet();
    more = ordered.where(moreSet.contains).toSet();
    // New actions appended to an existing customized order start in More.
    // Once present in the saved order, savedMoreIds is the explicit choice.
    if (!savedOrder.contains(inputBarButtonProactiveCare)) {
      more.add(inputBarButtonProactiveCare);
    }
  }
  return InputBarButtonLayout(orderedIds: ordered, moreIds: more);
}
