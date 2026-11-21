/// The bounds the LAN sync feature's pieces impose on each other.
///
/// A limit that only its own module knows about is a limit nobody can check
/// against the one beside it. The endpoint cap and the listener's probe cap were
/// chosen in separate files, and the first was raised past the second without
/// anything noticing: one peer's whole fan-out then tripped the listener's own
/// `ping_busy` refusal, which the probe correctly reads as "no verdict" — so the
/// feature disabled its own measurements, silently, for the address set it had
/// just grown to support.
///
/// Every bound another bound depends on therefore lives here, and the ones that
/// depend on [kMaxPeerEndpoints] are *derived* from it rather than restated, so
/// raising the memory of addresses cannot reintroduce that contradiction. The
/// relationships are asserted in `test/core/services/sync/sync_limits_test.dart`
/// and by the prober's own concurrency test.
library;

/// How many endpoints a peer record remembers. Bounded because the set is
/// learned (the pairing QR's candidates plus the address every session is seen
/// at), and a stale address only costs one failed connect before the next
/// candidate is tried.
///
/// Twelve, not six, because the set is a memory of *(device, network)* pairs:
/// an office, a home and a phone hotspot, each of which can hold a couple of
/// interfaces. The periodic probe is tiered, so a longer memory costs no extra
/// steady-state traffic — the tick follows the addresses that answered, and the
/// tail is only walked when they all go silent.
const int kMaxPeerEndpoints = 12;

/// How many liveness probes one listener answers at once. Past this the probe
/// route refuses with 503 `ping_busy`, which the caller reads as "not now"
/// rather than as a verdict about the address.
///
/// Derived from the endpoint cap with headroom, and the headroom is *spare*
/// rather than reserved: the probing side never has more than
/// [kSyncProbeConcurrency] in flight, because one device-wide pool hands out
/// every probe of every round ([kSyncProbeConcurrency], and the pool in
/// `sync_endpoint_prober.dart`). The two used to be unequal in practice — the
/// cap was per *round*, and a tick runs one round per peer concurrently plus
/// whatever round a session starts — so this number was a wish about a fan-out
/// that could stack on itself.
const int kMaxPingsInFlight = kMaxPeerEndpoints + 2;

/// How many endpoints this device probes at once — the fan-out budget, shared
/// by both probe paths (the periodic tick and a session whose snapshot went
/// stale) **and by every peer**, through the one device-wide pool.
///
/// Equal to the endpoint cap so a peer's whole address memory is one wave: the
/// round's wait is then the slowest answer, not the sum of the chunks, which
/// is the property the parallel probe exists for. It is a *budget*, not a
/// wish: a set larger than this (a future cap, a caller that passed a bigger
/// one, two peers' rounds at once) is chunked or queued rather than fanned out,
/// so this file stays the single authority on how much probing this device does
/// at once — and the pool is what makes that true of the device.
const int kSyncProbeConcurrency = kMaxPeerEndpoints;

/// How many blobs one push acknowledgement may ask the initiator to push
/// (slice 24).
///
/// The list is peer input, and every entry costs the initiator more than a map
/// lookup: a hash it did not publish this session falls through to the asset
/// registry (a query) and to a full scan of the local skill directories. The
/// *workspace* request list needs no such bound — a pair is a lookup in the
/// table the peer itself advertised, which its own walk already caps.
///
/// A list past this is **truncated, not refused**: the entries that fall off
/// stay in the receiver's pending set and are asked for again next session, so
/// the failure mode is a slower convergence rather than a lost blob.
const int kMaxBlobRequestsPerSession = 2048;

/// How many addresses a responder tries when it has to dial the initiator back
/// to pull a file from it.
///
/// Three, not twelve: every candidate costs a connect budget before the next is
/// tried, and this dial sits inside the peer's push beat, where the initiator is
/// waiting. The observed address and the two most likely advertised ones cover
/// the real cases (one address that works, one NAT'd memory, one other network);
/// what a miss costs is a file that waits for the push fallback instead.
const int kMaxReverseDialCandidates = 3;

