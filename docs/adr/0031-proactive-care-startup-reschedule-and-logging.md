# ADR-0031: Proactive Care Startup Re-arm and Always-On Trigger-Path Logging

Ta的来信 (Proactive Care) is an Android-only exact-alarm feature that wakes the app
(`android_alarm_manager_plus`, one-shot, `exact: true, wakeup: true,
allowWhileIdle: true`) and asks the LLM for a scheduled care reply. A user reported
that the scheduled time arrived with the app in the foreground and no reply was
generated. The trigger path was effectively silent: the only always-on log was the
background-isolate `Alarm fired` line, everything else went through `FlutterLogger`
which is off by default (`flutter_log_enabled_v1`).

## Context

Three suspects could each explain "foreground, time arrived, no reply":

- **Startup re-arm race (fixed here)**: `main.dart` scheduled a post-frame callback
  that captured `AssistantProvider.assistants` before Drift was open and assistants
  had loaded, then called `rescheduleAll([])` — a silent no-op wrapped in `catch (_) {}`.
  After an Android force-stop (which clears all alarms) the next launch never re-armed
  the alarms, so the feature was dead until the user re-saved assistant settings.
- **Exact-alarm permission silently denied** (Android 12+ `SCHEDULE_EXACT_ALARM`):
  `oneShotAt` failures were only logged to the off-by-default `FlutterLogger`.
- **Startup-window trigger drop**: the main-isolate port is registered synchronously
  while assistants still load; `handleProactiveCareTrigger` silently early-returned
  when the assistant was not found yet, consuming the one-shot alarm.

No root cause was confirmed at session time; the agreed strategy was debug-first:
make the whole trigger path observable in logcat with always-on `debugPrint`, fix the
demonstrable startup race in the same change, and let the next user reproduction
produce evidence (`Alarm fired` present/absent, permission state) that pins the
remaining suspect.

## Decisions

- **Re-arm after assistants load, not at first frame**: `rescheduleAll` moved to
  `HomePageController.initChat`, right after `AssistantProvider.ensureDefaults`
  completes (where `ProactiveCareAlarmService.isSupported` guards non-Android). The
  first-frame block in `main.dart` now only persists the l10n snapshot.
- **Always-on trigger-path logging**: every silent step of the app-alive chain now
  `debugPrint`s with the `[ProactiveCare]` prefix — port receipt, handler entry and
  each early return, `newTime == null` decision outcome, schedule result, and all
  catch blocks. Existing `FlutterLogger.log` calls are kept alongside (file capture
  when the user enables it) but are no longer the only trace.
- **Schedule failure carries the permission state**: when `oneShotAt` returns false,
  the log includes `Permission.scheduleExactAlarm.status`, so a denied exact-alarm
  permission is identifiable in logcat without behavior changes.
- **Pure filter extracted**: `pendingForReschedule(List<Assistant>, {DateTime? now})`
  (enabled + future `proactiveCareNextMessageAt`) is the single source of truth for
  the re-arm filter, shared by `rescheduleAll` and unit tests.
- **No behavior change beyond re-arming**: the silent-drop path only logs for now;
  the permission-denied path still does not auto-degrade (AGENTS.md 3.6) and the
  recurring-cycle decision failure is out of scope until evidence points at it.

## Consequences

- `main.dart` no longer re-arms alarms at first frame; `initChat` is the single re-arm
  point (idempotent — `sync` replaces the pending alarm).
- A force-stop → relaunch now logs `rescheduleAll: N/M assistants need re-arming`
  plus one `Alarm scheduled`/`Alarm schedule FAILED` line per assistant, closing the
  evidence gap for the next user reproduction.
- New unit test `test/core/services/proactive_care_alarm_service_test.dart` pins the
  re-arm filter contract (disabled / null / past / exactly-now skipped, future kept).
- Remaining suspects (permission denial, decision-model loop death) stay unresolved by
  design; the next reproduction's logcat decides.
