package com.cup11.cuplivo

import android.app.Activity
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Process as AndroidProcess
import android.util.Log
import android.view.WindowManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.nio.charset.StandardCharsets
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import java.util.zip.ZipFile

/**
 * Android bridge for the Linux sandbox (proot when the native libs ship).
 *
 * Rootfs download and apt orchestration live in Dart; this plugin only
 * extracts the archive and runs commands inside the guest.
 */
class LinuxSandboxPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware {
  private lateinit var channel: MethodChannel
  private lateinit var appContext: Context
  private var activity: Activity? = null
  private var volumeCtrlChannel: EventChannel? = null
  private var volumeCtrlSink: EventChannel.EventSink? = null
  @Volatile internal var volumeCtrlEnabled: Boolean = false

  private val volumeCtrlStreamHandler = object : EventChannel.StreamHandler {
    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
      volumeCtrlSink = events
    }

    override fun onCancel(arguments: Any?) {
      volumeCtrlSink = null
    }
  }
  private val mainHandler = Handler(Looper.getMainLooper())
  private val attached = AtomicBoolean(false)
  private val attachmentGeneration = AtomicLong(0)
  private val executions = ConcurrentHashMap<String, AndroidExecution>()
  private var executionExecutor: ThreadPoolExecutor? = null

  /// Cached capability probe. hasProot() can fall through to an APK copy on
  /// first call (disk I/O), which must not run on the UI thread on every
  /// isSupported call. The native libs are fixed per install, so caching is
  /// safe; reset on attach to reflect a fresh engine.
  @Volatile
  private var prootSupport: Boolean? = null

  /// Guards the first-time proot probe so concurrent isSupported calls
  /// cannot race on the APK copy (both would write the same fallback file).
  /// Deliberately not `this`: engine attach/detach also synchronize on the
  /// plugin, and a slow probe must not block engine teardown.
  private val prootProbeLock = Any()

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    attachmentGeneration.incrementAndGet()
    prootSupport = null
    appContext = binding.applicationContext
    channel = MethodChannel(binding.binaryMessenger, "cuplivo/linux_sandbox")
    channel.setMethodCallHandler(this)
    volumeCtrlChannel = EventChannel(
      binding.binaryMessenger,
      "cuplivo/linux_sandbox/volume_ctrl",
    )
    volumeCtrlChannel?.setStreamHandler(volumeCtrlStreamHandler)
    synchronized(this) {
      executionExecutor = ThreadPoolExecutor(
        2,
        2,
        0L,
        TimeUnit.MILLISECONDS,
        ArrayBlockingQueue(4),
      )
    }
    attached.set(true)
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    attached.set(false)
    channel.setMethodCallHandler(null)
    volumeCtrlEnabled = false
    volumeCtrlSink = null
    volumeCtrlChannel?.setStreamHandler(null)
    volumeCtrlChannel = null
    executions.values.forEach { it.cancel() }
    executions.clear()
    synchronized(this) {
      executionExecutor?.shutdownNow()
      executionExecutor = null
    }
  }

  override fun onAttachedToActivity(binding: ActivityPluginBinding) {
    activity = binding.activity
    if (binding.activity is MainActivity) {
      (binding.activity as MainActivity).volumeCtrlPlugin = this
    }
  }

  override fun onDetachedFromActivityForConfigChanges() {
    detachActivity(resetIntercept = false)
  }

  override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
    onAttachedToActivity(binding)
  }

  override fun onDetachedFromActivity() {
    detachActivity(resetIntercept = true)
  }

  private fun detachActivity(resetIntercept: Boolean) {
    if (resetIntercept) {
      volumeCtrlEnabled = false
    }
    (activity as? MainActivity)?.volumeCtrlPlugin = null
    activity = null
  }

  internal fun emitVolumeCtrl(down: Boolean) {
    volumeCtrlSink?.success(down)
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    val generation = attachmentGeneration.get()
    when (call.method) {
      "isSupported" -> {
        // Cached capability probe. hasProot() is usually a cheap local file
        // probe but can fall through to an APK copy on first use (disk I/O),
        // which must never run on the platform (UI) thread. The first probe
        // therefore runs on a background thread — deliberately NOT the
        // bounded execution executor, so a saturated executor can never
        // surface sandbox_busy and make Dart misclassify the sandbox as
        // unsupported — and the cached result keeps every later call cheap.
        val cached = prootSupport
        if (cached != null) {
          result.success(cached)
          return
        }
        Thread {
          val supported = synchronized(prootProbeLock) {
            prootSupport ?: hasProot().also { prootSupport = it }
          }
          mainHandler.post { result.success(supported) }
        }.start()
      }
      "getAbi" -> result.success(primaryAbi())
      "extractRootfs" -> {
        val workspace = call.argument<String>("workspacePath")
        val archivePath = call.argument<String>("archivePath")
        if (workspace.isNullOrBlank() || archivePath.isNullOrBlank()) {
          result.error("bad_args", "workspacePath and archivePath required", null)
          return
        }
        enqueueRootfsExtraction(
          workspace = workspace,
          archivePath = archivePath,
          requestId = call.argument<String>("requestId"),
          result = result,
        )
      }
      // Backward-compatible alias: if callers still pass url, reject clearly.
      "installRootfs" -> {
        val workspace = call.argument<String>("workspacePath")
        val archivePath = call.argument<String>("archivePath")
        val url = call.argument<String>("url")
        if (!archivePath.isNullOrBlank() && !workspace.isNullOrBlank()) {
          enqueueRootfsExtraction(
            workspace = workspace,
            archivePath = archivePath,
            requestId = call.argument<String>("requestId"),
            result = result,
          )
        } else {
          result.error(
            "bad_args",
            "installRootfs now expects archivePath (download in Dart). url=${url ?: "null"}",
            null,
          )
        }
      }
      "exec" -> {
        val workspace = call.argument<String>("workspacePath")
        val command = call.argument<String>("command")
        val cwd = call.argument<String>("cwd")
        val timeoutMs = (call.argument<Number>("timeoutMs") ?: 30_000)
          .toLong()
          .coerceIn(1L, MAX_EXEC_TIMEOUT_MS)
        val requestId = call.argument<String>("requestId")?.takeIf { it.isNotBlank() }
          ?: "shell_${System.nanoTime()}"
        if (workspace.isNullOrBlank() || command.isNullOrBlank()) {
          result.error("bad_args", "workspacePath and command required", null)
          return
        }
        val execution = AndroidExecution(requestId, attachmentGeneration.get())
        if (executions.putIfAbsent(requestId, execution) != null) {
          result.error("duplicate_request", "requestId already active", null)
          return
        }
        val executor = executionExecutor
        if (executor == null || executor.isShutdown) {
          executions.remove(requestId, execution)
          result.error("sandbox_detached", "sandbox executor is unavailable", null)
          return
        }
        try {
          executor.execute {
            if (!attached.get() || execution.generation != attachmentGeneration.get()) {
              executions.remove(requestId, execution)
              return@execute
            }
            // Clear any interrupt status left by a previously cancelled task
            // on this pooled thread: a stale flag would make waitFor/read
            // throw immediately and misclassify a healthy command as timed out.
            Thread.interrupted()
            execution.workerThread = Thread.currentThread()
            if (execution.cancelled.get()) {
              completeSuccess(execution, result, cancelledResult())
              execution.workerThread = null
              executions.remove(requestId, execution)
              return@execute
            }
            try {
              val map = GuestCommandRunner(appContext).execute(
                workspacePath = workspace,
                command = command,
                cwd = cwd,
                timeoutMs = timeoutMs,
                execution = execution,
              )
              // The map's cancelled flag was decided atomically with
              // finished/timedOut inside capture(); a cancel arriving after
              // the command completed must not discard its real result.
              completeSuccess(execution, result, map)
            } catch (e: Exception) {
              if (execution.cancelled.get()) {
                completeSuccess(execution, result, cancelledResult())
              } else {
                completeError(execution, result, "exec_failed", e)
              }
            } finally {
              execution.workerThread = null
              executions.remove(requestId, execution)
            }
          }
        } catch (_: RejectedExecutionException) {
          executions.remove(requestId, execution)
          result.error("sandbox_busy", "sandbox executor queue is full", null)
        }
      }
      "cancel" -> {
        val requestId = call.argument<String>("requestId")
        if (requestId.isNullOrBlank()) {
          result.error("bad_args", "requestId required", null)
          return
        }
        val execution = executions[requestId]
        if (execution == null) {
          result.success(false)
          return
        }
        execution.cancel()
        result.success(true)
      }
      "ptyLaunchSpec" -> {
        val workspace = call.argument<String>("workspacePath")
        if (workspace.isNullOrBlank()) {
          result.error("bad_args", "workspacePath required", null)
          return
        }
        Thread {
          try {
            val spec = GuestCommandRunner(appContext).ptyLaunchSpec(workspace)
            android.os.Handler(android.os.Looper.getMainLooper()).post {
              result.success(spec)
            }
          } catch (e: Exception) {
            android.os.Handler(android.os.Looper.getMainLooper()).post {
              result.error("pty_spec_failed", e.message, null)
            }
          }
        }.start()
      }
      "setKeepScreenOn" -> {
        val enabled = call.argument<Boolean>("enabled") == true
        val act = activity
        if (act == null) {
          if (enabled) {
            result.error("no_activity", "Activity not attached", null)
          } else {
            result.success(null)
          }
          return
        }
        act.runOnUiThread {
          if (enabled) {
            act.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
          } else {
            act.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
          }
        }
        result.success(null)
      }
      "setVolumeCtrlIntercept" -> {
        volumeCtrlEnabled = call.argument<Boolean>("enabled") == true
        result.success(null)
      }
      else -> result.notImplemented()
    }
  }

  private fun completeSuccess(
    execution: AndroidExecution,
    result: MethodChannel.Result,
    value: Any?,
  ) {
    if (!execution.completed.compareAndSet(false, true)) return
    mainHandler.post {
      if (attached.get() && execution.generation == attachmentGeneration.get()) {
        result.success(value)
      }
    }
  }

  private fun completeError(
    execution: AndroidExecution,
    result: MethodChannel.Result,
    code: String,
    error: Exception,
  ) {
    if (!execution.completed.compareAndSet(false, true)) return
    mainHandler.post {
      if (attached.get() && execution.generation == attachmentGeneration.get()) {
        result.error(code, error.message ?: error.javaClass.simpleName, null)
      }
    }
  }

  private fun enqueueRootfsExtraction(
    workspace: String,
    archivePath: String,
    requestId: String?,
    result: MethodChannel.Result,
  ) {
    val id = requestId?.takeIf { it.isNotBlank() }
      ?: "extract_${System.nanoTime()}"
    val execution = AndroidExecution(id, attachmentGeneration.get())
    if (executions.putIfAbsent(id, execution) != null) {
      result.error("duplicate_request", "requestId already active", null)
      return
    }
    val executor = executionExecutor
    if (executor == null || executor.isShutdown) {
      executions.remove(id, execution)
      result.error("sandbox_detached", "sandbox executor is unavailable", null)
      return
    }
        try {
          executor.execute {
            if (!attached.get() || execution.generation != attachmentGeneration.get()) {
              executions.remove(id, execution)
              return@execute
            }
            // Clear any interrupt status left by a previously cancelled task
            // on this pooled thread: a stale flag would make the extractor
            // abort spuriously and report a bogus cancellation.
            Thread.interrupted()
            execution.workerThread = Thread.currentThread()
            if (execution.cancelled.get()) {
              completeError(
                execution,
                result,
                "cancelled",
                IllegalStateException("rootfs extraction cancelled"),
              )
              execution.workerThread = null
              executions.remove(id, execution)
              return@execute
            }
            try {
              extractRootfs(workspace, archivePath)
              if (execution.cancelled.get()) {
                completeError(
                  execution,
                  result,
                  "cancelled",
                  IllegalStateException("rootfs extraction cancelled"),
                )
              } else {
                completeSuccess(execution, result, null)
              }
            } catch (e: InterruptedException) {
              // TarStream.alive() throws when the cancel path interrupted
              // this thread; report cancellation instead of a generic
              // extraction failure.
              if (execution.cancelled.get()) {
                completeError(
                  execution,
                  result,
                  "cancelled",
                  IllegalStateException("rootfs extraction cancelled"),
                )
              } else {
                Thread.currentThread().interrupt()
                completeError(execution, result, "extract_failed", e)
              }
            } catch (e: Exception) {
              completeError(execution, result, "extract_failed", e)
            } finally {
              execution.workerThread = null
              executions.remove(id, execution)
            }
          }
        } catch (_: RejectedExecutionException) {
          executions.remove(id, execution)
          result.error("sandbox_busy", "sandbox executor queue is full", null)
        }
      }

  private fun cancelledResult(): Map<String, Any?> = mapOf(
    "exitCode" to -1,
    "stdout" to "",
    "stderr" to "",
    "timedOut" to false,
    "cancelled" to true,
    "stdoutTruncated" to false,
    "stderrTruncated" to false,
  )

  private fun primaryAbi(): String {
    val abis = Build.SUPPORTED_ABIS
    if (abis.isNotEmpty()) {
      val a = abis[0]
      if (a.contains("arm64")) return "arm64-v8a"
      if (a.contains("x86_64") || a.contains("amd64")) return "x86_64"
      return a
    }
    return "arm64-v8a"
  }

  private fun hasProot(): Boolean {
    val exec = NativeLibResolver.resolve(appContext, EXEC_LIB)
    val loader = NativeLibResolver.resolve(appContext, LOADER_LIB)
    val ok = exec != null && loader != null
    if (!ok) {
      Log.w(
        TAG,
        "proot runtime missing: exec=${exec?.absolutePath} loader=${loader?.absolutePath}",
      )
    }
    return ok
  }

  private fun extractRootfs(workspacePath: String, archivePath: String) {
    val archive = File(archivePath)
    if (!archive.exists() || archive.length() == 0L) {
      throw IllegalStateException("archive missing or empty: $archivePath")
    }
    val sandbox = File(workspacePath, ".sandbox")
    val linuxTmp = File(sandbox, "linux.tmp")
    val linux = File(sandbox, "linux")
    sandbox.mkdirs()
    if (linuxTmp.exists()) linuxTmp.deleteRecursively()
    linuxTmp.mkdirs()

    try {
      // Streaming extractor with hardlink→copy fallback (system tar fails on
      // Android with "Permission denied" for Ubuntu base hardlinks).
      RootfsExtractor.extract(archive, linuxTmp)

      val sh = File(linuxTmp, "bin/sh")
      if (!sh.exists()) {
        // Some tarballs nest a single top-level dir
        val children = linuxTmp.listFiles()?.filter { it.isDirectory } ?: emptyList()
        if (children.size == 1 && File(children[0], "bin/sh").exists()) {
          val nested = children[0]
          nested.listFiles()?.forEach { child ->
            val dest = File(linuxTmp, child.name)
            if (!child.renameTo(dest)) {
              child.copyRecursively(dest, overwrite = true)
              child.deleteRecursively()
            }
          }
          nested.deleteRecursively()
        }
      }
      if (!File(linuxTmp, "bin/sh").exists()) {
        throw IllegalStateException("extract produced no bin/sh")
      }
      patchRootfs(linuxTmp)
      if (linux.exists()) linux.deleteRecursively()
      if (!linuxTmp.renameTo(linux)) {
        linuxTmp.copyRecursively(linux, overwrite = true)
        linuxTmp.deleteRecursively()
      }
      File(sandbox, "tmp").mkdirs()
    } catch (e: Exception) {
      try {
        if (linuxTmp.exists()) linuxTmp.deleteRecursively()
      } catch (_: Exception) {
      }
      throw e
    }
  }

  /** Minimal Android-friendly rootfs fixes (DNS / tmp / apt locks). */
  private fun patchRootfs(linuxDir: File) {
    try {
      patchDns(linuxDir)
      ensureGuestDirs(linuxDir)
      writeAptConfig(linuxDir)
    } catch (e: Exception) {
      Log.w(TAG, "patchRootfs: ${e.message}")
    }
  }

  /** Rewrite resolv.conf unless it already points at a usable DNS. */
  private fun patchDns(linuxDir: File) {
    val etc = File(linuxDir, "etc")
    etc.mkdirs()
    val resolv = File(etc, "resolv.conf")
    val body = if (resolv.isFile) resolv.readText() else ""
    val hasNameserver = body.lineSequence().any { it.trimStart().startsWith("nameserver") }
    val pointsAtStub = body.contains("127.0.0.53") || body.contains("systemd")
    if (hasNameserver && !pointsAtStub) return
    resolv.writeText(
      buildString {
        PUBLIC_DNS.forEach { append("nameserver $it\n") }
      },
    )
  }

  private fun ensureGuestDirs(linuxDir: File) {
    listOf("tmp", "var/tmp", "root").forEach { path ->
      File(linuxDir, path).mkdirs()
    }
  }

  /**
   * Make every apt invocation inside the guest wait for a held dpkg/apt lock
   * instead of failing instantly. Covers commands run through the LLM shell
   * tool (which bypasses the Dart-side install queue): a concurrent install
   * just waits, then proceeds.
   */
  private fun writeAptConfig(linuxDir: File) {
    val confDir = File(linuxDir, "etc/apt/apt.conf.d")
    confDir.mkdirs()
    File(confDir, "99cuplivo").writeText(
      "// Cuplivo Linux sandbox: wait for dpkg/apt locks instead of failing.\n" +
        "Acquire::Lock::Timeout \"600\";\n" +
        "DPkg::Lock::Timeout \"600\";\n" +
        "Acquire::Retries \"3\";\n",
    )
  }
}

