package com.cuplivo.cuplivo.scheduled

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
import org.robolectric.annotation.Config

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
        val first = System.currentTimeMillis() + 60_000

        sync(messenger, "c1", first)
        alarms.fire("c1", first)
        assertEquals(1, messenger.fired().size)

        // A rescheduled occurrence arrives while the first is still in flight:
        // it stays in the registry instead of being consumed and dropped.
        val second = first + 60_000
        sync(messenger, "c1", second)
        alarms.fire("c1", second)

        assertEquals(1, messenger.fired().size)
        assertEquals(second, prefs.getLong("alarm:c1", -1))

        messenger.call("done", mapOf("conversationId" to "c1"))
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
}
