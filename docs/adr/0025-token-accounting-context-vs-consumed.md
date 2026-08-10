# Token accounting: dual context-vs-consumed semantics

Multi-round tool-call turns undercounted token usage: every provider max-merged per-round `usage` across rounds (correct only for within-stream cumulative snapshots), so the stored message fields reflected the last request instead of the turn's billed total — multi-round consumption was invisible in the message token display and the Stats page (issue #235).

We now store **both** quantities on `ChatMessage`, with distinct consumers:

- **Consumed semantics (sum across rounds)** — `promptTokens` / `completionTokens` / `cachedTokens` / `totalTokens`. What was actually billed. Consumed by the Stats aggregation and the token-detail popup. Providers fold each completed round into a `consumedUsage` accumulator (`TokenUsage.sum` / `TokenUsage.accumulate`) at round boundaries and reset the round-local `usage`; the consumer replaces (last-wins) on both `chunk.usage` and `chunk.consumedUsage`.
- **Context semantics (last round)** — the new `contextTokens` column (schema v17, added to the schema self-heal set). The context the model had at the end of the turn, shown by the bottom-right token display (`contextTokens ?? totalTokens` for legacy rows). Streaming is naturally continuous because the live value is the current round's cumulative.

Schema note: the column was originally designated schema v16, but an unrelated group-chat v16 landed on master in parallel (colliding version numbers with complementary columns). The merged schema is **v17**: the upgrade step idempotently adds both columns, so users upgrading from either v16 variant land the other branch's column.

`TokenUsage.merge` remains max-semantics and is used only within a single request's stream.

Rejected alternatives: (a) single sum semantics everywhere — the corner number would inflate ~k× for tool turns and lose the context quick-read, with a visible jump at stream finish; (b) single context semantics everywhere — the Stats page would keep undercounting multi-round turns, leaving #235 unfixed. The two consumers need different values, and neither is derivable from the other after the fact, so both are persisted.

Consequences: legacy rows keep pre-v16 context-ish values (Stats sums them as an approximation; the corner display falls back to `totalTokens`, so history renders unchanged). The detail popup's tok/s now averages over the whole turn's completion output. No ARB changes.