private class AndroidExecution(
  val requestId: String,
  val generation: Long,
) {
  val cancelled = AtomicBoolean(false)
  val completed = AtomicBoolean(false)

  @Volatile
  var process: Process? = null

  @Volatile
  var workerThread: Thread? = null

  fun attach(process: Process) {
    this.process = process
    if (cancelled.get()) {
      try {
        process.destroy()
      } catch (_: Exception) {
      }
    }
  }

  fun cancel() {
    cancelled.set(true)
    try {
      process?.destroy()
    } catch (_: Exception) {
    }
    // Interrupting the worker aborts long-running work that cannot be
    // killed through the process handle alone: rootfs extraction checks
    // Thread.interrupted() per entry (TarStream.alive()).
    workerThread?.interrupt()
  }
}

/** Runs one command inside the proot guest and captures capped output. */
private class GuestCommandRunner(private val appContext: Context) {
  fun execute(
    workspacePath: String,
    command: String,
    cwd: String?,
    timeoutMs: Long,
    execution: AndroidExecution,
  ): Map<String, Any?> {
    val exec = NativeLibResolver.resolve(appContext, EXEC_LIB)
      ?: throw IllegalStateException("proot missing (system lib dir, filesDir cache and APK copy all failed)")
    val loader = NativeLibResolver.resolve(appContext, LOADER_LIB)
      ?: throw IllegalStateException("proot loader missing")
    val linux = File(workspacePath, ".sandbox/linux")
    val tmp = File(workspacePath, ".sandbox/tmp")
    tmp.mkdirs()
    val guestCwd = when {
      cwd.isNullOrBlank() -> "/workspace"
      cwd.startsWith("/workspace") -> cwd
      else -> "/workspace/${cwd.trimStart('/')}"
    }

    val builder = ProcessBuilder(
      buildGuestCommand(
        proot = exec,
        linuxDir = linux,
        guestCwd = guestCwd,
        hostWorkspace = workspacePath,
        command = command,
      ),
    )
    builder.directory(File(workspacePath))
    val env = builder.environment()
    env["PROOT_LOADER"] = loader.absolutePath
    env["PROOT_TMP_DIR"] = tmp.absolutePath
    env["TMPDIR"] = tmp.absolutePath
    val process = builder.start()
    execution.attach(process)
    try {
      // Commands such as git, apt and `read` must observe EOF instead of
      // keeping the proot process alive waiting for interactive input.
      process.outputStream.close()
    } catch (_: Exception) {
    }
    return OutputDrainer.capture(process, timeoutMs, execution)
  }

