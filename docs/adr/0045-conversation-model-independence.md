# ADR-0045: Conversation Model Independence (会话模型独立)

In-chat model switches once wrote to the assistant (`Assistant.chatModel*`)
via `showModelSelectSheet`, so switching in one conversation leaked to every
other conversation of the same assistant and to future assistant settings.
This ADR adds an opt-in mode in which a conversation's model stops
correlating with its assistant's.

## Decision

A user toggle, `conversation_model_independent_v1` (default OFF, Display &
Behavior, SQLite business preference), gates a **conversation model binding**:
two new nullable columns on `conversation_rows`
(`chat_model_provider` / `chat_model_id`, schema v22, mirroring
`Assistant.chatModel*` naming).

- **Effective model chain (toggle-agnostic)**: `convo.chatModel* → assistant
  .chatModel* → global default`. One chain, zero read-side branching; the
  toggle only gates write/creation behavior.
- **Snapshot at creation**: with the toggle ON, new `kindNormal` conversations
  (via `ChatService.createConversation` and `createDraftConversation` —
  handoff, proactive care, and forks all funnel through them) snapshot the
  effective model. Group conversations never bind (per-speaker models rule).
  Unresolvable (both null) stays unbound.
- **Write-target rule**: an in-conversation model switch writes the
  conversation binding when the conversation is bound (regardless of toggle)
  or when the toggle is ON (first switch creates the binding, with a
  one-shot "仅当前会话生效" snackbar); unbound + toggle OFF writes the
  assistant (status quo). The assistant is never touched by in-chat switches
  while the toggle is ON.
- **Sticky**: bindings survive the toggle being switched off. Toggling off
  only stops future snapshots and restores the old write target for
  still-unbound conversations. There is no clearing operation.
- **Coverage**: send, regenerate, and continue-after-tool all resolve
  through the chain (the chat `getModelConfig` call sites), as do the model
  capsule, input-bar image-routing/warning gates, and the model selector's
  preselect. Regenerate follows the chain (not per-message replay) so a
  bound conversation stays on its own model.

## Considered options

- **Retroactive snapshot at toggle-enable** (freeze all existing
  conversations when the toggle flips): rejected — a preference change
  silently mass-mutates chat data, and users enabling the mode for new
  conversations would unintentionally freeze old ones.
- **Nullable override only** (conversation follows the assistant until the
  user first switches): rejected — assistant changes would still leak into
  untouched conversations, breaking direction (b) of the decoupling.
- **Regenerate replays the message's stored model**: rejected — diverges
  from send and would make regenerate out of sync with the conversation's
  chosen model.
- **Toggle OFF clears all bindings**: rejected — destructive and surprising;
  a conversation's model would jump back to the assistant's.

## Capability gates vs assistant-owned configuration

Model-identity capability UI follows the conversation's effective model:
the model icon, reasoning entry visibility (`isReasoningModel`), the
reasoning budget popover's X-high/max option availability, the Tools Hub /
built-in-search tool gates, and image routing/warning gates. Assistant-owned
*configuration* stays assistant-level: the reasoning budget value itself,
MCP/local-tool/workspace/skill bindings, prompt and request parameters —
the binding changes *which model talks*, not the assistant's kit. A bound
conversation therefore shows the affordances of its own model but still
sends with the assistant's request settings.

## Out of scope (unchanged)

Per-speaker group-chat models, Multi-AI engine threads, translation/search/
global-default model selections, the assistant settings page model selector,
title/summary/suggestion/compress/proactive-care model chains (they have
their own dedicated settings), and proactive care's assistant-level send flow.

## Consequences

- New conversations default to OFF behavior; existing conversations never
  bind retroactively.
- `Conversation` is a `??`-pattern `copyWith` model; the new fields are
  nullable and need no clear flag (no clearing UI exists) — the usual
  null-clear trap is intentionally not exposed.
- Backup/restore, LAN sync, and trash recovery round-trip the two fields
  through the existing `Conversation.toJson/fromJson`; old builds ignore
  them on restore; old zips restore with null bindings.
