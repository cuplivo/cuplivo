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

### The second half of #1007

Three more gaps surfaced while verifying that fix, all of them on the *reporting* side of the
same contract — where the care path told the user (or the log) something the system was not
doing:

- **iOS had no foreground executor at all.** `IosProactiveCareScheduler` only schedules an
  arrival notification and leaves `attach`/`detach` empty, so a care time reached while the app
  was alive produced nothing until the next `resumed` transition — and never when the user was
  looking at the app. Kelivo's own iOS scheduler does not work that way: `PreparedScheduledTasks`
  runs a 1 s `Timer.periodic` in the app and executes due tasks in the foreground, with the
  notification only as the suspended-app fallback. The care port dropped that half.
- **The exact-alarm grant was invisible.** `ProactiveCareAlarms.arm()` wrote the registry and
  called the (permission-gated, silently no-op) `ExactAlarmHelper.scheduleExact`, logging
  `alarm arm` either way, and never reported the grant back to Dart; the readiness card also
  stayed collapsed, so "care is on, the alarm is not" looked exactly like "care is on". Kelivo's
  `ScheduledTasks` treats the grant as a first-class state instead: `snapshot()` reports
  `exactAlarms`, `arm()` is gated on it, and the task list blocks with a waiting state.
- **The letter was not durable on screen.** The silent insert bypasses the streaming path, and
  the timeline was only reloaded *after* the trailing next-time decision (another model round
  trip, tens of seconds to minutes). A foreground delivery therefore looked like a failure until
  the user navigated away and back.

Two further deviations were examined and deliberately left alone, because they are Kelivo's own
contract rather than a porting gap: the 1 s foreground cadence (Kelivo's desktop/iOS schedulers
poll at 1 Hz) and the arrival notification's second identity (`ScheduledTaskNotifications` only
removes pending requests, which is the right behaviour for `prepared: false` letters).

## Decisions

1. **A fire always ends in one of two states.** `careFirePlan(ready, foreground)` yields
   `Direct` only while the app owns the foreground (live channel listener, no notification
   flash), and `Service` otherwise (the same `beginScheduledRun` contract a scheduled task
   uses). There is deliberately no third state: a held fire with neither owner has no listener
   and no recovery.
2. **Both plans arm the watchdog.** A handoff that never completes is reclaimed by `finish(id)`
   instead of parking the conversation forever.
3. **In-flight before consumption.** `fire()` returns early while another delivery for the same
   conversation is in flight, leaving the registry entry intact (and saying so in the log). An
   occurrence is only consumed when this fire owns the handoff; when that handoff finishes, a
   registry entry that arrived meanwhile is re-armed, so the newer letter keeps a native carrier
   instead of waiting for the next `sync`/resume. A deadline that expires without an answer is
   logged and recorded (`care_delivery_timeout`) rather than passing silently.
4. **The foreground drains what is held.** `MainActivity.onStart` calls
   `proactiveCareAlarms.dispatchPending()` right after `setForeground(true)`, so a fire parked
   by a refused service start still reaches Dart minutes later rather than never. The
   `dispatchPending()` a `Service` fire calls right after `beginScheduledRun` is a no-op — the
   service starts asynchronously, so `service` is still null at that instant; the drain that
   actually completes that handoff is `GenerationForegroundService.onStartCommand` (it calls
   `proactiveCareAlarms.dispatchPending()` while `hasScheduledRuns`) plus the Dart `ready`
   handshake. If neither ever comes, the 10-minute deadline releases the occurrence and the
   **Dart-side overdue catch-up is the last resort** — the native side cannot promise delivery
   without a listener, it can only promise not to strand the conversation.
