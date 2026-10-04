package com.cuplivo.cuplivo.scheduled

import android.app.AlarmManager
import android.content.Context
import com.cuplivo.cuplivo.KelivoApplication
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.StandardMethodCodec
import java.nio.ByteBuffer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowAlarmManager

/**
 * The trigger chain around a fired letter (#1007): a fire either goes out to a
 * listening Dart side or is owned by a foreground-service run, an in-flight
 * letter is not consumed by a later fire, a stale one is ignored, and a live
 * listener delivers even while the Activity is stopped.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], application = KelivoApplication::class)
class ProactiveCareAlarmsTest {
    private class Messenger : BinaryMessenger {
        val events = mutableListOf<MethodCall>()
        private val handlers = mutableMapOf<String, BinaryMessenger.BinaryMessageHandler>()

        /** Decoded replies, one per [call]. */
        val replies = mutableListOf<Any?>()

        override fun setMessageHandler(
            channel: String,
            handler: BinaryMessenger.BinaryMessageHandler?,
        ) {
            if (handler == null) handlers.remove(channel) else handlers[channel] = handler
        }

        override fun send(channel: String, message: ByteBuffer?) = send(channel, message, null)

        override fun send(
            channel: String,
            message: ByteBuffer?,
            callback: BinaryMessenger.BinaryReply?,
        ) {
            message?.flip()
            if (message != null) events += StandardMethodCodec.INSTANCE.decodeMethodCall(message)
            val reply = StandardMethodCodec.INSTANCE.encodeSuccessEnvelope(null)
            reply.flip()
            callback?.reply(reply)
        }

        fun call(method: String, args: Any? = null) {
            val data = StandardMethodCodec.INSTANCE.encodeMethodCall(MethodCall(method, args))
            data.flip()
            handlers.getValue("app.proactive_care_alarms").onMessage(data) { response ->
                response?.flip()
                replies += StandardMethodCodec.INSTANCE.decodeEnvelope(response!!)
            }
        }

        fun fired(): List<MethodCall> = events.filter { it.method == "fire" }
    }

    private val app get() = RuntimeEnvironment.getApplication() as KelivoApplication
    private val alarms get() = app.proactiveCareAlarms
    private val prefs
        get() = app.getSharedPreferences("cuplivo_proactive_care_alarms", Context.MODE_PRIVATE)

    private fun ready(): Messenger {
        val messenger = Messenger()
        alarms.configure(messenger)
        messenger.call("ready")
        return messenger
    }

    private fun sync(messenger: Messenger, id: String, at: Long) {
        messenger.call("sync", mapOf("conversationId" to id, "dueAt" to at))
    }

    private fun dueAtOf(call: MethodCall): Any? = (call.arguments as Map<*, *>)["dueAt"]

    @Test fun aListeningDartSideDeliversWhileTheAppIsInTheBackground() {
        val messenger = ready()
        app.backgroundRuntime.setForeground(false)
        val dueAt = System.currentTimeMillis() + 60_000

        sync(messenger, "c1", dueAt)
        alarms.fire("c1", dueAt)

        // The engine owns a live listener, so the letter goes out right away.
        // It used to be parked here until the app came back to the front, which
        // is how a letter due at 10:55 surfaced at 11:08 (#1007).
        val fire = messenger.fired().single()
        assertEquals("c1", (fire.arguments as Map<*, *>)["conversationId"])
        assertEquals(dueAt, dueAtOf(fire))
        // No service run: the direct hand-off never starts one.
        assertFalse(app.backgroundRuntime.hasScheduledRuns)
        // And the occurrence is consumed exactly once.
        assertNull(prefs.getAll()["alarm:c1"])
    }

    @Test fun aForegroundFireDispatchesWithoutAServiceBackedRun() {
        val messenger = ready()
        app.backgroundRuntime.setForeground(true)
        val dueAt = System.currentTimeMillis() + 60_000

        sync(messenger, "c1", dueAt)
        alarms.fire("c1", dueAt)

        val fire = messenger.fired().single()
        assertEquals("c1", (fire.arguments as Map<*, *>)["conversationId"])
        assertFalse(app.backgroundRuntime.hasScheduledRuns)
    }

    @Test fun anInFlightLetterIsNotConsumedByALaterFire() {
        val messenger = ready()
        app.backgroundRuntime.setForeground(true)
        ShadowAlarmManager.setCanScheduleExactAlarms(true)
        val manager = app.getSystemService(AlarmManager::class.java)
        val first = System.currentTimeMillis() + 60_000

        sync(messenger, "c1", first)
        alarms.fire("c1", first)
        assertEquals(1, messenger.fired().size)

        // A rescheduled occurrence arrives while the first is still in flight:
        // it stays in the registry instead of being consumed and dropped. The
        // system consumes the one-shot alarm while firing it, so the test does
        // the same — otherwise the registry would look armed by accident.
        val second = first + 60_000
        sync(messenger, "c1", second)
        // `ScheduledAlarm.operation` is nullable in Robolectric's shadow; in a
        // scheduled alarm it is always set.
        val secondAlarm = Shadows.shadowOf(manager).scheduledAlarms
            .single { it.triggerAtTime == second }
        manager.cancel(requireNotNull(secondAlarm.operation))
        alarms.fire("c1", second)

        assertEquals(1, messenger.fired().size)
        assertEquals(second, prefs.getLong("alarm:c1", -1))
        assertTrue(
            Shadows.shadowOf(manager).scheduledAlarms.none { it.triggerAtTime == second },
        )

        messenger.call("done", mapOf("conversationId" to "c1"))

        // Finishing the first delivery gives the ignored occurrence a carrier
        // again: a registry entry alone is armed nowhere.
        val rearmed = Shadows.shadowOf(manager).scheduledAlarms
            .single { it.triggerAtTime == second }
        assertEquals(second, rearmed.triggerAtTime)

        // That occurrence delivers the second letter.
        alarms.fire("c1", second)
        assertEquals(2, messenger.fired().size)
        assertEquals(second, dueAtOf(messenger.fired().last()))
    }

    @Test fun aStaleFireIsIgnored() {
        val messenger = ready()
        app.backgroundRuntime.setForeground(true)
        val dueAt = System.currentTimeMillis() + 60_000

        sync(messenger, "c1", dueAt)
        alarms.fire("c1", dueAt + 1)

        assertTrue(messenger.fired().isEmpty())
        assertEquals(dueAt, prefs.getLong("alarm:c1", -1))
    }

    /** Nothing is scheduled without the exact-alarm grant, and Dart has to hear
     *  that instead of believing an arm that never happened (#1007). */
    @Test
    @Config(sdk = [33])
    fun withoutTheExactAlarmGrantNothingIsScheduledAndDartIsTold() {
        val manager = app.getSystemService(AlarmManager::class.java)
        ShadowAlarmManager.setCanScheduleExactAlarms(false)
        val messenger = ready()
        val dueAt = System.currentTimeMillis() + 60_000

        sync(messenger, "c1", dueAt)

        assertEquals(mapOf("exactAlarms" to false), messenger.replies.last())
        assertTrue(Shadows.shadowOf(manager).scheduledAlarms.isEmpty())

        // The grant flips both the report and the real registration.
        ShadowAlarmManager.setCanScheduleExactAlarms(true)
        sync(messenger, "c1", dueAt)

        assertEquals(mapOf("exactAlarms" to true), messenger.replies.last())
        assertEquals(1, Shadows.shadowOf(manager).scheduledAlarms.size)
    }

    @Test
    @Config(sdk = [33])
    fun theStatusCallAnswersTheSameQuestion() {
        ShadowAlarmManager.setCanScheduleExactAlarms(false)
        val messenger = ready()

        messenger.call("status")

        assertEquals(mapOf("exactAlarms" to false), messenger.replies.last())
    }

    /**
     * `dispatched` is a cross-drain delivery record: a later drain (e.g. a
     * second conversation's Direct fire or `MainActivity.onStart`) while the
     * first letter is still awaiting Dart's `done` ack must not erase the first
     * letter's record and re-fire it.
     */
    @Test fun laterDrainsDoNotReFireAnAlreadyDispatchedInFlightLetter() {
        val messenger = ready()
        app.backgroundRuntime.setForeground(true)
        val dueAt = System.currentTimeMillis() + 60_000

        sync(messenger, "c1", dueAt)
        sync(messenger, "c2", dueAt)
        alarms.fire("c1", dueAt)
        assertEquals(1, messenger.fired().size)

        // Second fire triggers another `dispatchToChannel` while `c1` is still
        // in flight (no `done` yet), followed by a foreground `dispatchPending`
        // drain: `c1` must stay recorded in `dispatched` and never be handed
        // off a second time.
        alarms.fire("c2", dueAt)
        alarms.dispatchPending()
        alarms.dispatchPending()

        val firedIds = messenger.fired().map { (it.arguments as Map<*, *>)["conversationId"] }
        assertEquals(listOf("c1", "c2"), firedIds)
    }
}
