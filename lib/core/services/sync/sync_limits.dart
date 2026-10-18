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
/// Derived from the endpoint cap, with headroom for a second peer's round: a
/// device that fans out over its whole address memory must never saturate its
/// *own* listener, or its own probe round comes back with nothing but "no
/// verdict" — and the ceiling's job (bounding the connections one peer can open)
/// is still done, at a number that is a fact about this protocol rather than an
/// unrelated eight.
const int kMaxPingsInFlight = kMaxPeerEndpoints + 2;

/// How many endpoints one probe round asks at once — the fan-out budget, shared
/// by both probe paths (the periodic tick and a session whose snapshot went
/// stale).
///
/// Equal to the endpoint cap so a peer's whole address memory is one wave: the
/// round's wait is then the slowest answer, not the sum of the chunks, which is
/// the property the parallel probe exists for. It is a *budget*, not a wish: a
/// set larger than this (a future cap, a caller that passed a bigger one) is
/// chunked rather than fanned out, so this file stays the single authority on
/// how much probing this device does at once.
const int kSyncProbeConcurrency = kMaxPeerEndpoints;

/// How many addresses a responder tries when it has to dial the initiator back
/// to pull a file from it.
///
/// Three, not twelve: every candidate costs a connect budget before the next is
/// tried, and this dial sits inside the peer's push beat, where the initiator is
/// waiting. The observed address and the two most likely advertised ones cover
/// the real cases (one address that works, one NAT'd memory, one other network);
/// what a miss costs is a file that waits for the push fallback instead.
const int kMaxReverseDialCandidates = 3;