  fun ptyLaunchSpec(workspacePath: String): Map<String, Any> {
    val exec = NativeLibResolver.resolve(appContext, EXEC_LIB)
      ?: throw IllegalStateException("proot missing (system lib dir, filesDir cache and APK copy all failed)")
    val loader = NativeLibResolver.resolve(appContext, LOADER_LIB)
      ?: throw IllegalStateException("proot loader missing")
    val linux = File(workspacePath, ".sandbox/linux")
    val tmp = File(workspacePath, ".sandbox/tmp")
    tmp.mkdirs()
    if (!linux.isDirectory) {
      throw IllegalStateException("sandbox rootfs missing: ${linux.absolutePath}")
    }
    val arguments = buildGuestCommand(
      proot = exec,
      linuxDir = linux,
      guestCwd = "/workspace",
      hostWorkspace = workspacePath,
      command = null,
    )
    return mapOf(
      "executable" to arguments.first(),
      "arguments" to arguments.drop(1),
      "environment" to mapOf(
        "PROOT_LOADER" to loader.absolutePath,
        "PROOT_TMP_DIR" to tmp.absolutePath,
        "TMPDIR" to tmp.absolutePath,
      ),
      "workingDirectory" to workspacePath,
    )
  }
}

/**
 * Vendored proot native library resolution.
 *
 * Preferred source is the platform-extracted native library directory
 * (`applicationInfo.nativeLibraryDir`): the system writes those files with
 * the exec bit and the right SELinux label already in place, so the binary
 * can be spawned directly without copying or chmod. The filesDir copy chain
 * below is kept only for installs where that directory is unavailable.
 */
