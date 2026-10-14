package com.cuplivo.cuplivo.scheduled

import android.app.AlarmManager
import android.content.Context
import android.os.Looper
import com.cuplivo.cuplivo.KelivoApplication
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.StandardMethodCodec
import java.nio.ByteBuffer
import java.util.concurrent.TimeUnit
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
 * The trigger chain around a fired letter (#1007): a fire must always end up
 * either directly dispatched or owned by a foreground-service run, an
 * in-flight letter must not be consumed by a later fire, and the foreground
 * dispatch must recover anything held while no service was running.
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

    @Test fun aBackgroundedProcessStartsARunInsteadOfParkingTheLetter() {
        val messenger = ready()
        app.backgroundRuntime.setForeground(false)
        val dueAt = System.currentTimeMillis() + 60_000

        sync(messenger, "c1", dueAt)
        alarms.fire("c1", dueAt)

        // The letter is owned by a scheduled run, not parked with no service.
        assertTrue(app.backgroundRuntime.hasScheduledRuns)
        assertTrue(messenger.fired().isEmpty())

        // Coming back to the front drains the held letter into Dart.
        app.backgroundRuntime.setForeground(true)
        alarms.dispatchPending()
        val fire = messenger.fired().single()
        assertEquals("c1", (fire.arguments as Map<*, *>)["conversationId"])
        assertEquals(dueAt, dueAtOf(fire))

        // The Dart side completing the run releases the foreground service.
        messenger.call("done", mapOf("conversationId" to "c1"))
        assertFalse(app.backgroundRuntime.hasScheduledRuns)
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
        manager.cancel(
            Shadows.shadowOf(manager).scheduledAlarms.single { it.triggerAtTime == second }.operation,
        )
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

    /** A handoff that never completes must not park the conversation forever,
     *  and releasing it must be visible instead of silent (#1007). */
    @Test fun aDeliveryThatNeverCompletesIsReleasedAndRecorded() {
        val messenger = ready()
        app.backgroundRuntime.setForeground(false)
        ShadowAlarmManager.setCanScheduleExactAlarms(true)
        val dueAt = System.currentTimeMillis() + 60_000

        sync(messenger, "c1", dueAt)
        alarms.fire("c1", dueAt)
        assertTrue(messenger.fired().isEmpty())

        Shadows.shadowOf(Looper.getMainLooper()).idleFor(10, TimeUnit.MINUTES)

        assertTrue(messenger.fired().isEmpty())
        assertFalse(app.backgroundRuntime.hasScheduledRuns)
        assertTrue(
            app.getSharedPreferences("kelivo_background", Context.MODE_PRIVATE)
                .getString("last_error", "")
                .orEmpty()
                .contains("care_delivery_timeout"),
        )

        // The occurrence is released, not replayed: the foreground drain has
        // nothing left to hand over.
        app.backgroundRuntime.setForeground(true)
        alarms.dispatchPending()
        assertTrue(messenger.fired().isEmpty())
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
}
