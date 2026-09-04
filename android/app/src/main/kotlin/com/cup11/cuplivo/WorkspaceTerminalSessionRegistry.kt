package com.cup11.cuplivo

/** Pure session ownership policy kept independent from Android for JVM tests. */
internal class WorkspaceTerminalSessionRegistry<T : Any> {
  data class Entry<T : Any>(
    val workspaceId: String,
    val workspaceHostPath: String,
    val session: T,
    var durable: Boolean,
    var autoStarted: Boolean,
    var attachedViews: Int = 0,
    var running: Boolean = true,
    var exitCode: Int? = null,
  )

  private val entries = linkedMapOf<String, Entry<T>>()

  fun putIfAbsent(entry: Entry<T>): Entry<T> {
    val existing = entries[entry.workspaceId]
    if (existing != null) return existing
    entries[entry.workspaceId] = entry
    return entry
  }

  fun get(workspaceId: String): Entry<T>? = entries[workspaceId]

  fun getByHostPath(workspaceHostPath: String): Entry<T>? =
    entries.values.firstOrNull { it.workspaceHostPath == workspaceHostPath }

  fun getBySession(session: T): Entry<T>? =
    entries.values.firstOrNull { it.session === session }

  fun entries(): List<Entry<T>> = entries.values.toList()

  fun attach(workspaceId: String): Entry<T>? = entries[workspaceId]?.also {
    it.attachedViews += 1
  }

  /** Returns an exited entry that became unowned and should be removed. */
  fun detach(workspaceId: String): Entry<T>? {
    val entry = entries[workspaceId] ?: return null
    if (entry.attachedViews > 0) entry.attachedViews -= 1
    return if (!entry.running && entry.attachedViews == 0) entry else null
  }

  /** Returns true when an exited session has no attached view and may be removed. */
  fun markExited(session: T, exitCode: Int): Boolean {
    val entry = getBySession(session) ?: return false
    entry.running = false
    entry.exitCode = exitCode
    return entry.attachedViews == 0
  }

  fun setDurable(workspaceId: String, durable: Boolean): Entry<T>? =
    entries[workspaceId]?.also { it.durable = durable }

  fun markAutoStarted(workspaceId: String): Entry<T>? =
    entries[workspaceId]?.also { it.autoStarted = true }

  fun remove(workspaceId: String): Entry<T>? = entries.remove(workspaceId)

  fun sessionsToStopOnTaskRemoved(): List<Entry<T>> =
    entries.values.filter { !it.running || !it.durable }

  fun autoSessionToStopIfDetached(workspaceId: String): Entry<T>? =
    entries[workspaceId]?.takeIf {
      it.running && it.autoStarted && it.attachedViews == 0
    }

  fun runningDurableCount(): Int =
    entries.values.count { it.running && it.durable }

  fun allRunning(): List<Entry<T>> = entries.values.filter { it.running }
}

internal interface WorkspaceTerminalKeepAliveDelegate {
  fun activate()
  fun deactivate()
}

internal class WorkspaceTerminalKeepAliveController(
  private val delegate: WorkspaceTerminalKeepAliveDelegate,
) {
  var active: Boolean = false
    private set

  fun sync(runningDurableCount: Int) {
    val next = runningDurableCount > 0
    if (next == active) return
    if (next) delegate.activate() else delegate.deactivate()
    active = next
  }
}
