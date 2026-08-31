# ADR-0053: Conversation-Owned Proactive Care Schedules

Ta的来信 remains an Android-only assistant capability, but its enablement and next delivery time are now resolved per conversation. The assistant switch is only a default: each fixed-assistant normal conversation may follow it or explicitly enable/disable the feature, while the conversation's next time is the sole live schedule and always targets that same conversation. This avoids the previous surprising behavior where one assistant-level alarm selected whichever conversation happened to be newest at delivery time.

## Decisions

- A conversation override has three states: follow the assistant default, explicitly enabled, or explicitly disabled. Returning to follow is an explicit user action.
- Enabling never invents a time. Normal conversation activity may ask the decision model for one, and users may edit or clear it directly.
- Disabling cancels delivery but retains the time. Past unconsumed times remain visible and are never caught up automatically.
- A fired schedule is atomically consumed before generation. Foreground and killed-process execution both append only to the owning conversation; they never select or create another conversation.
- Model and manual time writes use completion-order last-write-wins. A keep decision performs no write.
- Existing future assistant schedules migrate once to that assistant's newest normal conversation. Copying one time to every conversation was rejected because it would multiply deliveries after upgrade.
- Runtime permissions are application-wide Android readiness, not assistant or conversation state. Feature switches never request them; users act through explicit settings rows.
- The input action is globally customizable but deliberately defaults to the More bucket, including when first appended to an existing saved layout. This is a narrow exception to ADR-0042's default-direct rule.

## Consequences

This supersedes ADR-0031's assistant-owned pending filter and alarm identity while preserving its startup re-arm and always-on logging decisions. Group chats, conversations without a fixed assistant, and temporary chats remain ineligible. Ordinary unsaved drafts may hold settings in memory, but cannot arm an alarm until their first message persists the conversation.