5. **The in-process scheduler exists only where Kelivo has one.** Care is a *consumer* of
   Kelivo's scheduled-task layer, so each platform's trigger is the one upstream already owns
   there. `InProcessProactiveCareScheduler` (renamed from `DesktopProactiveCareScheduler`, whose
   doc already claimed "foreground platforms") is attached in `ProactiveCareAlarmService.attach`
   only for **desktop** (primary owner, matching `DesktopScheduledTasks`) and **iOS** (foreground
   executor, the same role `PreparedScheduledTasks` plays for Kelivo's own iOS scheduled tasks).
   **Android deliberately has none**: `ScheduledTasksService.configureDevice` returns early for
   Android and `attach` only readies the native channel, so Kelivo's Android tasks run through the
   native exact alarm alone. Adding a Dart timer there would not be reuse but a second trigger (and
   a permanent 1 s poll) that upstream does not have. Delivery stays exactly-once because
   `_claimSchedule` is the only place a schedule is consumed — a native fire and the timer racing
   each other resolve to one letter.
6. **Resume re-arms, from a trustworthy snapshot, before the catch-up.**
   `HomePageController.onAppLifecycleStateChanged(resumed)` runs
   `HomeViewModel.reschedulePendingProactiveCare()` and then the overdue catch-up. The re-arm only
   *calls* the upstream `rescheduleAll` API (it owns no timing), so it stays inside the
   consumption layer even though upstream does not re-arm on every resume. Two constraints make it
   safe: the re-arm is a *replace-all* (the native registry cancels whatever the payload omits,
   the in-process mirror clears and refills), so it (a) is skipped while the chat stores are
   unloaded or the assistant list cannot resolve the owner of a schedule it would otherwise arm,
   and (b) runs **before** the catch-up — and (b) only sequences the catch-up the same call
   performs. No lock is needed for other triggers (the in-app timer on desktop/iOS, or a native
   `fire` on Android): from the snapshot read (`getAllConversations()`) to the native
   `rescheduleAll` invocation the path contains no `await` — `_resolvesEveryScheduledOwner` and
   `pendingForReschedule` are synchronous — so no concurrent delivery can arm a newer occurrence
   inside the replace-all's window, and any `sync` that lands afterwards is ordered behind it on
   the same MethodChannel. The re-arm itself is guarded inside
   `HomeViewModel.reschedulePendingProactiveCare` (empty-store check) and
   `ProactiveCareAlarmService._resolvesEveryScheduledOwner` (an unloaded snapshot must not clear
   alarms it cannot see), while the catch-up is not: `runDueSchedules` finds no candidates while
   the conversation cache is empty, and `initChat` kicks off `deliverDueProactiveCare` again once
   the caches are loaded and the startup `rescheduleAll` has completed.
7. **Silent failures are over.** Every early return on the trigger chain logs
   `[ProactiveCare] …` (`debugPrint` on the Dart side, tag `ProactiveCare` on the Kotlin side),
   and native dispatch failures also go through `BackgroundRuntime.recordError`, the same
   observability Kelivo's scheduled tasks have. This follows the 3.x debug-first strategy
   recorded in that line's ADR-0031, which found an earlier instance of the same class of bug
   (re-arming before assistants had loaded).
8. **The letter reaches the UI as soon as it is durable.** `ProactiveCareMessageFlow` calls
   `onLetterPersisted(conversationId)` right after `addMessage`, before the trailing next-time
   decision, and `HomeViewModel` is the only owner of that callback: it reloads the timeline when
   the letter belongs to the open conversation. The delivery entry points no longer refresh
   after the fact, so a slow decision round trip cannot hide a letter that is already in the
   database, and `deliverProactiveCareSchedule` cannot reload twice.
9. **The exact-alarm grant is reported, not assumed.** `ProactiveCareAlarms` answers
   `status`, and every `sync`/`rescheduleAll` reply carries `exactAlarms`; `arm()` logs
   `Log.w` and returns without pretending instead of describing a no-op as `alarm arm`. Dart
   stores the flag in `ProactiveCareAlarmService.exactAlarmsPermitted` and logs the downgrade for
   the affected conversation, and the Roleplay care pane mirrors Kelivo's gating: the readiness
   card auto-expands when the grant is missing, and a future-only conversation row reads
   `scheduledTasksWaitingPermission` instead of promising a time the platform will not honour.
   `AndroidProactiveCareSettingsStatus.waitsForExactAlarm` counts both `notReady` and `unknown`
   (a failed query is not a licence to promise the time). The registry write stays where it is —
   a missing grant downgrades care rather than cancelling it, because the Dart schedule is
   unconsumed: on desktop/iOS the in-app executor still delivers it while the app is alive, and on
   Android the next resume's catch-up does (upstream parity: Kelivo's own Android tasks do not run
   without the grant either).
