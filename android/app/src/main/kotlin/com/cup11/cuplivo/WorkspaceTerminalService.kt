package com.cup11.cuplivo

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Binder
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import com.termux.shared.shell.command.ExecutionCommand
import com.termux.shared.shell.command.environment.IShellEnvironment
import com.termux.shared.termux.shell.TermuxShellManager
import com.termux.shared.termux.shell.command.runner.terminal.TermuxSession
import com.termux.shared.termux.terminal.TermuxTerminalSessionClientBase
import com.termux.terminal.TerminalSession
import java.util.HashMap

internal data class WorkspaceTerminalLaunchRequest(
  val workspaceId: String,
  val workspaceHostPath: String,
  val executable: String,
  val arguments: List<String>,
  val environment: Map<String, String>,
  val workingDirectory: String,
  val durable: Boolean,
  val autoStarted: Boolean,
  val notification: WorkspaceTerminalNotification,
)

internal data class WorkspaceTerminalNotification(
  val channelName: String,
  val title: String,
  val text: String,
)

class WorkspaceTerminalService : Service(), TermuxSession.TermuxSessionClient {
  inner class LocalBinder : Binder() {
    val service: WorkspaceTerminalService
      get() = this@WorkspaceTerminalService
  }

  private val binder = LocalBinder()
  private val handler = Handler(Looper.getMainLooper())
  private val registry = WorkspaceTerminalSessionRegistry<TermuxSession>()
  private val views = mutableMapOf<String, MutableSet<WorkspaceTerminalPlatformView>>()
  private val pendingStopCallbacks =
    mutableMapOf<String, MutableList<(Boolean) -> Unit>>()
  private val stopRequested = mutableSetOf<String>()
  private lateinit var shellManager: TermuxShellManager

  private var notification: WorkspaceTerminalNotification? = null
  private var wakeLock: PowerManager.WakeLock? = null
  private var wifiLock: WifiManager.WifiLock? = null

  private val keepAliveController = WorkspaceTerminalKeepAliveController(
    object : WorkspaceTerminalKeepAliveDelegate {
      override fun activate() {
        try {
          enterForeground()
          acquireLocks()
        } catch (error: Exception) {
          releaseLocks()
          leaveForeground()
          throw error
        }
      }

      override fun deactivate() {
        releaseLocks()
        leaveForeground()
      }
    },
  )

  private val terminalSessionClient = object : TermuxTerminalSessionClientBase() {
    override fun onTextChanged(changedSession: TerminalSession) {
      registry.getBySessionWrapper(changedSession)?.let { entry ->
        views[entry.workspaceId]?.forEach { it.onScreenChanged() }
      }
    }

    override fun onTitleChanged(updatedSession: TerminalSession) {
      registry.getBySessionWrapper(updatedSession)?.let { entry ->
        views[entry.workspaceId]?.forEach { it.onScreenChanged() }
      }
    }

    override fun onSessionFinished(finishedSession: TerminalSession) {
      handleSessionFinished(finishedSession)
    }

    override fun onCopyTextToClipboard(session: TerminalSession, text: String) {
      val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
      val label = applicationInfo.loadLabel(packageManager)
      clipboard?.setPrimaryClip(ClipData.newPlainText(label, text))
    }

    override fun onPasteTextFromClipboard(session: TerminalSession?) {
      val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
      val text = clipboard?.primaryClip?.getItemAt(0)?.coerceToText(this@WorkspaceTerminalService)
      if (!text.isNullOrEmpty()) session?.emulator?.paste(text.toString())
    }

    override fun setTerminalShellPid(session: TerminalSession, pid: Int) {
      registry.getBySessionWrapper(session)?.session?.executionCommand?.mPid = pid
    }
  }

  override fun onCreate() {
    super.onCreate()
    shellManager = TermuxShellManager.init(this)
  }

  override fun onBind(intent: Intent?): IBinder = binder

  override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int =
    START_NOT_STICKY

  override fun onTaskRemoved(rootIntent: Intent?) {
    registry.sessionsToStopOnTaskRemoved().forEach { entry ->
      stopSession(entry.workspaceId) { success ->
        if (!success) {
          Log.e(TAG, "Timed out stopping ${entry.workspaceId} after task removal")
        }
      }
    }
    super.onTaskRemoved(rootIntent)
  }