/// How many pairing requests one listener answers at once.
///
/// The pairing route is the one face that answers before any authentication, so
/// it cannot share the data lanes: a stranger who fills it would otherwise hold
/// the write lane — and pairing is *the* route a user reaches for when the pair
/// is broken. Past this cap the caller is answered 503 `pair_busy`, the same
/// refusal language `ping_busy` uses, because it says the same thing ("this
/// listener is loaded"), which the caller can act on.
///
/// Four, and deliberately **not** derived from [kMaxPeerEndpoints]: pairing is
/// bounded by a human standing in front of two devices — one pairing at a time,
/// plus a double-tap and a retry — while the endpoint cap is a memory of
/// networks. Tying the two together would invent a relationship neither has,
/// and the last bound that was derived from a wish is why this file exists.
const int kMaxPairRequestsInFlight = 4;

// ---- workspace content ----

/// How many files one managed workspace may carry into a sync (ADR-0003 slice
/// 18): 2,000 files. A workspace past it is not transferred at all, and the
/// panel says so.
const int kMaxWorkspaceFiles = 2000;

/// How many bytes one managed workspace may carry into a sync: 200 MB. Same
/// rule as the file cap — past it, nothing rides.
const int kMaxWorkspaceBytes = 200 * 1024 * 1024;

/// How many file entries one peer's table may hold — both the ledger in the
/// checkpoint and the table a session advertises.
///
/// The ledger is the "both sides agreed on this" record; an entry it does not
/// hold only ever makes the plan conservative (offer or fetch again, never
/// delete), so what the cap costs past this bound is a re-transfer, not data.
///
/// The *table* is not conservative in the same way, and this number decides
/// both: a shared workspace that does not fit is dropped from the advertisement
/// entirely, and the peer reads its absence as "no opinion" — it plans nothing,
/// nothing transfers, and no report field names it. That is why the drop is
/// counted where the tables are built (`tablesOf`) and why the bound is
/// *computed* from the per-workspace cap rather than written as a round number:
/// the two have to agree, so raising [kMaxWorkspaceFiles] has to raise this, and
/// ten workspaces' worth is the largest table the drop rule is expected to
/// represent.
const int kMaxWorkspaceLedgerEntries = 10 * kMaxWorkspaceFiles;

// ---- one push's bytes ----

/// The largest `/sync/*` JSON body this side accepts, counted after
/// decompression (`sync_server.dart`, `_readJson`). A body past it answers 413,
/// and a 413 fails the whole round while the next round rebuilds the same
/// body — so this is the number past which a pair stops converging.
///
/// It lives here rather than beside the server because the client's budget is
/// *derived* from it: the two have to agree, and a cap only the server knows is
/// how a sender ends up building a body the other side refuses.
const int kSyncMaxBodyBytes = 256 * 1024 * 1024;

/// The share of [kSyncMaxBodyBytes] one push may use: 60%. The rest is
/// headroom, and it is not slack for the batch's content — the body is
/// *measured* before it is built (`sync_budget.dart`), so its content cannot
/// exceed the budget. It is what the send path itself needs and no budget can
/// see: the batch's row maps, the JSON text, its UTF-8 buffer and the gzip
/// buffer are all alive before a byte reaches the socket, so a body at the cap
/// costs the sender several times the cap in memory. Sixty rather than eighty
/// because this runs on phones.
///
/// The measurement's own copy is inside that figure too: admission serialises
/// one conversation at a time to learn its size, so a conversation at the
/// per-conversation ceiling adds one encode of its own on top of the batch it
/// is being admitted into.
///
/// Named for what it holds: the *budget*, not the headroom. A name carrying the
/// other side of the ratio would make "give the send path more headroom" a
/// change that halves it.
const int kSyncDeltaBudgetPercent = 60;

/// How many bytes one push may carry, all parts together: conversation
/// subtrees, business rows, the asset manifest, skill hashes and the workspace
/// tables. `sync_budget.dart` measures everything but the subtrees and admits
/// subtrees against the remainder.
const int kSyncDeltaByteBudget =
    kSyncMaxBodyBytes * kSyncDeltaBudgetPercent ~/ 100;

/// How large one conversation may be to ride in a push: half the push budget.
///
/// Derived, not chosen twice: without this bound one huge conversation fits
/// under the push budget only by displacing every other conversation from the
/// round, and with only the push budget a batch of ordinary conversations can
/// still add up past it. One bound per question — this one answers "is this
/// conversation too big to send at all", [kSyncDeltaByteBudget] answers "does
/// this batch still fit".
const int kSyncMaxConversationBytes = kSyncDeltaByteBudget ~/ 2;