10. **Parity is a finding too.** The 1 s foreground cadence — on the platforms that have an
    in-app executor, i.e. desktop and iOS, exactly where Kelivo polls at 1 Hz — and the arrival
    notification's pending-request-only removal are Kelivo's own behaviour, so they are recorded
    here and left alone; a re-base must preserve them, not "fix" them. Android is *not* a cadence
    case: it has no in-app executor on either side, and a re-base must not reintroduce one.
11. **The iOS arrival notification's identity and replace-all contract match Kelivo's adapter.**
    Care registers its arrival notification through `app.scheduled_notifications`, and
    `ScheduledTaskNotifications` prepends `scheduled-task:` in both `schedule` (`prefix + runId`)
    and `cancel` (`prefix + id`). `IosProactiveCareScheduler.notificationIdFor` is the single
    builder of that `runId` argument — passing the bare conversation id so `schedule` and `cancel`
    both address `scheduled-task:<conversationId>` without double-prefixing. In addition,
    `IosProactiveCareScheduler.rescheduleAll` is a replace-all like Android's
    `ProactiveCareAlarms.replaceAll` (`(due.keys - wanted.keys).forEach(::cancel)`): it cancels
    every conversation that had a schedule but is no longer pending — one this process scheduled,
    or one still carrying a stored care time — so a dropped schedule (past due, switched off, owner
    assistant gone) does not leave a stale pending arrival notification behind. A conversation that
    vanished from the snapshot entirely is not in that set; it is swept by
    `PreparedScheduledTasks.load` at the next start (which cancels every pending `scheduled-task:`
    id that is not one of its runs) and care re-arms the survivors afterwards.
12. **A cold start recovers once the stores are loaded, and the resume path is unconditional.**
    `resumed` fires before `ChatService.init()` on a notification-tap cold start, and back then
    `getAllConversations()` returns nothing, so the catch-up found no candidates; gating the whole
    recovery on `_chatInitialized` (`HomePageController.onAppLifecycleStateChanged`) dropped the one
    delivery that scenario needs, and nothing retried because the app was already in the
    foreground. `_recoverProactiveCareOnResume` (re-arm, then catch-up) now runs from `resumed`
    unconditionally, and `initChat` kicks off `deliverDueProactiveCare` (`unawaited`) right after
    its awaited `ProactiveCareAlarmService.rescheduleAll` once the caches are warm — deliberately
    not awaited so the `finally` block can open the tapped conversation immediately while
    `onLetterPersisted` reloads the window as soon as the letter is stored. The re-arm keeps its
    own guard inside the view model and service (an unloaded snapshot must not clear alarms it
    cannot see); the catch-up stays idempotent through the atomic claim.
13. **A live Dart listener is the only precondition for a direct Android hand-off.** `careFirePlan`
    took `(ready, foreground)` and chose `Direct` only when the Activity owned the foreground. That
    parked every fire in the state the app spends most of its life in — process alive, screen off,
    another app in front — behind a foreground-service start that Android 12+ may refuse from the
    background, or behind the next `MainActivity.onStart`: a letter due at 10:55 surfaced at 11:08.
    `ready` already carries the real fact (Dart installed its `fire` handler), so the plan is now
    `careFirePlan(ready)`; `Direct` hands off through `dispatchToChannel`, and `dispatchPending`
    keeps its foreground/service hold for the `Service` plan, whose whole purpose is that no
    listener exists yet. A direct hand-off is not silent either: the persisted letter posts its own
    notification. `configure` resets `ready` and clears `dispatched`, because a recreated engine has
    no listener until it answers again and any previous engine's hand-offs were lost with it. Note
    the deliberate trade-off: a `Direct` hand-off while backgrounded runs in the live process
    without starting a foreground service, trading foreground-service process protection for
    immediate delivery latency without triggering `BackgroundRuntime.beginScheduledRun`'s
    collateral `stopAll`.