private object NativeLibResolver {
  fun resolve(appContext: Context, libFileName: String): File? {
    // 1) System-extracted native lib dir: executable out of the box. Still
    //    verified (and repaired via chmod if needed) so a non-executable
    //    copy falls through to the fallback chain instead of failing at
    //    exec time.
    val systemLib = File(appContext.applicationInfo.nativeLibraryDir, libFileName)
    if (systemLib.isFile && systemLib.length() > 0L && makeExecutable(systemLib)) {
      return systemLib
    }

    // 2) Previously copied fallback (survives restarts and app updates)
    val cached = File(appContext.filesDir, "proot/$libFileName")
    if (cached.isFile && cached.length() > 0L && makeExecutable(cached)) {
      return cached
    }

    // 3) Copy out of APK / split APKs into app filesDir
    val copied = copyFromApk(appContext, libFileName)
    if (copied != null && makeExecutable(copied)) {
      return copied
    }
    return null
  }

  /**
   * Best-effort exec bit setup for the filesDir fallback path. setExecutable
   * silently no-ops on some Android versions/OEMs, so the result is verified
   * and an explicit libcore chmod (0755) is tried before giving up. Returns
   * true only when the file is actually executable, so a binary that cannot
   * be made runnable is reported as missing instead of failing at exec time.
   */
  private fun makeExecutable(file: File): Boolean {
    try {
      if (file.canExecute()) return true
      file.setExecutable(true, false)
      if (file.canExecute()) return true
      android.system.Os.chmod(file.path, 0x1ED) // 0755
      if (file.canExecute()) return true
      Log.w(TAG, "makeExecutable: still not executable after chmod: ${file.absolutePath}")
    } catch (e: Exception) {
      Log.w(TAG, "makeExecutable failed for ${file.absolutePath}: ${e.message}")
    }
    return false
  }

