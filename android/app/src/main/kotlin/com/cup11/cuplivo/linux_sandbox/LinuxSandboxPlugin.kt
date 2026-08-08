package com.cup11.cuplivo.linux_sandbox

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/**
 * Cuplivo sandbox native bridge: ABI/paths + PRoot shell execution.
 *
 * Rootfs download/extract is handled on the Dart side. This plugin only
 * exposes native library locations and runs commands under PRoot.
 */
class LinuxSandboxPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var appContext: Context? = null
    private val executor = Executors.newCachedThreadPool()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val activeProcess = AtomicReference<Process?>(null)

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        setup(binding.binaryMessenger)
    }

    fun attachToEngine(context: Context, messenger: BinaryMessenger) {
        appContext = context.applicationContext
        setup(messenger)
    }

    private fun setup(messenger: BinaryMessenger) {
        channel?.setMethodCallHandler(null)
        channel = MethodChannel(messenger, CHANNEL_NAME).also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        detach()
    }

    fun detach() {
        channel?.setMethodCallHandler(null)
        channel = null
        appContext = null
        activeProcess.getAndSet(null)?.destroyForcibly()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getNativeLibraryDir" -> {
                val ctx = appContext
                if (ctx == null) {
                    result.error("no_context", "Application context unavailable", null)
                    return
                }
                result.success(ctx.applicationInfo.nativeLibraryDir)
            }
            "getSupportedAbi" -> result.success(supportedAbi())
            "hasRootfs" -> {
                val sandboxRoot = call.argument<String>("sandboxRoot")?.trim().orEmpty()
                if (sandboxRoot.isEmpty()) {
                    result.error("invalid_args", "Missing sandboxRoot", null)
                    return
                }
                result.success(hasUsableRootfs(File(sandboxRoot, LINUX_DIR)))
            }
            "execShell" -> {
                val sandboxRoot = call.argument<String>("sandboxRoot")?.trim().orEmpty()
                val command = call.argument<String>("command") ?: ""
                val timeoutMs = (call.argument<Number>("timeoutMs")?.toLong() ?: DEFAULT_TIMEOUT_MS)
                    .coerceIn(1_000L, MAX_TIMEOUT_MS)
                if (sandboxRoot.isEmpty()) {
                    result.error("invalid_args", "Missing sandboxRoot", null)
                    return
                }
                if (command.isBlank()) {
                    result.error("invalid_args", "command must not be empty", null)
                    return
                }
                val ctx = appContext
                if (ctx == null) {
                    result.error("no_context", "Application context unavailable", null)
                    return
                }
                executor.execute {
                    try {
                        val map = runProotShell(
                            nativeLibraryDir = File(ctx.applicationInfo.nativeLibraryDir),
                            sandboxRoot = File(sandboxRoot),
                            command = command,
                            timeoutMs = timeoutMs,
                        )
                        mainHandler.post { result.success(map) }
                    } catch (e: Exception) {
                        mainHandler.post {
                            result.error("exec_failed", e.message, null)
                        }
                    }
                }
            }
            "cancelInstall" -> {
                // Install is Dart-side in the hybrid path; cancel is a no-op here.
                result.success(true)
            }
            "destroy" -> {
                // Disk delete is Dart-side; cancel any running shell.
                activeProcess.getAndSet(null)?.destroyForcibly()
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    private fun supportedAbi(): String {
        val abis = Build.SUPPORTED_ABIS ?: emptyArray()
        for (abi in abis) {
            when (abi) {
                "arm64-v8a" -> return "arm64-v8a"
                "x86_64" -> return "x86_64"
            }
        }
        return "unsupported"
    }

    private fun runProotShell(
        nativeLibraryDir: File,
        sandboxRoot: File,
        command: String,
        timeoutMs: Long,
    ): Map<String, Any?> {
        val linuxDir = File(sandboxRoot, LINUX_DIR)
        val filesDir = File(sandboxRoot, FILES_DIR)
        val tmpDir = File(sandboxRoot, TMP_DIR)

        if (!hasUsableRootfs(linuxDir)) {
            return mapOf(
                "exitCode" to 127,
                "stdout" to "",
                "stderr" to "Rootfs is not installed",
                "timedOut" to false,
                "truncated" to false,
            )
        }

        val proot = File(nativeLibraryDir, PROOT_EXEC)
        val loader = File(nativeLibraryDir, PROOT_LOADER)
        if (!proot.isFile) {
            return mapOf(
                "exitCode" to 127,
                "stdout" to "",
                "stderr" to "proot executable not found: ${proot.absolutePath}",
                "timedOut" to false,
                "truncated" to false,
            )
        }
        if (!loader.isFile) {
            return mapOf(
                "exitCode" to 127,
                "stdout" to "",
                "stderr" to "proot loader not found: ${loader.absolutePath}",
                "timedOut" to false,
                "truncated" to false,
            )
        }

        filesDir.mkdirs()
        tmpDir.mkdirs()

        val cmd = buildProotCommand(
            proot = proot,
            linuxDir = linuxDir,
            filesDir = filesDir,
            command = command,
        )

        val process = ProcessBuilder(cmd)
            .directory(filesDir)
            .redirectErrorStream(false)
            .apply {
                environment()["PROOT_LOADER"] = loader.absolutePath
                environment()["PROOT_TMP_DIR"] = tmpDir.absolutePath
                environment()["TMPDIR"] = tmpDir.absolutePath
            }
            .start()

        activeProcess.set(process)
        try {
            return process.readResult(timeoutMs)
        } finally {
            activeProcess.compareAndSet(process, null)
        }
    }

    private fun buildProotCommand(
        proot: File,
        linuxDir: File,
        filesDir: File,
        command: String,
    ): List<String> {
        val args = mutableListOf(
            proot.absolutePath,
            "--root-id",
            "--link2symlink",
            "--kill-on-exit",
            "-r",
            linuxDir.absolutePath,
            "-w",
            WORKSPACE_DIR,
            "-b",
            "${filesDir.absolutePath}:$WORKSPACE_DIR",
        )

        for (path in KERNEL_FS_MOUNTS) {
            if (File(path).exists()) {
                args += "-b"
                args += path
            }
        }

        args += listOf(
            "/usr/bin/env",
            "-i",
            "HOME=/root",
            "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            "TERM=xterm-256color",
            "LANG=C.UTF-8",
            "LC_ALL=C.UTF-8",
            "/bin/bash",
            "-l",
            "-c",
            // Positional args avoid shell-escaping the user command; eval "$2" once.
            "cd -- \"\$1\" && eval \"\$2\"",
            "cuplivo",
            WORKSPACE_DIR,
            command,
        )
        return args
    }

    private fun Process.readResult(timeoutMs: Long): Map<String, Any?> {
        val stdout = StreamCollector(inputStream)
        val stderr = StreamCollector(errorStream)
        try {
            val finished = waitFor(timeoutMs, TimeUnit.MILLISECONDS)
            if (!finished) {
                destroyForcibly()
            }
            stdout.join(1_000)
            stderr.join(1_000)
            return mapOf(
                "exitCode" to if (finished) exitValue() else -1,
                "stdout" to stdout.text(),
                "stderr" to stderr.text(),
                "timedOut" to !finished,
                "truncated" to (stdout.truncated || stderr.truncated),
            )
        } catch (e: InterruptedException) {
            destroyForcibly()
            stdout.join(1_000)
            stderr.join(1_000)
            Thread.currentThread().interrupt()
            throw e
        }
    }

    private class StreamCollector(
        stream: InputStream,
        private val maxChars: Int = MAX_OUTPUT_CHARS,
    ) {
        private val builder = StringBuilder()

        @Volatile
        var truncated: Boolean = false
            private set

        private val thread = Thread {
            try {
                stream.bufferedReader().use { reader ->
                    val buffer = CharArray(4096)
                    while (true) {
                        val read = reader.read(buffer)
                        if (read < 0) break
                        synchronized(builder) {
                            val remaining = maxChars - builder.length
                            if (remaining > 0) {
                                builder.append(buffer, 0, minOf(read, remaining))
                            }
                            if (read > remaining) {
                                truncated = true
                            }
                        }
                    }
                }
            } catch (_: IOException) {
                // Process killed or stream closed; keep partial output.
            }
        }.apply {
            isDaemon = true
            start()
        }

        fun join(millis: Long) {
            thread.join(millis)
        }

        fun text(): String = synchronized(builder) { builder.toString() }
    }

    companion object {
        const val CHANNEL_NAME = "app.linux_sandbox"

        private const val PROOT_EXEC = "libproot_exec.so"
        private const val PROOT_LOADER = "libproot_loader.so"
        private const val FILES_DIR = "files"
        private const val LINUX_DIR = "linux"
        private const val TMP_DIR = "tmp"
        private const val WORKSPACE_DIR = "/workspace"
        private const val DEFAULT_TIMEOUT_MS = 30_000L
        private const val MAX_TIMEOUT_MS = 120_000L
        private const val MAX_OUTPUT_CHARS = 128 * 1024

        private val KERNEL_FS_MOUNTS = listOf("/dev", "/proc", "/sys")

        private fun hasUsableRootfs(linuxDir: File): Boolean =
            linuxDir.isDirectory && File(linuxDir, "bin/sh").isFile
    }
}
