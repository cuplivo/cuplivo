package com.cuplivo.cuplivo.scheduled

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.cuplivo.cuplivo.KelivoApplication
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** How a fired letter reaches the Dart side. */
internal enum class CareFirePlan { Direct, Service }

/**
 * A letter only reaches Dart through a live channel: either the app is in
 * front (no foreground service needed, and no notification flash), or the run
 * goes through the same foreground-service contract as a scheduled task.
 *
 * There is deliberately no third option. A fire held back while neither holds
 * has no listener for the channel, and drifting there used to drop the letter
 * (and, because the occurrence was already consumed, every later one too).
 */
internal fun careFirePlan(ready: Boolean, foreground: Boolean): CareFirePlan =
    if (ready && foreground) CareFirePlan.Direct else CareFirePlan.Service

/**
 * Native owner of the proactive-care ("Ta的来信") letter alarms.
 *
 * One-shot exact alarms keyed by conversation id, mirroring the
 * ScheduledTasks architecture: the registry survives process death,
 * a fire only consumes the alarm and hands the conversation to the
 * shared Flutter engine — generation itself always runs on the Dart
 * provider stack, which claims the schedule atomically before
 * delivering (see ProactiveCareMessageFlow).
 */
class ProactiveCareAlarms(private val app: KelivoApplication) {
    companion object {
        const val FIRE = "com.cuplivo.cuplivo.care.FIRE"
        private const val TAG = "ProactiveCare"
        private const val LIMIT_MS = 10 * 60 * 1000L
        private const val RUN_PREFIX = "care:"
    }

    private val prefs = app.getSharedPreferences("cuplivo_proactive_care_alarms", Context.MODE_PRIVATE)
    private val alarms = app.getSystemService(AlarmManager::class.java)
    private val main = Handler(Looper.getMainLooper())
    private val due = mutableMapOf<String, Long>()
    private val inFlight = mutableMapOf<String, Long>()
    private val dispatched = mutableSetOf<String>()
    /** Fires that actually began a foreground-service run (`Service` plan). */
    private val serviceRuns = mutableSetOf<String>()
    private val deadlines = mutableMapOf<String, Runnable>()
    private var channel: MethodChannel? = null
    private var ready = false

    init {
        // Registry recovery: SharedPreferences is the single source of truth.
        prefs.all.forEach { (key, value) ->
            val id = key.removePrefix("alarm:")
            if (id != key && value is Long) due[id] = value
        }
    }