  private fun copyFromApk(appContext: Context, libFileName: String): File? {
    val abi = primaryAbi()
    val entryNames = listOf(
      "lib/$abi/$libFileName",
      "lib/${abi.replace('-', '_')}/$libFileName",
    )
    val apkPaths = mutableListOf<String>()
    val ai = appContext.applicationInfo
    if (!ai.sourceDir.isNullOrBlank()) apkPaths += ai.sourceDir
    ai.splitSourceDirs?.forEach { if (!it.isNullOrBlank()) apkPaths += it }

    val outDir = File(appContext.filesDir, "proot")
    outDir.mkdirs()
    val out = File(outDir, libFileName)

    for (apk in apkPaths) {
      try {
        ZipFile(apk).use { zip ->
          for (entryName in entryNames) {
            val entry = zip.getEntry(entryName) ?: continue
            zip.getInputStream(entry).use { input ->
              FileOutputStream(out).use { output -> input.copyTo(output) }
            }
            if (out.isFile && out.length() > 0L) {
              Log.i("LinuxSandbox", "copied $entryName from $apk → ${out.absolutePath}")
              return out
            }
          }
        }
      } catch (e: Exception) {
        Log.w("LinuxSandbox", "copyFromApk($apk, $libFileName): ${e.message}")
      }
    }
    Log.w(
      "LinuxSandbox",
      "copyFromApk: no $libFileName entry found (abi=$abi, entries=$entryNames, apks=$apkPaths)",
    )
    return null
  }

