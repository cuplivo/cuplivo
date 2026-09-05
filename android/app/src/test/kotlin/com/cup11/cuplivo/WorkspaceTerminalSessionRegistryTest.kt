package com.cup11.cuplivo

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class WorkspaceTerminalSessionRegistryTest {
  private fun entry(
    workspaceId: String,
    session: Any = Any(),
    durable: Boolean = false,
    autoStarted: Boolean = false,
  ) = WorkspaceTerminalSessionRegistry.Entry(
    workspaceId = workspaceId,
    workspaceHostPath = "/workspaces/$workspaceId",
    session = session,
    durable = durable,
    autoStarted = autoStarted,
  )

  @Test
  fun oneWorkspaceKeepsTheFirstSession() {
    val registry = WorkspaceTerminalSessionRegistry<Any>()
    val first = entry("workspace-a")
    val duplicate = entry("workspace-a")

    assertSame(first, registry.putIfAbsent(first))
    assertSame(first, registry.putIfAbsent(duplicate))
    assertSame(first.session, registry.get("workspace-a")!!.session)
    assertEquals(1, registry.entries().size)
  }

  @Test
  fun separateWorkspacesCanOwnSessionsConcurrently() {
    val registry = WorkspaceTerminalSessionRegistry<Any>()
    registry.putIfAbsent(entry("workspace-a"))
    registry.putIfAbsent(entry("workspace-b"))

    assertEquals(
      listOf("workspace-a", "workspace-b"),
      registry.allRunning().map { it.workspaceId },
    )
  }

  @Test
  fun detachingAViewDoesNotStopARunningSession() {
    val registry = WorkspaceTerminalSessionRegistry<Any>()
    registry.putIfAbsent(entry("workspace-a"))
    registry.attach("workspace-a")

    assertNull(registry.detach("workspace-a"))
    assertTrue(registry.get("workspace-a")!!.running)
    assertEquals(0, registry.get("workspace-a")!!.attachedViews)
  }

  @Test
  fun reattachingUsesTheSameRunningSession() {
    val registry = WorkspaceTerminalSessionRegistry<Any>()
    val session = Any()
    registry.putIfAbsent(entry("workspace-a", session))
    registry.attach("workspace-a")
    registry.detach("workspace-a")

    val reattached = registry.attach("workspace-a")

    assertSame(session, reattached!!.session)
    assertEquals(1, reattached.attachedViews)
  }

  @Test
  fun anExitedSessionLivesUntilItsLastAttachedViewDetaches() {
    val registry = WorkspaceTerminalSessionRegistry<Any>()
    val session = Any()
    registry.putIfAbsent(entry("workspace-a", session))
    registry.attach("workspace-a")

    assertFalse(registry.markExited(session, 17))
    assertEquals(17, registry.get("workspace-a")!!.exitCode)
    assertSame(registry.get("workspace-a"), registry.detach("workspace-a"))
  }

  @Test
  fun taskRemovalStopsOnlyOrdinarySessions() {
    val registry = WorkspaceTerminalSessionRegistry<Any>()
    registry.putIfAbsent(entry("ordinary"))
    registry.putIfAbsent(entry("durable", durable = true))

    assertEquals(
      listOf("ordinary"),
      registry.sessionsToStopOnTaskRemoved().map { it.workspaceId },
    )
  }

  @Test
  fun taskRemovalAlsoCleansExitedEntries() {
    val registry = WorkspaceTerminalSessionRegistry<Any>()
    val exited = entry("exited", durable = true)
    registry.putIfAbsent(exited)
    registry.markExited(exited.session, 0)

    assertEquals(
      listOf("exited"),
      registry.sessionsToStopOnTaskRemoved().map { it.workspaceId },
    )
  }

  @Test
  fun onlyDetachedAutoStartedSessionIsEligibleForAutoStop() {
    val registry = WorkspaceTerminalSessionRegistry<Any>()
    registry.putIfAbsent(entry("auto", autoStarted = true))

    assertEquals("auto", registry.autoSessionToStopIfDetached("auto")!!.workspaceId)
    registry.attach("auto")
    assertNull(registry.autoSessionToStopIfDetached("auto"))
  }

  @Test
  fun keepAliveReferenceTransitionsOnlyAtZeroBoundary() {
    val calls = mutableListOf<String>()
    val controller = WorkspaceTerminalKeepAliveController(
      object : WorkspaceTerminalKeepAliveDelegate {
        override fun activate() {
          calls += "activate"
        }

        override fun deactivate() {
          calls += "deactivate"
        }
      },
    )

    controller.sync(0)
    controller.sync(1)
    controller.sync(2)
    controller.sync(1)
    controller.sync(0)
    controller.sync(0)

    assertEquals(listOf("activate", "deactivate"), calls)
    assertFalse(controller.active)
  }

  @Test
  fun failedKeepAliveActivationDoesNotClaimForegroundState() {
    val controller = WorkspaceTerminalKeepAliveController(
      object : WorkspaceTerminalKeepAliveDelegate {
        override fun activate() {
          throw IllegalStateException("foreground failed")
        }

        override fun deactivate() = Unit
      },
    )

    var failed = false
    try {
      controller.sync(1)
    } catch (_: IllegalStateException) {
      failed = true
      // Expected: the service can retry promotion on the next state sync.
    }

    assertTrue(failed)
    assertFalse(controller.active)
  }
}
