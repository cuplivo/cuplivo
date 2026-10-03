package com.cuplivo.cuplivo.scheduled

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import com.cuplivo.cuplivo.KelivoApplication
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

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
        private const val LIMIT_MS = 10 * 60 * 1000L
        private const val RUN_PREFIX = "care:"
    }

    private val prefs = app.getSharedPreferences("cuplivo_proactive_care_alarms", Context.MODE_PRIVATE)
    private val alarms = app.getSystemService(AlarmManager::class.java)
    private val main = Handler(Looper.getMainLooper())
    private val due = mutableMapOf<String, Long>()
    private val inFlight = mutableMapOf<String, Long>()
    private val dispatched = mutableSetOf<String>()
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
                            result.success(null)
                        }
                        "cancel" -> {
                            cancel(args["conversationId"] as String)
                            result.success(null)
                        }
                        "rescheduleAll" -> {
                            @Suppress("UNCHECKED_CAST")
                            val list = args["alarms"] as? List<Map<String, Any>> ?: emptyList()
                            replaceAll(list.mapNotNull { row ->
                                val id = row["conversationId"] as? String ?: return@mapNotNull null
                                val at = (row["dueAt"] as? Number)?.toLong() ?: return@mapNotNull null
                                id to at
                            })
                            result.success(null)
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

    private fun arm(id: String, dueAt: Long) {
        ExactAlarmHelper.cancel(alarms, pendingIntent(id, 0))
        due[id] = dueAt
        persist(id, dueAt)
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
        due.remove(id)
        persist(id, null)
        if (inFlight.containsKey(id)) return
        inFlight[id] = dueAt
        if (app.hasEngine && ready) {
            // Foreground path: the engine is alive, dispatch without the
            // foreground-service dance (no notification flash).
            dispatchPending()
            return
        }
        val timeout = Runnable { finish(id) }
        deadlines[id] = timeout
        main.postDelayed(timeout, LIMIT_MS)
        // The service posts its foreground notification before warming Flutter.
        if (!app.hasEngine) app.backgroundRuntime.setForeground(false)
        app.backgroundRuntime.beginScheduledRun(RUN_PREFIX + id)
        dispatchPending()
    }

    /** Sends every claimed-but-undelivered fire to the Dart side. */
    fun dispatchPending() {
        if (!ready) return
        // When the process was dead, the engine only exists under the
        // foreground service; without it the channel has no listener.
        if (inFlight.isNotEmpty() && app.backgroundRuntime.service == null && !app.backgroundRuntime.foreground) return
        inFlight.toMap().forEach { (id, dueAt) ->
            if (!dispatched.add(id)) return@forEach
            channel?.invokeMethod("fire", mapOf("conversationId" to id, "dueAt" to dueAt))
        }
    }

    private fun finish(id: String) {
        deadlines.remove(id)?.let(main::removeCallbacks)
        if (inFlight.remove(id) != null) {
            dispatched.remove(id)
            app.backgroundRuntime.endScheduledRun(RUN_PREFIX + id)
        }
    }
}