  override fun onDestroy() {
    registry.entries().forEach { entry ->
      entry.session.terminalSession.finishIfRunning()
      shellManager.mTermuxSessions.remove(entry.session)
      registry.remove(entry.workspaceId)
    }
    pendingStopCallbacks.values.flatten().forEach { it(false) }
    pendingStopCallbacks.clear()
    releaseLocks()
    leaveForeground()
    super.onDestroy()
  }

  internal fun startSession(
    request: WorkspaceTerminalLaunchRequest,
  ): Map<String, Any?> {
    notification = request.notification
    registry.get(request.workspaceId)?.let { existing ->
      if (existing.running) {
        if (request.autoStarted) registry.markAutoStarted(request.workspaceId)
        if (request.durable != existing.durable) {
          updateDurability(existing, request.durable)
        }
        return stateMap(existing)
      }
      removeEntry(request.workspaceId)
    }

    val serviceIntent = Intent(applicationContext, WorkspaceTerminalService::class.java)
    // Session creation is only requested while Cuplivo has a foreground
    // activity. Start normally, then promote synchronously once a durable
    // session has entered the registry; this avoids an orphaned
    // startForegroundService deadline when PTY creation fails.
    startService(serviceIntent)
    val command = ExecutionCommand(
      TermuxShellManager.getNextShellId(),
      request.executable,
      request.arguments.toTypedArray(),
      null,
      request.workingDirectory,
      ExecutionCommand.Runner.TERMINAL_SESSION.getName(),
      false,
    ).also {
      it.shellName = request.workspaceId
      it.commandLabel = request.workspaceId
      it.terminalTranscriptRows = TRANSCRIPT_ROWS
    }
    val session = TermuxSession.execute(
      this,
      command,
      terminalSessionClient,
      this,
      CuplivoSandboxShellEnvironment(request),
      null,
      false,
    ) ?: run {
      if (registry.entries().isEmpty()) stopSelf()
      throw IllegalStateException("TermuxSession failed to start")
    }

    // A hidden auto-start session has no view to provide its first size. Start
    // the PTY before publishing the session into either ownership registry so
    // a native spawn failure cannot leave a visible but unusable entry.
    val terminalSession = session.terminalSession
    try {
      terminalSession.updateSize(80, 24, 8, 16)
      command.mPid = terminalSession.pid
    } catch (error: Exception) {
      if (terminalSession.pid > 0) terminalSession.finishIfRunning()
      if (registry.entries().isEmpty()) stopSelf()
      throw error
    }

    val entry = WorkspaceTerminalSessionRegistry.Entry(
      workspaceId = request.workspaceId,
      workspaceHostPath = request.workspaceHostPath,
      session = session,
      durable = request.durable,
      autoStarted = request.autoStarted,
    )
    registry.putIfAbsent(entry)
    shellManager.mTermuxSessions.add(session)

    try {
      syncKeepAlive()
      views[request.workspaceId]?.forEach { view ->
        registry.attach(request.workspaceId)
        view.attachSession(terminalSession)
      }
    } catch (error: Exception) {
      registry.remove(request.workspaceId)
      shellManager.mTermuxSessions.remove(session)
      if (terminalSession.pid > 0) terminalSession.finishIfRunning()
      syncKeepAlive()
      notifyState(request.workspaceId)
      if (registry.entries().isEmpty()) stopSelf()
      throw error
    }
    notifyState(request.workspaceId)
    return stateMap(entry)
  }

  internal fun getSessionState(workspaceId: String): Map<String, Any?> =
    registry.get(workspaceId)?.let(::stateMap) ?: absentState()

  internal fun setDurable(
    workspaceId: String,
    durable: Boolean,
    strings: WorkspaceTerminalNotification,
  ): Map<String, Any?> {
    notification = strings
    val entry = registry.get(workspaceId) ?: return absentState()
    updateDurability(entry, durable)
    notifyState(workspaceId)
    return stateMap(entry)
  }

