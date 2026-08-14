enum PlanItemStatus { pending, inProgress, completed, error }

enum PlanPhase { planning, awaitingApproval, executing, completed }

PlanItemStatus planItemStatusFromString(String? value) {
  return switch (value) {
    'in_progress' => PlanItemStatus.inProgress,
    'completed' => PlanItemStatus.completed,
    'error' => PlanItemStatus.error,
    _ => PlanItemStatus.pending,
  };
}

String planItemStatusToString(PlanItemStatus value) {
  return switch (value) {
    PlanItemStatus.pending => 'pending',
    PlanItemStatus.inProgress => 'in_progress',
    PlanItemStatus.completed => 'completed',
    PlanItemStatus.error => 'error',
  };
}

PlanPhase planPhaseFromString(String? value) {
  return switch (value) {
    'awaiting_approval' => PlanPhase.awaitingApproval,
    'executing' => PlanPhase.executing,
    'completed' => PlanPhase.completed,
    _ => PlanPhase.planning,
  };
}

String planPhaseToString(PlanPhase value) {
  return switch (value) {
    PlanPhase.planning => 'planning',
    PlanPhase.awaitingApproval => 'awaiting_approval',
    PlanPhase.executing => 'executing',
    PlanPhase.completed => 'completed',
  };
}

class PlanItem {
  const PlanItem({
    required this.id,
    required this.title,
    required this.description,
    this.status = PlanItemStatus.pending,
  });

  final String id;
  final String title;
  final String description;
  final PlanItemStatus status;

  PlanItem copyWith({
    String? title,
    String? description,
    PlanItemStatus? status,
  }) {
    return PlanItem(
      id: id,
      title: title ?? this.title,
      description: description ?? this.description,
      status: status ?? this.status,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'description': description,
    'status': planItemStatusToString(status),
  };

  factory PlanItem.fromJson(Map<String, dynamic> json) {
    return PlanItem(
      id: (json['id'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      description: (json['description'] ?? '').toString(),
      status: planItemStatusFromString(json['status']?.toString()),
    );
  }
}

class ConversationPlan {
  const ConversationPlan({
    required this.conversationId,
    required this.active,
    required this.phase,
    this.title = '',
    this.items = const <PlanItem>[],
  });

  final String conversationId;
  final bool active;
  final PlanPhase phase;
  final String title;
  final List<PlanItem> items;

  bool get hasPlan => items.isNotEmpty;
  bool get needsInitialPlan => active && items.isEmpty;
  bool get isAwaitingApproval =>
      active && phase == PlanPhase.awaitingApproval && items.isNotEmpty;

  ConversationPlan copyWith({
    bool? active,
    PlanPhase? phase,
    String? title,
    List<PlanItem>? items,
  }) {
    return ConversationPlan(
      conversationId: conversationId,
      active: active ?? this.active,
      phase: phase ?? this.phase,
      title: title ?? this.title,
      items: items ?? this.items,
    );
  }

  Map<String, dynamic> toJson() => {
    'conversationId': conversationId,
    'active': active,
    'phase': planPhaseToString(phase),
    'title': title,
    'items': items.map((e) => e.toJson()).toList(),
  };

  factory ConversationPlan.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'];
    return ConversationPlan(
      conversationId: (json['conversationId'] ?? '').toString(),
      active: json['active'] == true,
      phase: planPhaseFromString(json['phase']?.toString()),
      title: (json['title'] ?? '').toString(),
      items: rawItems is List
          ? rawItems
                .whereType<Map>()
                .map((e) => PlanItem.fromJson(e.cast<String, dynamic>()))
                .where((e) => e.id.isNotEmpty && e.title.isNotEmpty)
                .toList()
          : const <PlanItem>[],
    );
  }
}
