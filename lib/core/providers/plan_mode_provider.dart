import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/plan_mode.dart';

enum PlanApprovalDecision { approved, rejected }

/// Conversation-scoped Plan Mode state.
///
/// Plan state is persisted separately from chat rows so the feature can evolve
/// without a database migration. Pending approval completers are intentionally
/// process-local: if the app/process is restarted, the persisted plan remains
/// visible but no stale generation is resumed automatically.
class PlanModeProvider extends ChangeNotifier {
  static const _prefsKey = 'plan_mode_by_conversation_v1';

  final Map<String, ConversationPlan> _plans = <String, ConversationPlan>{};
  final Map<String, Completer<PlanApprovalDecision>> _approvalWaiters =
      <String, Completer<PlanApprovalDecision>>{};
  bool _initialized = false;
  bool _initializing = false;
  Completer<void>? _initializationCompleter;

  bool get initialized => _initialized;

  Future<void> initialize() async {
    if (_initialized) return;
    if (_initializing) {
      await _initializationCompleter?.future;
      return;
    }
    _initializing = true;
    final completer = Completer<void>();
    _initializationCompleter = completer;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw != null && raw.trim().isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            if (entry.value is! Map) continue;
            final value = Map<String, dynamic>.from(entry.value as Map);
            value['conversationId'] = entry.key.toString();
            var plan = ConversationPlan.fromJson(value);
            if (plan.phase == PlanPhase.awaitingApproval) {
              plan = plan.copyWith(phase: PlanPhase.planning);
            }
            if (plan.conversationId.isNotEmpty) {
              _plans[plan.conversationId] = plan;
            }
          }
        }
      }
      _initialized = true;
      notifyListeners();
    } catch (e) {
      debugPrint('[PlanMode] initialize failed: $e');
      _initialized = true;
    } finally {
      _initializing = false;
      if (!completer.isCompleted) completer.complete();
      if (identical(_initializationCompleter, completer)) {
        _initializationCompleter = null;
      }
    }
  }

  ConversationPlan? planFor(String? conversationId) {
    if (conversationId == null || conversationId.isEmpty) return null;
    return _plans[conversationId];
  }

  bool isActive(String? conversationId) =>
      planFor(conversationId)?.active == true;

  bool needsInitialPlan(String? conversationId) =>
      planFor(conversationId)?.needsInitialPlan == true;

  bool hasPendingApproval(String? conversationId) {
    if (conversationId == null) return false;
    return _approvalWaiters.containsKey(conversationId);
  }

  Future<void> setActive(String conversationId, bool active) async {
    if (conversationId.isEmpty) return;
    await initialize();
    final current = _plans[conversationId];
    if (!active) {
      rejectPendingApproval(conversationId);
      if (current == null) return;
      _plans[conversationId] = current.copyWith(active: false);
    } else if (current == null) {
      _plans[conversationId] = ConversationPlan(
        conversationId: conversationId,
        active: true,
        phase: PlanPhase.planning,
      );
    } else {
      _plans[conversationId] = current.copyWith(active: true);
    }
    notifyListeners();
    await _persist();
  }

  Future<void> clearPlan(String conversationId) async {
    await initialize();
    rejectPendingApproval(conversationId);
    _plans.remove(conversationId);
    notifyListeners();
    await _persist();
  }

  String _newItemId(String conversationId, int index) {
    final micros = DateTime.now().microsecondsSinceEpoch;
    return 'plan_${conversationId.hashCode.abs()}_${micros}_$index';
  }

  Future<ConversationPlan> createOrReplacePlan({
    required String conversationId,
    required String title,
    required List<({String title, String description})> items,
    bool awaitingApproval = true,
  }) async {
    final normalized = <PlanItem>[];
    for (var i = 0; i < items.length; i++) {
      final itemTitle = items[i].title.trim();
      if (itemTitle.isEmpty) continue;
      normalized.add(
        PlanItem(
          id: _newItemId(conversationId, i),
          title: itemTitle,
          description: items[i].description.trim(),
        ),
      );
    }
    final plan = ConversationPlan(
      conversationId: conversationId,
      active: true,
      phase: awaitingApproval
          ? PlanPhase.awaitingApproval
          : PlanPhase.planning,
      title: title.trim(),
      items: normalized,
    );
    _plans[conversationId] = plan;
    notifyListeners();
    await _persist();
    return plan;
  }

  Future<ConversationPlan?> updateItem({
    required String conversationId,
    required String itemId,
    String? title,
    String? description,
    bool requireApproval = false,
  }) async {
    final current = _plans[conversationId];
    if (current == null) return null;
    final next = current.items
        .map(
          (item) => item.id == itemId
              ? item.copyWith(
                  title: title?.trim().isNotEmpty == true ? title!.trim() : null,
                  description: description?.trim(),
                )
              : item,
        )
        .toList();
    final plan = current.copyWith(
      items: next,
      phase: requireApproval ? PlanPhase.planning : current.phase,
    );
    _plans[conversationId] = plan;
    notifyListeners();
    await _persist();
    return plan;
  }

  Future<ConversationPlan?> setItemStatus({
    required String conversationId,
    required String itemId,
    required PlanItemStatus status,
  }) async {
    final current = _plans[conversationId];
    if (current == null) return null;
    final next = current.items
        .map((item) {
          if (item.id == itemId) return item.copyWith(status: status);
          if (status == PlanItemStatus.inProgress &&
              item.status == PlanItemStatus.inProgress) {
            return item.copyWith(status: PlanItemStatus.pending);
          }
          return item;
        })
        .toList();
    final allCompleted = next.isNotEmpty &&
        next.every((item) => item.status == PlanItemStatus.completed);
    final plan = current.copyWith(
      items: next,
      phase: allCompleted ? PlanPhase.completed : PlanPhase.executing,
    );
    _plans[conversationId] = plan;
    notifyListeners();
    await _persist();
    return plan;
  }

  Future<ConversationPlan?> addItem({
    required String conversationId,
    required String title,
    required String description,
    int? afterIndex,
    bool requireApproval = false,
  }) async {
    final current = _plans[conversationId];
    if (current == null) return null;
    final next = List<PlanItem>.of(current.items);
    final item = PlanItem(
      id: _newItemId(conversationId, next.length),
      title: title.trim(),
      description: description.trim(),
    );
    final insertAt = afterIndex == null
        ? next.length
        : (afterIndex + 1).clamp(0, next.length);
    next.insert(insertAt, item);
    final plan = current.copyWith(
      items: next,
      phase: requireApproval ? PlanPhase.planning : current.phase,
    );
    _plans[conversationId] = plan;
    notifyListeners();
    await _persist();
    return plan;
  }

  Future<ConversationPlan?> removeItem({
    required String conversationId,
    required String itemId,
    bool requireApproval = false,
  }) async {
    final current = _plans[conversationId];
    if (current == null) return null;
    final next = current.items.where((item) => item.id != itemId).toList();
    final plan = current.copyWith(
      items: next,
      phase: requireApproval ? PlanPhase.planning : current.phase,
    );
    _plans[conversationId] = plan;
    notifyListeners();
    await _persist();
    return plan;
  }

  Future<void> markAwaitingApproval(String conversationId) async {
    final current = _plans[conversationId];
    if (current == null || current.items.isEmpty) return;
    _plans[conversationId] = current.copyWith(
      active: true,
      phase: PlanPhase.awaitingApproval,
    );
    notifyListeners();
    await _persist();
  }

  Future<PlanApprovalDecision> waitForApproval(String conversationId) async {
    final old = _approvalWaiters.remove(conversationId);
    if (old != null && !old.isCompleted) {
      old.complete(PlanApprovalDecision.rejected);
    }
    final completer = Completer<PlanApprovalDecision>();
    _approvalWaiters[conversationId] = completer;
    notifyListeners();
    final decision = await completer.future;
    if (identical(_approvalWaiters[conversationId], completer)) {
      _approvalWaiters.remove(conversationId);
    }
    notifyListeners();
    return decision;
  }

  Future<void> approve(String conversationId) async {
    final current = _plans[conversationId];
    if (current != null) {
      _plans[conversationId] = current.copyWith(
        active: true,
        phase: PlanPhase.executing,
      );
      await _persist();
    }
    final waiter = _approvalWaiters.remove(conversationId);
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete(PlanApprovalDecision.approved);
    }
    notifyListeners();
  }

  Future<void> reject(String conversationId) async {
    final current = _plans[conversationId];
    if (current != null) {
      _plans[conversationId] = current.copyWith(
        active: true,
        phase: PlanPhase.planning,
      );
      await _persist();
    }
    final waiter = _approvalWaiters.remove(conversationId);
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete(PlanApprovalDecision.rejected);
    }
    notifyListeners();
  }

  void rejectPendingApproval(String conversationId) {
    final waiter = _approvalWaiters.remove(conversationId);
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete(PlanApprovalDecision.rejected);
    }
    notifyListeners();
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final body = <String, dynamic>{
        for (final entry in _plans.entries) entry.key: entry.value.toJson(),
      };
      await prefs.setString(_prefsKey, jsonEncode(body));
    } catch (e) {
      debugPrint('[PlanMode] persist failed: $e');
    }
  }
}
