import 'package:flutter/foundation.dart';

import '../../../core/memory/memory_strategy.dart';
import '../../../core/models/assistant.dart';

/// View model for the 3-layer memory settings page.
///
/// Bridges the persisted [Assistant] config to the page's local state so the
/// page never has to re-implement the round-trip logic. The page can ignore
/// persistence concerns and just call [apply] on the helper it gets.
class SettingMemoryViewModel extends ChangeNotifier {
  SettingMemoryViewModel({required this.initialAssistant})
      : _draft = initialAssistant.copyWith();

  final Assistant initialAssistant;
  Assistant _draft;

  Assistant get draft => _draft;

  /// The preset that matches the current draft, or `null` if the user has
  /// edited any of the four numeric fields to a non-preset value.
  MemoryStrategy? get activeStrategy => detectStrategy(_draft);

  /// Set the master 3-layer switch.
  void setThreeLayerEnabled(bool value) {
    if (_draft.enableThreeLayerMemory == value) return;
    _draft = _draft.copyWith(enableThreeLayerMemory: value);
    notifyListeners();
  }

  /// Set the cross-window switch.
  void setCrossWindowEnabled(bool value) {
    if (_draft.enableCrossWindowMemory == value) return;
    _draft = _draft.copyWith(enableCrossWindowMemory: value);
    notifyListeners();
  }

  /// Set the cross-window compression switch.
  void setCompressionEnabled(bool value) {
    if (_draft.enableCrossWindowMemoryCompression == value) return;
    _draft = _draft.copyWith(enableCrossWindowMemoryCompression: value);
    notifyListeners();
  }

  /// Set the recent-chats-as-fallback switch.
  void setRecentChatsFallbackEnabled(bool value) {
    if (_draft.useRecentChatsAsFallback == value) return;
    _draft = _draft.copyWith(useRecentChatsAsFallback: value);
    notifyListeners();
  }

  /// Apply one of the three [MemoryStrategy] presets. Picking a preset is
  /// a one-shot opt-in — it also enables the 3-layer + cross-window +
  /// compression switches so the preset has effect without the user
  /// separately turning each one on.
  void applyPreset(MemoryStrategy strategy) {
    _draft = applyStrategy(_draft, strategy);
    notifyListeners();
  }

  void setCompressionThresholdChars(int value) {
    final clamped = value.clamp(1000, 200000);
    if (_draft.crossWindowMemoryCompressionThresholdChars == clamped) return;
    _draft =
        _draft.copyWith(crossWindowMemoryCompressionThresholdChars: clamped);
    notifyListeners();
  }

  void setCompressionTailEntries(int value) {
    final clamped = value.clamp(1, 200);
    if (_draft.crossWindowMemoryTailEntries == clamped) return;
    _draft = _draft.copyWith(crossWindowMemoryTailEntries: clamped);
    notifyListeners();
  }

  void setRecallCount(int value) {
    final clamped = value.clamp(1, 50);
    if (_draft.longTermMemoryRecallCount == clamped) return;
    _draft = _draft.copyWith(longTermMemoryRecallCount: clamped);
    notifyListeners();
  }

  void setLongTermMaxChars(int value) {
    final clamped = value.clamp(200, 50000);
    if (_draft.longTermMemoryMaxChars == clamped) return;
    _draft = _draft.copyWith(longTermMemoryMaxChars: clamped);
    notifyListeners();
  }

  /// Returns the draft if the user changed anything, otherwise `null`. The
  /// caller is expected to persist via `AssistantProvider.updateAssistant`.
  Assistant? buildUpdate() {
    if (identical(_draft, initialAssistant)) return null;
    if (_draft.toJson().toString() == initialAssistant.toJson().toString()) {
      return null;
    }
    return _draft;
  }
}
