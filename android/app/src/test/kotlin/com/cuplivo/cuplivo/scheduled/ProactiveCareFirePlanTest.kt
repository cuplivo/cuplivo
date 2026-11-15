package com.cuplivo.cuplivo.scheduled

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The whole point of the plan decision: a fire either dispatches while Dart is
 * listening, or it starts the same service-backed run a scheduled task uses.
 * Never a third state — a fire held with no service has no channel listener,
 * which is how letters used to get lost.
 *
 * The listening side is `ready`, and it is deliberately *not* tied to the
 * Activity's lifecycle: a backgrounded process with a live engine can deliver
 * (#1007: the letter that surfaced only when the app came back to the front).
 */
class ProactiveCareFirePlanTest {
    @Test fun aListeningDartSideDispatchesDirectly() {
        assertEquals(CareFirePlan.Direct, careFirePlan(ready = true))
    }

    @Test fun aFreshChannelGoesThroughTheForegroundServiceRun() {
        // Dart has not attached yet: the service is the only owner that can
        // create a listener for the run.
        assertEquals(CareFirePlan.Service, careFirePlan(ready = false))
    }
}

/**
 * The carrier is orthogonal to the plan: it says whether the *process* is kept
 * alive while the letter is generated, and the plan says who dispatches it.
 *
 * The cell that used to be missing is `background + Direct`. It dispatched
 * (the listener existed) but took no run, so the model round trip ran in a
 * cached process that Android freezes and whose network it suspends. The letter
 * was generated whenever the process was next unfrozen — in the field, right
 * after the user sent a message.
 */
class ProactiveCareCarrierTest {
    @Test fun aForegroundDirectHandOffNeedsNoCarrier() {
        // The Activity is in front: the process is already active.
        assertEquals(false, careNeedsCarrier(foreground = true, plan = CareFirePlan.Direct))
    }

    @Test fun aBackgroundDirectHandOffTakesTheCarrier() {
        // The regression: a live listener is not process protection.
        assertEquals(true, careNeedsCarrier(foreground = false, plan = CareFirePlan.Direct))
    }

    @Test fun theServicePlanAlwaysTakesTheCarrier() {
        // `dispatchPending` waits for a service: a fresh channel needs the run
        // whether or not the Activity happens to be in front.
        assertEquals(true, careNeedsCarrier(foreground = true, plan = CareFirePlan.Service))
        assertEquals(true, careNeedsCarrier(foreground = false, plan = CareFirePlan.Service))
    }
}