14. **`dispatched` is a cross-drain delivery record bounded by `inFlight`.** `dispatchToChannel`
    checks `val bridge = channel ?: return`, invokes `fire` for each `inFlight` id not yet in
    `dispatched`, adds the id to `dispatched` after invoking, and prunes stale entries with
    `dispatched.retainAll(inFlight.keys)` (while `finish(id)` removes the id once Dart acknowledges
    via `done`). Keeping all still-`inFlight` ids in `dispatched` across drains prevents a second
    conversation's fire or `MainActivity.onStart` from erasing an earlier in-flight letter's
    delivery record and re-firing it before its model round trip finishes. Pinned by
    `ProactiveCareAlarmsTest.laterDrainsDoNotReFireAnAlreadyDispatchedInFlightLetter` (run it
    deliberately — see the verification note below) plus `ProactiveCareFirePlanTest`.
15. **A refused arrival notification is logged.** `ScheduledTaskNotifications.schedule` returns
    `false` when notifications are not authorized or the adapter's 60-request queue is full;
    `IosProactiveCareScheduler` logs the refusal with the `[IosProactiveCare]` tag so a silent
    refusal is visible in diagnostics.

## Consequences

- The five `[ProactiveCare]` log lines now describe a whole delivery: `alarm arm` → `native fire`
  (on desktop/iOS, or the in-process timer) → `deliver` → `claim lost`/letter → `finish`. A future
  report can be pinned from logcat without guessing.
- Two triggers can race for one schedule; the atomic claim makes that a no-op for the loser, so
  the extra trigger costs one extra channel round-trip at most.
- `ProactiveCareAlarmService` now branches on `defaultTargetPlatform` (the tree's
  `PlatformUtils` pattern) instead of `dart:io Platform.is*`, which is what makes the Android
  branch unit-testable off-device.
- Android has exactly three recovery points, all consuming Kelivo's native layer: the exact
  alarm, the `MainActivity.onStart` drain, and the resume re-arm/catch-up. A fire whose handoff
  never completes is released by the deadline (logged and recorded), and a letter whose alarm was
  lost, cleared by the OEM, or never scheduled for lack of the grant is delivered by the next
  resume instead of within a second — the same guarantee, and the same limit, Kelivo's own Android
  scheduled tasks work under.
- iOS keeps the arrival notification: the in-app executor covers "the app is alive", the
  notification covers "the app is suspended or dead" and the start/resume catch-up still writes
  the letter. The two cannot double-deliver, because both paths claim the same persisted
  schedule. The residual gap — a letter whose time passes while the app is suspended, announced
  by the notification but written only on the next resume — is inherent to iOS background
  limits, not to this port.
- The readiness card now auto-expands once per pane lifetime when the grant is missing; a user
  who collapses it again is not fought. `AndroidProactiveCareSettingsStatus.waitsForExactAlarm`
  is the single predicate behind the conversation row's waiting text and its tests, and it treats
  a failed grant query (`unknown`) as waiting too.
- A re-arm is only as good as its snapshot: the resume path and `rescheduleAll` itself refuse to
  run on a snapshot that cannot resolve the owner of a future schedule the replace-all would
  otherwise arm, because it would cancel exactly the alarms it failed to see. Schedules the
  re-arm omits by design — past-due, or owned by an assistant that no longer exists — must not
  veto it, or one stale row would freeze every other pending letter. A cold-start `resumed` that
  arrives before `initChat` therefore changes nothing (the startup re-arm still runs), instead of
  wiping the registry; the same `resumed` still runs the catch-up.
