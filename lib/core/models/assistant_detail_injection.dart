/// Where/when assistant roster details are injected into the director context.
enum AssistantDetailInjectionMode {
  beforeSystemPrompt,
  appendIntoSystemPrompt,
  endOfFirstUserMessage,
  endOfEveryUserMessage,
  endOfEveryUserAndAssistantMessage,
  everyNUserMessages,
  everyNUserAndAssistantMessages,
}

extension AssistantDetailInjectionModeX on AssistantDetailInjectionMode {
  String get storageValue => name;

  bool get needsN =>
      this == AssistantDetailInjectionMode.everyNUserMessages ||
      this == AssistantDetailInjectionMode.everyNUserAndAssistantMessages;

  static AssistantDetailInjectionMode fromStorage(String? raw) {
    if (raw == null || raw.isEmpty) {
      return AssistantDetailInjectionMode.endOfEveryUserMessage;
    }
    for (final v in AssistantDetailInjectionMode.values) {
      if (v.name == raw) return v;
    }
    return AssistantDetailInjectionMode.endOfEveryUserMessage;
  }
}