  private fun primaryAbi(): String {
    val abis = Build.SUPPORTED_ABIS
    if (abis.isNotEmpty()) {
      val a = abis[0]
      if (a.contains("arm64")) return "arm64-v8a"
      if (a.contains("x86_64") || a.contains("amd64")) return "x86_64"
      return a
    }
    return "arm64-v8a"
  }
}

/** Assemble the proot argv: flags, guest bindings, and a clean bash -lc. */
private fun buildGuestCommand(
  proot: File,
  linuxDir: File,
  guestCwd: String,
  hostWorkspace: String,
  command: String?,
): List<String> {
  val argv = mutableListOf<String>()
  argv += proot.absolutePath
  argv += listOf(
    "--root-id",
    "--link2symlink",
    "--kill-on-exit",
    "-r",
    linuxDir.absolutePath,
    "-w",
    guestCwd,
    "-b",
    "$hostWorkspace:/workspace",
  )
  for (mount in KERNEL_FS_MOUNTS) {
    argv += listOf("-b", mount)
  }
  argv += listOf(
    "/usr/bin/env",
    "-i",
    "HOME=/root",
    "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
    "LANG=C.UTF-8",
    "TERM=xterm-256color",
    "DEBIAN_FRONTEND=noninteractive",
    "GIT_TERMINAL_PROMPT=0",
  )
  if (command == null) {
    argv += listOf("/bin/bash", "-l")
  } else {
    argv += listOf("/bin/bash", "-lc", command)
  }
  return argv
}