  internal fun stopSession(workspaceId: String, callback: (Boolean) -> Unit) {
    val entry = registry.get(workspaceId)
    if (entry == null) {
      callback(true)
      return
    }
    if (!entry.running) {
      removeEntry(workspaceId)
      callback(true)
      return
    }
    pendingStopCallbacks.getOrPut(workspaceId) { mutableListOf() }.add(callback)
    if (!stopRequested.add(workspaceId)) return
    entry.session.terminalSession.finishIfRunning()
    handler.postDelayed({
      val callbacks = pendingStopCallbacks.remove(workspaceId) ?: return@postDelayed
      stopRequested.remove(workspaceId)
      callbacks.forEach { it(false) }
    }, STOP_TIMEOUT_MS)
  }

  internal fun stopSessionForWorkspacePath(
    workspaceHostPath: String,
    callback: (Boolean) -> Unit,
  ) {
    val entry = registry.getByHostPath(workspaceHostPath)
    if (entry == null) callback(true) else stopSession(entry.workspaceId, callback)
  }

  internal fun stopAutoSessionIfDetached(
    workspaceId: String,
    callback: (Boolean) -> Unit,
  ) {
    val entry = registry.autoSessionToStopIfDetached(workspaceId)
    if (entry == null) callback(true) else stopSession(workspaceId, callback)
  }

  internal fun stopAllSessions(callback: (Boolean) -> Unit) {
    val ids = registry.entries().map { it.workspaceId }
    if (ids.isEmpty()) {
      callback(true)
      return
    }
    var remaining = ids.size
    var allSucceeded = true
    ids.forEach { id ->
      stopSession(id) { success ->
        allSucceeded = allSucceeded && success
        remaining -= 1
        if (remaining == 0) callback(allSucceeded)
      }
    }
  }

  internal fun attachView(workspaceId: String, view: WorkspaceTerminalPlatformView) {
    val set = views.getOrPut(workspaceId) { linkedSetOf() }
    if (set.add(view)) {
      val entry = registry.attach(workspaceId)
      if (entry != null) view.attachSession(entry.session.terminalSession)
    }
    view.onSessionStateChanged(getSessionState(workspaceId))
  }

  internal fun detachView(workspaceId: String, view: WorkspaceTerminalPlatformView) {
    if (views[workspaceId]?.remove(view) != true) return
    if (views[workspaceId].isNullOrEmpty()) views.remove(workspaceId)
    val removable = registry.detach(workspaceId)
    if (removable != null) removeEntry(workspaceId)
  }

  override fun onTermuxSessionExited(termuxSession: TermuxSession) {
    // Session retention/removal is decided in handleSessionFinished after the
    // Termux execution state has been finalized.
  }

  private fun handleSessionFinished(terminalSession: TerminalSession) {
    val entry = registry.getBySessionWrapper(terminalSession) ?: return
    entry.session.finish()
    val removeWhenUnattached = registry.markExited(
      entry.session,
      terminalSession.exitStatus,
    )
    notifyState(entry.workspaceId)
    pendingStopCallbacks.remove(entry.workspaceId)?.let { callbacks ->
      stopRequested.remove(entry.workspaceId)
      removeEntry(entry.workspaceId)
      callbacks.forEach { it(true) }
      return
    }
    if (removeWhenUnattached) removeEntry(entry.workspaceId) else syncKeepAlive()
  }

  private fun removeEntry(workspaceId: String) {
    val entry = registry.remove(workspaceId) ?: return
    shellManager.mTermuxSessions.remove(entry.session)
    syncKeepAlive()
    notifyState(workspaceId)
    if (registry.entries().isEmpty()) stopSelf()
  }

  private fun notifyState(workspaceId: String) {
    val state = getSessionState(workspaceId)
    views[workspaceId]?.forEach { it.onSessionStateChanged(state) }
  }

  private fun stateMap(
    entry: WorkspaceTerminalSessionRegistry.Entry<TermuxSession>,
  ): Map<String, Any?> {
    val terminal = entry.session.terminalSession
    return mapOf(
      "state" to if (entry.running) "running" else "exited",
      "sessionId" to terminal.mHandle,
      "processId" to terminal.pid.takeIf { it > 0 },
      "exitCode" to entry.exitCode,
      "durable" to entry.durable,
      "autoStarted" to entry.autoStarted,
      "attachedViews" to entry.attachedViews,
    )
  }

  private fun absentState(): Map<String, Any?> = mapOf(
    "state" to "absent",
    "durable" to false,
    "autoStarted" to false,
    "attachedViews" to 0,
  )

  private fun syncKeepAlive() {
    keepAliveController.sync(registry.runningDurableCount())
  }

