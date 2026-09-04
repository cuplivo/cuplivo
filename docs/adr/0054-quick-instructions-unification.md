# ADR-0054: Unified Quick Instructions with Frozen Invocations and Request-Scoped Tool Restrictions

Status: accepted

Cuplivo previously exposed two overlapping concepts: Quick Phrases inserted editable text into the composer, while Instruction Injections appended reusable prompts to the system message and stored assistant bindings. Supporting user-message placement, one-shot and persistent use, reproducible regeneration, and temporary tool restrictions in either legacy model would duplicate persistence and make activation ownership ambiguous.

## Decision

- **One global definition library**: Quick Phrase and Instruction Injection definitions become one globally managed **Quick Instruction** library. Placement is a property of the definition: system prompt, before user message, after user message, or composer insertion. Legacy data is migrated into this library with deterministic identities and explicit origin suffixes for name collisions.
- **Activation has a placement-specific owner**: system-prompt activation belongs to an assistant, falling back to the global binding when no assistant exists; persistent user-message activation belongs to a conversation; one-shot activation belongs to the next successful send. Composer-insertion items have no activation state.
- **User-message invocations are frozen**: when a send or queue operation accepts an input, every applicable user-message instruction becomes an immutable Invocation Snapshot on that user-message version. Regeneration, continuation, editing, branching, backup, and synchronization operate on the frozen snapshots, so later definition edits or deletion never rewrite history. System-prompt instructions remain live and resolve from the current definition at generation time.
- **History retention is message-owned**: the anchor user message always expands all of its snapshots. A non-anchor message expands only snapshots whose history-retention flag is set. Persistent activation therefore creates a new snapshot on every send and may intentionally repeat in context; truncating, deleting, or branching away from the carrying message removes that historical contribution naturally.
- **Tool restrictions are request-scoped negative permissions**: active system instructions and the current anchor's snapshots may deny local tools, MCP servers, filesystem tools, shell access, or shell commands. They never change the assistant's configured tools. Multiple policies combine monotonically: disabled sets and command block lists form unions, and any block match denies the invocation.
- **Command analysis fails closed**: shell restrictions evaluate the complete Bash command structure, including pipelines, chains, substitutions, redirections, and interpreter `-c` bodies. Incomplete parsing or warning/error diagnostics deny the command. Existing approval and sandbox mechanisms remain independent layers.
- **Mode boundary stays explicit**: user-message Quick Instructions apply only to ordinary chat, Multi-AI, and synthesized-answer flows. Group chat, handoff children, and proactive-care flows can use live system-position instructions but never inherit user-message Invocation Snapshots.

## Consequences

- Historical user turns are reproducible and portable, at the cost of storing full prompt and tool-policy snapshots per invocation.
- Definition deletion or a placement/trigger change must clear future assistant/conversation activation references, while existing message snapshots remain untouched.
- Backup and LAN synchronization retain complete snapshots; human-readable UI, copy, selection, and exports expose only localized name markers and message bodies, never hidden prompt text.
- Legacy backup restoration must invalidate store caches and rerun migration detection. Migration writes and verifies the unified destination before recording a receipt and removing the legacy source; interrupted migration is retryable without duplicates.
- Request policies can only remove capabilities already enabled elsewhere. They cannot grant a tool, bypass approval, weaken sandboxing, or silently mutate durable assistant settings.

## Considered Options

- **Keep two feature models and add cross-links**: rejected because placement, ordering, grouping, migration, and tool policy would still need parallel editors and stores.
- **Store persistent activation on assistants for every placement**: rejected because before/after instructions are conversation intent and would unexpectedly leak across unrelated chats using the same assistant.
- **Resolve user instructions live during regeneration**: rejected because editing or deleting a global definition would retroactively change historical requests and backup restores.
- **Apply historical tool restrictions**: rejected because tool authorization belongs to the current request; replaying a prior turn's restrictions would let distant history unpredictably constrain the anchor.
- **Mutate assistant tool switches while an instruction is active**: rejected because it conflates durable capability configuration with temporary request policy and makes cleanup unsafe.
