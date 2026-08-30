# ADR-0041: Screen-on Wake Lock During Generation

Mobile chat generation holds the screen on (`wakelock_plus`, Android
`FLAG_KEEP_SCREEN_ON` / iOS `idleTimerDisabled`) so the user can watch the
stream without the display sleeping — the classic chat-app behavior.
**User-togglable (issue #552)**: an opt-out switch
`keepScreenOnDuringGeneration` (default `true`, so the shipped behavior is
unchanged) lets battery/heat-conscious users turn the wake lock off. The
toggle is re-checked at every slot start: an in-flight round keeps its lock
until settle, a new enabled slot turns the screen on even when an older
disabled round is still running, and an off-flip over overlapping rounds only
takes effect once every active round has settled (a new round can only *add*
a lock — it cannot preempt one a still-active round relies on).

## Why the engine, not the page layer

The lock is acquired inside `GenerationEngine._runSlot` and released in its
`finally`, via an injectable refcounted `WakeLockManager`
(`lib/core/services/wake_lock_manager.dart`). The naive alternative would
toggle the lock in page-level stream adapters, which exist in parallel for
page / Multi-AI / group-chat / subagent. The engine is the single choke point;
a refcount over running slots makes Multi-AI (N slots) the natural case and
single AI the degenerate case — the same argument as ADR-0034. Images-API
image generation streams through the engine's chunk loop and is covered
automatically.

## Considered and rejected

- **CPU / background lock**: already owned by `AndroidBackgroundManager`
  (flutter_background foreground service, Android-only, user-toggled). The
  wake lock only keeps the *screen* on; the two mechanisms are orthogonal.
- **Desktop**: `wakelock_plus` nominally supports Windows/macOS/Linux, but an
  actively watched stream implies a live monitor. Excluded to avoid plugin
  surface on three more platforms.
- **User toggle**: rejected in v1 (always-on: the cost of a broken stream
  outweighs battery); adopted with an opt-out in #552 (battery/heat is a
  real user concern, and the switch makes the trade-off the user's).
- **App-lifecycle hook**: rejected — the Android window flag is
  foreground-scoped by construction; backgrounding naturally ends the
  screen-on state. An observer would be dead code.
- **Hand-rolled platform channels**: rejected per repo protocol (prefer
  mature third-party libraries).

## Consequences

- New dependency `wakelock_plus`.
- Future generation paths outside the engine (new layer-① consumers) silently
  lack the lock — the engine-boundary rule must be respected.
- The refcount's failure mode is a leaked hold (screen never sleeps, battery);
  the test set covers done / error / cancel / pre-start-abort / `failRound`
  settlement paths.
- The user toggle is re-checked per slot start; a mid-round flip takes
  effect for rounds that start afterwards. `WakeLockManager._platformOn`
  distinguishes "enabled but failed" from "disabled by the user" so the
  settle-time drop is never skipped once an enable was requested.
