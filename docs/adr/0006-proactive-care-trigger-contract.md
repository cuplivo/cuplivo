# ADR-0006: The proactive-care trigger contract

**Status:** Accepted (2026-10)
**Deciders:** cuplivo
**Issue:** #1007

## Context

「Ta的来信」(proactive care) reuses Kelivo's scheduled-task alarm infrastructure: one native
exact alarm per conversation (`android/.../scheduled/ProactiveCareAlarms.kt`), a Dart-side
atomic claim that consumes the persisted next time, and a start/resume catch-up
(`runDueSchedules`) for whatever the alarm path missed.

Issue #1007 reported that letters stopped arriving on Android after 4.2 while the feature still
worked in 4.1. The screenshot settles which link failed: at 18:27 the conversation still showed
「下次助手主动发消息时间 18:25」, i.e. `_claimSchedule` never ran. Generation is provably fine
(the two earlier letters were persisted), the decision model is fine (18:25 got stored), and
Kelivo's own `ScheduledTasks` cannot produce this state — `start()` always calls
`beginScheduledRun()` before `dispatchPending()`, and `dispatchPending()` requires the
foreground service. The care channel, however, had three deviations:

- `fire()` took a "foreground shortcut" whenever the engine was alive (`hasEngine && ready`) and
  dispatched without a service — but `dispatchPending()` refuses to dispatch when
  `service == null && !foreground`, exactly the state of "process alive, Activity stopped"
  (screen off, another app in front). That fire was parked with **no deadline**, because the
  10-minute watchdog was only armed on the service path.
- `fire()` consumed the occurrence (`due.remove` + `persist(null)`) *before* the in-flight
  guard, so once a fire was parked, every later fire for that conversation was consumed and
  dropped as well — the conversation's letters were dead until the next process start.
- Nothing re-armed or re-dispatched when the app came back to the front: `dispatchPending()`
  only ran from the native `ready` message, `fire()` and the foreground service, and pending
  alarms were only re-armed at process start. A letter that arrived mid-session therefore
  depended entirely on the overdue catch-up, which only runs on a real `resumed` transition.

The code is byte-identical between 4.1 and 4.2 (`scheduled/` has no diff between `7761be66e`
and HEAD), so 4.2 did not introduce the defect; 4.2 merely hit it. This is a *reuse* error, not
a Kelivo bug: no upstream issue is warranted.

## Decisions

1. **A fire always ends in one of two states.** `careFirePlan(ready, foreground)` yields
   `Direct` only while the app owns the foreground (live channel listener, no notification
   flash), and `Service` otherwise (the same `beginScheduledRun` contract a scheduled task
   uses). There is deliberately no third state: a held fire with neither owner has no listener
   and no recovery.
2. **Both plans arm the watchdog.** A handoff that never completes is reclaimed by `finish(id)`
   instead of parking the conversation forever.
3. **In-flight before consumption.** `fire()` returns early while another delivery for the same
   conversation is in flight, leaving the registry entry intact. An occurrence is only consumed
   when this fire owns the handoff.
4. **The foreground drains what is held.** `MainActivity.onStart` calls
   `proactiveCareAlarms.dispatchPending()` right after `setForeground(true)`, so a fire parked
   by a refused service start still reaches Dart minutes later rather than never.
5. **The in-process scheduler is the Android foreground safety net.**
   `InProcessProactiveCareScheduler` (renamed from `DesktopProactiveCareScheduler`, whose doc
   already claimed "foreground platforms") is attached alongside the native alarm in
   `ProactiveCareAlarmService.attach`. While the app is alive it delivers a due letter even when
   the alarm was never scheduled, was cleared by the OEM, or handed off nowhere. Delivery stays
   exactly-once because `_claimSchedule` is the only place a schedule is consumed — a native
   fire and the timer racing each other resolve to one letter.
6. **Resume re-arms.** `HomePageController.onAppLifecycleStateChanged(resumed)` now runs
   `HomeViewModel.reschedulePendingProactiveCare()` before the overdue catch-up, mirroring the
   native `ready` → `rescheduleAll` re-arm Kelivo's scheduled tasks do.
7. **Silent failures are over.** Every early return on the trigger chain logs
   `[ProactiveCare] …` (`debugPrint` on the Dart side, tag `ProactiveCare` on the Kotlin side),
   and native dispatch failures also go through `BackgroundRuntime.recordError`, the same
   observability Kelivo's scheduled tasks have. This follows the 3.x debug-first strategy
   recorded in that line's ADR-0031, which found an earlier instance of the same class of bug
   (re-arming before assistants had loaded).

## Consequences

- The five `[ProactiveCare]` log lines now describe a whole delivery: `alarm arm` → `native fire`
  (or the in-process timer) → `deliver` → `claim lost`/letter → `finish`. A future report can be
  pinned from logcat without guessing.
- Two triggers can race for one schedule; the atomic claim makes that a no-op for the loser, so
  the extra trigger costs one extra channel round-trip at most.
- `ProactiveCareAlarmService` now branches on `defaultTargetPlatform` (the tree's
  `PlatformUtils` pattern) instead of `dart:io Platform.is*`, which is what makes the Android
  branch unit-testable off-device.
- iOS is unchanged: its arrival notification plus resume-generated letter is a deliberate design
  (the letter cannot be generated while the app is suspended). Extending the in-process safety
  net to iOS would only shorten the delay when the app is already alive; that is a follow-up,
  not part of this fix.
- A future re-base must replay this contract as part of the care unit
  (`docs/rebase-runbook.md`); the deviations it fixes are exactly the kind of thing a mechanical
  port reintroduces.