/** Captures capped stdout/stderr and enforces the exec timeout. */
private object OutputDrainer {
  private const val MAX_BYTES = 64 * 1024
  private const val HEAD_BYTES = 32 * 1024
  private const val TAIL_BYTES = 32 * 1024
  private const val GRACE_AFTER_TERM_MS = 2_000L
  private const val DRAIN_JOIN_MS = 2_000L

  fun capture(
    process: Process,
    timeoutMs: Long,
    execution: AndroidExecution,
  ): Map<String, Any?> {
    val stdout = ByteDrain("stdout", process.inputStream)
    val stderr = ByteDrain("stderr", process.errorStream)
    val finished = try {
      process.waitFor(timeoutMs, TimeUnit.MILLISECONDS)
    } catch (_: InterruptedException) {
      Thread.currentThread().interrupt()
      false
    }
    val cancelled = execution.cancelled.get()
    val timedOut = !finished && !cancelled
    if (!finished || cancelled) {
      terminate(process)
    }
    joinAndClose(stdout)
    joinAndClose(stderr)
    val exitCode = if (timedOut || cancelled) {
      -1
    } else {
      try {
        process.exitValue()
      } catch (_: IllegalThreadStateException) {
        -1
      }
    }
    return mapOf(
      "exitCode" to exitCode,
      "stdout" to stdout.text(),
      "stderr" to stderr.text(),
      "timedOut" to timedOut,
      "cancelled" to cancelled,
      "stdoutTruncated" to stdout.truncated,
      "stderrTruncated" to stderr.truncated,
    )
  }

  private fun terminate(process: Process) {
    val pid = pidOf(process)
    // Kill guest descendants while the proot parent is still visible in
    // /proc. Once the parent exits, apt/dpkg children may be reparented and
    // can otherwise survive long enough to retain package-manager state.
    pid?.let { killDescendants(it) }
    try {
      process.destroy()
    } catch (_: Exception) {
    }
    val stopped = try {
      process.waitFor(GRACE_AFTER_TERM_MS, TimeUnit.MILLISECONDS)
    } catch (_: InterruptedException) {
      Thread.currentThread().interrupt()
      false
    }
    if (stopped) return

    pid?.let { killDescendants(it) }
    try {
      process.destroyForcibly()
      process.waitFor(GRACE_AFTER_TERM_MS, TimeUnit.MILLISECONDS)
    } catch (_: Exception) {
    }
  }

  private fun joinAndClose(drain: ByteDrain) {
    try {
      drain.joinFor(DRAIN_JOIN_MS)
      if (drain.isAlive) drain.close()
      drain.joinFor(500L)
      if (drain.isAlive) drain.interrupt()
    } catch (_: InterruptedException) {
      Thread.currentThread().interrupt()
      drain.close()
    }
  }

  /**
   * Resolve a host PID without depending on Java 9's Process.pid() API. The
   * Android Process implementation exposes the PID as a private field on
   * supported API levels; the string form is only a compatibility fallback.
   */
  private fun pidOf(process: Process): Long? {
    try {
      val field = process.javaClass.getDeclaredField("pid")
      field.isAccessible = true
      val value = (field.get(process) as? Number)?.toLong()
      field.isAccessible = false
      if (value != null && value > 0L) return value
    } catch (_: Exception) {
    }
    return PID_REGEX.find(process.toString())?.groupValues?.get(1)?.toLongOrNull()
  }

  /**
   * Recursively SIGKILL all children of [pid] by walking /proc (the proot
   * guest processes are host processes, so the host view sees them). Called
   * before destroyForcibly so no apt/dpkg survives to hold the dpkg lock.
   */
  private fun killDescendants(pid: Long) {
    val children = mutableListOf<Long>()
    try {
      File("/proc").listFiles()?.forEach { dir ->
        val pidText = dir.name.toLongOrNull() ?: return@forEach
        try {
          // A target process may exit between listFiles and readText; that
          // only skips this PID, the rest of the scan continues.
          val stat = File(dir, "stat")
          if (!stat.isFile) return@forEach
          val text = stat.readText()
          val open = text.indexOf('(')
          val close = text.lastIndexOf(')')
          if (open < 0 || close <= open) return@forEach
          val parts = text.substring(close + 1).trim().split(' ')
          // parts[0] = state, parts[1] = ppid
          if (parts.size > 1 && parts[1].toLongOrNull() == pid) {
            children += pidText
          }
        } catch (e: Exception) {
          Log.w(TAG, "killDescendants read $pidText: ${e.message}")
        }
      }
    } catch (e: Exception) {
      Log.w(TAG, "killDescendants scan: ${e.message}")
      return
    }
    children.forEach { child ->
      killDescendants(child)
      try {
        AndroidProcess.killProcess(child.toInt())
      } catch (e: Exception) {
        Log.w(TAG, "killDescendants kill $child: ${e.message}")
      }
    }
  }

