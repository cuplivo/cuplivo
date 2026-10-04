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