  private fun updateDurability(
    entry: WorkspaceTerminalSessionRegistry.Entry<TermuxSession>,
    durable: Boolean,
  ) {
    if (entry.durable == durable) return
    val previous = entry.durable
    registry.setDurable(entry.workspaceId, durable)
    try {
      syncKeepAlive()
    } catch (error: Exception) {
      registry.setDurable(entry.workspaceId, previous)
      syncKeepAlive()
      throw error
    }
  }

  private fun WorkspaceTerminalSessionRegistry<TermuxSession>.getBySessionWrapper(
    terminalSession: TerminalSession,
  ): WorkspaceTerminalSessionRegistry.Entry<TermuxSession>? =
    entries().firstOrNull { it.session.terminalSession === terminalSession }

  @SuppressLint("WakelockTimeout")
  private fun acquireLocks() {
    if (wakeLock == null) {
      val power = getSystemService(Context.POWER_SERVICE) as PowerManager
      wakeLock = power.newWakeLock(
        PowerManager.PARTIAL_WAKE_LOCK,
        "$packageName:workspace-terminal",
      ).also {
        it.setReferenceCounted(false)
        it.acquire()
      }
    }
    if (wifiLock == null) {
      val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
      @Suppress("DEPRECATION")
      wifiLock = wifi.createWifiLock(
        WifiManager.WIFI_MODE_FULL_HIGH_PERF,
        "$packageName:workspace-terminal",
      ).also {
        it.setReferenceCounted(false)
        it.acquire()
      }
    }
  }

  private fun releaseLocks() {
    wakeLock?.let { if (it.isHeld) it.release() }
    wakeLock = null
    wifiLock?.let { if (it.isHeld) it.release() }
    wifiLock = null
  }

  private fun enterForeground() {
    val notificationText = notification
      ?: throw IllegalStateException("Localized terminal notification text is unavailable")
    val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      manager.createNotificationChannel(
        NotificationChannel(
          NOTIFICATION_CHANNEL_ID,
          notificationText.channelName,
          NotificationManager.IMPORTANCE_LOW,
        ),
      )
    }
    val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
    val pendingIntent = launchIntent?.let {
      PendingIntent.getActivity(
        this,
        0,
        it,
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
      )
    }
    val built: Notification = NotificationCompat.Builder(
      this,
      NOTIFICATION_CHANNEL_ID,
    )
      .setSmallIcon(R.mipmap.ic_launcher)
      .setContentTitle(notificationText.title)
      .setContentText(notificationText.text)
      .setContentIntent(pendingIntent)
      .setOngoing(true)
      .setSilent(true)
      .setCategory(NotificationCompat.CATEGORY_SERVICE)
      .build()
    if (Build.VERSION.SDK_INT >= 34) {
      startForeground(
        NOTIFICATION_ID,
        built,
        ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
      )
    } else {
      startForeground(NOTIFICATION_ID, built)
    }
  }

  private fun leaveForeground() {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
      stopForeground(STOP_FOREGROUND_REMOVE)
    } else {
      @Suppress("DEPRECATION")
      stopForeground(true)
    }
  }

  companion object {
    private const val TAG = "WorkspaceTerminal"
    private const val TRANSCRIPT_ROWS = 5_000
    private const val STOP_TIMEOUT_MS = 7_000L
    private const val NOTIFICATION_CHANNEL_ID = "workspace_terminal_keep_alive"
    private const val NOTIFICATION_ID = 4107
  }
}

private class CuplivoSandboxShellEnvironment(
  private val request: WorkspaceTerminalLaunchRequest,
) : IShellEnvironment {
  override fun getDefaultWorkingDirectoryPath(): String = request.workingDirectory

  override fun getDefaultBinPath(): String = request.executable.substringBeforeLast('/', "/")

  override fun setupShellCommandArguments(
    fileToExecute: String,
    arguments: Array<out String>?,
  ): Array<String> = arrayOf(fileToExecute, *(arguments ?: emptyArray()))

  override fun setupShellCommandEnvironment(
    currentPackageContext: Context,
    executionCommand: ExecutionCommand,
  ): HashMap<String, String> = HashMap<String, String>().also { environment ->
    environment.putAll(System.getenv())
    environment.putAll(request.environment)
  }
}
