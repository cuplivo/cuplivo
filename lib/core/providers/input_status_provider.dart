import 'dart:async';

import 'package:flutter/foundation.dart';

/// Root-level owner of the image-mode / image-warning pill state (issue #307).
///
/// Lifted out of `_ChatInputBarState` so the LivePanel can render the info and
/// warning pills while the input bar keeps using the same state for its image
/// routing (`allowImagesApiRouting`). This is the single source of truth —
/// the input bar reports the raw per-model keys during its build (via
/// `context.read`, so it is never a listener of its own writes), and the
/// LivePanel `watch`es this provider to render the pills.
///
/// Notifications are deferred to a microtask: the input bar reports the keys
/// from inside its own `build`, and a synchronous `notifyListeners` there would
/// mark the ancestor `InheritedProviderScope` dirty mid-build (an assert).
class InputStatusProvider extends ChangeNotifier {
  String? _imageModeModelKey;
  String? _lastImageModeModelKey;
  String? _dismissedImageModeModelKey;
  String? _imageWarningModelKey;
  String? _lastImageWarningModelKey;
  String? _dismissedImageWarningModelKey;
  bool _restoredUnsupportedImagesApiRouting = false;
  String? _restoredUnsupportedConversationId;
  bool _notifyScheduled = false;

  /// True when the current model supports OpenAI image routing and the mode
  /// has not been dismissed for that model (the "Brush" info pill).
  bool get imageModeActive =>
      _imageModeModelKey != null &&
      _imageModeModelKey != _dismissedImageModeModelKey;

  /// True when images are attached to a model that cannot consume them and
  /// OCR is inactive (the "ImageOff" warning pill), not yet dismissed.
  bool get imageWarningActive =>
      _imageWarningModelKey != null &&
      _imageWarningModelKey != _dismissedImageWarningModelKey;

  /// Whether the next send for [conversationId] routes to the OpenAI images
  /// API. Mirrors the previous `_allowImagesApiRouting` input-bar getter: a
  /// one-shot "must not route" flag from queued-input restore overrides
  /// everything. The flag is scoped to the conversation it was set for, so the
  /// home and group-chat input bars (which share this provider) do not clear
  /// each other's flag.
  bool allowImagesApiRoutingFor(String? conversationId) {
    final restoredApplies =
        _restoredUnsupportedImagesApiRouting &&
        _restoredUnsupportedConversationId == conversationId;
    return !restoredApplies &&
        (_imageModeModelKey == null ||
            _imageModeModelKey != _dismissedImageModeModelKey);
  }

  /// Reports the current model's image-mode key (null when unsupported).
  /// Resets the per-model dismissal when the key changes. Called from the
  /// input bar's build; notifies only when an observable value changed.
  void updateImageModeKey(String? key, {String? conversationId}) {
    final beforeActive = imageModeActive;
    final beforeAllow = allowImagesApiRoutingFor(conversationId);
    if (key != _lastImageModeModelKey) {
      _dismissedImageModeModelKey = null;
      _lastImageModeModelKey = key;
    }
    _imageModeModelKey = key;
    if (imageModeActive != beforeActive ||
        allowImagesApiRoutingFor(conversationId) != beforeAllow) {
      _scheduleNotify();
    }
  }

  /// Reports the current model's image-warning key (null when the warning
  /// does not apply). Resets the per-model dismissal when the key changes.
  void updateImageWarningKey(String? key) {
    final before = imageWarningActive;
    if (key != _lastImageWarningModelKey) {
      _dismissedImageWarningModelKey = null;
      _lastImageWarningModelKey = key;
    }
    _imageWarningModelKey = key;
    if (imageWarningActive != before) {
      _scheduleNotify();
    }
  }

  /// Clears the one-shot "must not route" flag for [conversationId] (user
  /// typed a new message, attached images, or sent). A flag belonging to a
  /// different conversation is left untouched.
  void clearRestoredUnsupportedImagesApiRouting(String? conversationId) {
    if (!_restoredUnsupportedImagesApiRouting) return;
    if (_restoredUnsupportedConversationId != conversationId) return;
    _restoredUnsupportedImagesApiRouting = false;
    _restoredUnsupportedConversationId = null;
    _scheduleNotify();
  }

  /// Dismisses the image-mode pill for the current model key.
  void dismissImageMode() {
    if (!imageModeActive) return;
    _dismissedImageModeModelKey = _imageModeModelKey;
    _scheduleNotify();
  }

  /// Dismisses the image-warning pill for the current model key.
  void dismissImageWarning() {
    if (!imageWarningActive) return;
    _dismissedImageWarningModelKey = _imageWarningModelKey;
    _scheduleNotify();
  }

  /// Applies the queued-input restore semantics for image routing: a restored
  /// input that wanted routing but finds no routing model sets the one-shot
  /// "must not route" flag (scoped to [conversationId]); a restored input that
  /// did not want routing dismisses image mode for the current model.
  void restoreAllowImagesApiRouting({
    required bool allow,
    required String? conversationId,
  }) {
    final beforeAllow = allowImagesApiRoutingFor(conversationId);
    final beforeActive = imageModeActive;
    if (allow) {
      if (_imageModeModelKey == null) {
        _restoredUnsupportedImagesApiRouting = true;
        _restoredUnsupportedConversationId = conversationId;
      } else {
        _restoredUnsupportedImagesApiRouting = false;
        _restoredUnsupportedConversationId = null;
        if (_dismissedImageModeModelKey == _imageModeModelKey) {
          _dismissedImageModeModelKey = null;
        }
      }
    } else {
      _restoredUnsupportedImagesApiRouting = false;
      _restoredUnsupportedConversationId = null;
      if (_imageModeModelKey != null) {
        _dismissedImageModeModelKey = _imageModeModelKey;
      }
    }
    if (allowImagesApiRoutingFor(conversationId) != beforeAllow ||
        imageModeActive != beforeActive) {
      _scheduleNotify();
    }
  }

  /// Defers [notifyListeners] to a microtask (coalesced). The input bar calls
  /// the update methods from inside its own build, where a synchronous notify
  /// would mark an ancestor dirty mid-build.
  void _scheduleNotify() {
    if (_notifyScheduled) return;
    _notifyScheduled = true;
    scheduleMicrotask(() {
      _notifyScheduled = false;
      notifyListeners();
    });
  }
}