  private class ByteDrain(
    private val streamName: String,
    private val stream: InputStream,
  ) : Thread("cuplivo-$streamName-drain") {
    private val collected = BoundedBytes()

    init {
      start()
    }

    override fun run() {
      val buffer = ByteArray(8 * 1024)
      try {
        stream.use { input ->
          while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            if (count > 0) collected.append(buffer, 0, count)
          }
        }
      } catch (e: Exception) {
        Log.w(TAG, "$streamName drain stopped: ${e.javaClass.simpleName}")
      }
    }

    fun close() {
      try {
        stream.close()
      } catch (_: Exception) {
      }
    }

    fun joinFor(millis: Long) = join(millis)

    val truncated: Boolean
      get() = collected.truncated

    fun text(): String = collected.text()
  }

  private class BoundedBytes {
    private var full: ByteArrayOutputStream? = ByteArrayOutputStream(MAX_BYTES)
    private val head = ByteArrayOutputStream(HEAD_BYTES)
    private val tail = ByteArray(TAIL_BYTES)
    private var tailStart = 0
    private var tailSize = 0
    private var totalBytes = 0L

    @Synchronized
    fun append(bytes: ByteArray, offset: Int, length: Int) {
      if (length <= 0) return
      val previousBytes = totalBytes
      totalBytes += length
      full?.let { complete ->
        val remaining = MAX_BYTES - previousBytes
        if (remaining >= length) {
          complete.write(bytes, offset, length)
        } else {
          full = null
        }
      }
      val headRemaining = HEAD_BYTES - head.size()
      if (headRemaining > 0) {
        head.write(bytes, offset, minOf(headRemaining, length))
      }
      appendTail(bytes, offset, length)
    }

    @Synchronized
    fun text(): String {
      if (!truncated) {
        return String(full?.toByteArray() ?: ByteArray(0), StandardCharsets.UTF_8)
      }
      val headText = String(head.toByteArray(), StandardCharsets.UTF_8)
      val tailText = String(tailBytes(), StandardCharsets.UTF_8)
      return "$headText\n...[output truncated]...\n$tailText"
    }

    val truncated: Boolean
      @Synchronized get() = totalBytes > MAX_BYTES

    private fun appendTail(bytes: ByteArray, offset: Int, length: Int) {
      if (length >= TAIL_BYTES) {
        System.arraycopy(bytes, offset + length - TAIL_BYTES, tail, 0, TAIL_BYTES)
        tailStart = 0
        tailSize = TAIL_BYTES
        return
      }
      if (tailSize + length <= TAIL_BYTES) {
        writeCircular(bytes, offset, length, (tailStart + tailSize) % TAIL_BYTES)
        tailSize += length
        return
      }
      val overflow = tailSize + length - TAIL_BYTES
      val oldStart = tailStart
      val oldSize = tailSize
      tailStart = (oldStart + overflow) % TAIL_BYTES
      tailSize = TAIL_BYTES
      writeCircular(bytes, offset, length, (oldStart + oldSize) % TAIL_BYTES)
    }

    private fun writeCircular(bytes: ByteArray, offset: Int, length: Int, start: Int) {
      val first = minOf(length, TAIL_BYTES - start)
      System.arraycopy(bytes, offset, tail, start, first)
      if (first < length) {
        System.arraycopy(bytes, offset + first, tail, 0, length - first)
      }
    }

    private fun tailBytes(): ByteArray {
      val bytes = ByteArray(tailSize)
      val first = minOf(tailSize, TAIL_BYTES - tailStart)
      System.arraycopy(tail, tailStart, bytes, 0, first)
      if (first < tailSize) {
        System.arraycopy(tail, 0, bytes, first, tailSize - first)
      }
      return bytes
    }
  }
}

private const val MAX_EXEC_TIMEOUT_MS = 3_600_000L
private const val TAG = "LinuxSandbox"
private const val EXEC_LIB = "libproot_exec.so"
private const val LOADER_LIB = "libproot_loader.so"
private val PID_REGEX = Regex("pid=(\\d+)")
private val KERNEL_FS_MOUNTS = listOf("/dev", "/proc", "/sys")
private val PUBLIC_DNS = listOf("1.1.1.1", "8.8.8.8", "223.5.5.5")
