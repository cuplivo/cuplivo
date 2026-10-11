package com.cuplivo.cuplivo.scheduled

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The whole point of the plan decision: a fire either dispatches while the app
 * owns the foreground, or it starts the same service-backed run a scheduled
 * task uses. Never a third state — a fire held with no service has no channel
 * listener and no deadline, which is how letters used to get lost.
 */
class ProactiveCareFirePlanTest {
    @Test fun aForegroundAppWithAListeningDartSideDispatchesDirectly() {
        assertEquals(CareFirePlan.Direct, careFirePlan(ready = true, foreground = true))
    }

    @Test fun everyOtherStateGoesThroughTheForegroundServiceRun() {
        // Dart has not attached yet.
        assertEquals(CareFirePlan.Service, careFirePlan(ready = false, foreground = true))
        // The Activity stopped: screen off, another app in front, or the
        // process was warmed in the background.
        assertEquals(CareFirePlan.Service, careFirePlan(ready = true, foreground = false))
        assertEquals(CareFirePlan.Service, careFirePlan(ready = false, foreground = false))
    }
}