    fun configure(messenger: BinaryMessenger) {
        channel = MethodChannel(messenger, "app.proactive_care_alarms").also { bridge ->
            bridge.setMethodCallHandler { call, result ->
                try {
                    val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
                    when (call.method) {
                        "ready" -> {
                            ready = true
                            dispatchPending()
                            result.success(null)
                        }
                        "sync" -> {
                            val id = args["conversationId"] as String
                            val dueAt = (args["dueAt"] as Number).toLong()
                            if (dueAt <= System.currentTimeMillis()) cancel(id) else arm(id, dueAt)
                            result.success(status())
                        }
                        "cancel" -> {
                            cancel(args["conversationId"] as String)
                            result.success(null)
                        }
                        "status" -> result.success(status())
                        "rescheduleAll" -> {
                            @Suppress("UNCHECKED_CAST")
                            val list = args["alarms"] as? List<Map<String, Any>> ?: emptyList()
                            replaceAll(list.mapNotNull { row ->
                                val id = row["conversationId"] as? String ?: return@mapNotNull null
                                val at = (row["dueAt"] as? Number)?.toLong() ?: return@mapNotNull null
                                id to at
                            })
                            result.success(status())
                        }
                        "done" -> {
                            finish(args["conversationId"] as String)
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (error: Exception) {
                    result.error("proactive_care_alarm", error.message, null)
                }
            }
        }
    }

    private fun pendingIntent(id: String, dueAt: Long): PendingIntent {
        val intent = Intent(app, ProactiveCareAlarmReceiver::class.java).setAction(FIRE)
            .setData(Uri.Builder().scheme("kelivo-schedule").authority("care").appendPath(id).build())
            .putExtra("dueAt", dueAt)
        return PendingIntent.getBroadcast(app, 0, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    private fun persist(id: String, dueAt: Long?) {
        if (dueAt == null) prefs.edit().remove("alarm:$id").apply()
        else prefs.edit().putLong("alarm:$id", dueAt).apply()
    }

    // Whether the system lets this app schedule exact alarms. Mirrors
    // ScheduledTasks: the native owner is the only one that can answer, and
    // without the grant nothing is scheduled in the background at all.
    private fun permitted() = ExactAlarmHelper.isExactAlarmPermitted(alarms)

    private fun status() = mapOf("exactAlarms" to permitted())

    private fun arm(id: String, dueAt: Long) {
        ExactAlarmHelper.cancel(alarms, pendingIntent(id, 0))
        due[id] = dueAt
        persist(id, dueAt)
        if (!permitted()) {
            // Same contract as ScheduledTasks.arm: no exact-alarm grant, no
            // alarm. Say so instead of logging a successful arm.
            Log.w(TAG, "exact alarm not permitted; $id can only fire while the app is alive")
            return
        }
        ExactAlarmHelper.scheduleExact(alarms, dueAt, pendingIntent(id, dueAt))
    }

    private fun cancel(id: String) {
        ExactAlarmHelper.cancel(alarms, pendingIntent(id, 0))
        due.remove(id)
        persist(id, null)
    }

    private fun replaceAll(entries: List<Pair<String, Long>>) {
        val wanted = entries.toMap()
        (due.keys - wanted.keys).forEach(::cancel)
        wanted.forEach { (id, at) ->
            if (at <= System.currentTimeMillis()) cancel(id) else arm(id, at)
        }
    }

    /** Boot / time / permission-grant re-arm: never replays missed letters. */
    fun rescheduleAll() {
        due.entries.toList().forEach { (id, at) -> arm(id, at) }
    }

    fun fire(id: String, dueAt: Long) {
        // A stale delivery (alarm raced a reschedule/cancel) is ignored; the
        // registry still holds the authoritative next time.
        if (due[id] != dueAt) return
        // Never consume an occurrence another delivery still owns: the parked
        // fire would be dropped along with it.
        if (inFlight.containsKey(id)) {
            Log.i(TAG, "fire $id due=$dueAt ignored: a delivery for this conversation is in flight")
            return
        }
        due.remove(id)
        persist(id, null)
        inFlight[id] = dueAt
        // Both plans arm the deadline, so a handoff that never completes is
        // released instead of parking the conversation forever. Releasing is a
        // drop on the native side: the Dart schedule is still unconsumed, so
        // the overdue catch-up owns this letter from here on.
        val timeout = Runnable {
            Log.w(TAG, "fire $id due=$dueAt released after the deadline")
            app.backgroundRuntime.recordError("care_delivery_timeout: $id")
            finish(id)
        }
        deadlines[id] = timeout
        main.postDelayed(timeout, LIMIT_MS)
        val plan = careFirePlan(ready, app.backgroundRuntime.foreground)
        Log.i(TAG, "fire $id due=$dueAt plan=$plan")
        try {
            when (plan) {
                // The app owns the foreground: the engine is alive and the
                // channel has a listener, so dispatch without the
                // foreground-service dance (no notification flash).
                CareFirePlan.Direct -> dispatchPending()

                CareFirePlan.Service -> {
                    // The service posts its foreground notification before
                    // warming Flutter, and is the only owner that guarantees
                    // the channel gets a listener.
                    if (!app.hasEngine) app.backgroundRuntime.setForeground(false)
                    serviceRuns.add(id)
                    app.backgroundRuntime.beginScheduledRun(RUN_PREFIX + id)
                    dispatchPending()
                }
            }
        } catch (error: RuntimeException) {
            // Keep the fire parked: the next foreground dispatch
            // (MainActivity.onStart) can still deliver it, and the deadline
            // releases it otherwise.
            app.backgroundRuntime.recordError("care_delivery_failed: ${error.message}")
            Log.w(TAG, "fire $id failed to dispatch", error)
        }
    }

    /** Sends every claimed-but-undelivered fire to the Dart side. */
    fun dispatchPending() {
        if (!ready) return
        // When the process was dead, the engine only exists under the
        // foreground service; without it the channel has no listener yet.
        // Nothing is dropped *here*: the entry keeps its deadline and the next
        // foreground dispatch drains it (see MainActivity.onStart). If that
        // never comes, the deadline releases the occurrence and the Dart-side
        // overdue catch-up is the last resort.
        if (inFlight.isNotEmpty() && app.backgroundRuntime.service == null && !app.backgroundRuntime.foreground) {
            Log.i(TAG, "dispatchPending: holding ${inFlight.size} letter(s) for the foreground")
            return
        }
        inFlight.toMap().forEach { (id, dueAt) ->
            if (!dispatched.add(id)) return@forEach
            Log.i(TAG, "dispatchPending: handing off $id due=$dueAt")
            channel?.invokeMethod("fire", mapOf("conversationId" to id, "dueAt" to dueAt))
        }
    }

    private fun finish(id: String) {
        deadlines.remove(id)?.let(main::removeCallbacks)
        if (inFlight.remove(id) != null) {
            dispatched.remove(id)
            Log.i(TAG, "finish $id")
            // Only the Service plan began a scheduled run; a foreground fire
            // never did, and ending one it never started would touch
            // accounting that belongs to another run.
            if (serviceRuns.remove(id)) {
                app.backgroundRuntime.endScheduledRun(RUN_PREFIX + id)
            }
            // An occurrence that arrived while this delivery was in flight kept
            // its registry entry but lost its one-shot alarm (the system
            // consumed it). Re-arm it so the newer letter keeps a carrier
            // instead of waiting for the next sync/resume.
            due[id]?.let { arm(id, it) }
        }
    }
}