- The 10-minute deadline *releases* an occurrence rather than replaying it. Re-arming a past
  occurrence there would re-enter the parked state every 10 minutes whenever no listener exists,
  so the recovery stays where the truth is: the Dart schedule is unconsumed, and the overdue
  catch-up delivers it on the next resume. The release is logged and recorded so it is visible.
- A future re-base must replay this contract as part of the care unit
  (`docs/rebase-runbook.md`); the deviations it fixes are exactly the kind of thing a mechanical
  port reintroduces.
- Care's arrival notification shares Kelivo's `scheduled-task:` namespace on iOS. Two invariants
  must hold: (a) both `schedule` and `cancel` pass the bare conversation id through
  `IosProactiveCareScheduler.notificationIdFor` (which `ScheduledTaskNotifications` prefixes on
  both sides), and (b) `IosProactiveCareScheduler.rescheduleAll` cancels the conversations whose
  schedules it drops, so they never stay pending. Both invariants are pinned by
  `ios_proactive_care_scheduler_test.dart`.
- Android now has two dispatch entries into the same channel: `dispatchToChannel` (a live listener,
  plan `Direct`) and `dispatchPending` (waits for the service or the foreground, plan `Service`).
  They share `dispatched`, which records *hand-offs that happened* across drains and is pruned only
  against `inFlight.keys` (plus `finish(id)` on Dart's `done` ack); a fire is therefore delivered
  at most once, an in-flight letter is not re-fired by a subsequent drain, and a fire that could
  not be handed over stays queued for the next drain.
- Known and deliberately deferred: `BackgroundRuntime.beginScheduledRun` sets `blocked` when the
  foreground service cannot start and then calls `scheduledTasks.stopAll("foreground_service_start_failed")`,
  which aborts unrelated scheduled-task runs as collateral. Care's own recovery (the `MainActivity.onStart`
  drain, the deadline, the Dart catch-up) does not depend on that call, and changing it touches
  shared runtime behaviour for every background feature — so it is recorded here as an observation
  rather than changed with this fix.
- The residual iOS gap is unchanged and is a platform limit, not a port bug: while the app is
  suspended or dead no letter text exists, so the arrival notification can only announce it and the
  letter is written on the next foreground (a model round trip, so tens of seconds to a minute).
  What this decision set removes is the *silent* part — the orphaned notification, the dropped
  cold-start catch-up, and the refusal nobody could see.
- **Verification is uneven across the three platforms, and that is worth knowing when reading this
  document's claims.** The Dart half is gated on every PR (`pr-check`: format, l10n, analyze, tests).
  Nothing compiles Swift (`Runner/ScheduledTaskNotifications` included), so a `Runner/`-level
  regression is caught only by dispatching `release.yml` (`publish_release=false`) or by a device
  test. Kotlin production code is compiled by `release.yml`, but `android/app/src/test/` is compiled
  by neither workflow — `ScheduledAlarm.operation` had been nullable for a year without anyone
  noticing, because the file never type-checked anywhere. The two care suites
  (`ProactiveCareAlarmsTest`, `ProactiveCareFirePlanTest`) were compiled and run through a temporary
  gate on this change's branch and are green there, but nothing in the repository will run them
  again: treat a care edit's Kotlin tests as something to run deliberately
  (`./gradlew :app:testReleaseUnitTest`), and treat the remaining 52 pre-existing failures in that
  source set (`OAuthLifecycleTest`, plus one `HighRefreshRateControllerTest` initializer) as debt
  this document is only recording.
- The Dart side of this contract is covered in `ios_proactive_care_scheduler_test.dart` (the
  identifier and `rescheduleAll` replace-all invariants), `proactive_care_alarm_service_test.dart`
  (both platform branches), and the pure fire-plan decision and cross-drain delivery record in
  `ProactiveCareFirePlanTest` and `ProactiveCareAlarmsTest`.
