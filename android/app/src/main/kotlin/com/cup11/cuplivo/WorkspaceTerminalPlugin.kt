package com.cup11.cuplivo

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.IBinder
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

internal class WorkspaceTerminalServiceConnection(
  private val context: Context,
) : ServiceConnection {
  private var service: WorkspaceTerminalService? = null
  private var bound = false
  private var closed = false
  private val pending = mutableListOf<Pair<(WorkspaceTerminalService) -> Unit, (String) -> Unit>>()

  fun bind() {
    if (bound || closed) return
    bound = context.bindService(
      Intent(context, WorkspaceTerminalService::class.java),
      this,
      Context.BIND_AUTO_CREATE,
    )
    if (!bound) failPending("Unable to bind workspace terminal service")
  }

  fun withService(
    onReady: (WorkspaceTerminalService) -> Unit,
    onError: (String) -> Unit,
  ) {
    val current = service
    if (current != null) {
      onReady(current)
      return
    }
    if (closed) {
      onError("Workspace terminal service connection is closed")
      return
    }
    pending += onReady to onError
    bind()
  }

  fun close() {
    if (closed) return
    closed = true
    failPending("Workspace terminal service connection closed")
    if (bound) context.unbindService(this)
    bound = false
    service = null
  }

  override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
    val connected = (binder as? WorkspaceTerminalService.LocalBinder)?.service
    if (connected == null) {
      failPending("Unexpected workspace terminal binder")
      return
    }
    service = connected
    val callbacks = pending.toList()
    pending.clear()
    callbacks.forEach { it.first(connected) }
  }

  override fun onServiceDisconnected(name: ComponentName?) {
    service = null
  }

  private fun failPending(message: String) {
    val callbacks = pending.toList()
    pending.clear()
    callbacks.forEach { it.second(message) }
  }
}

class WorkspaceTerminalPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
  private var channel: MethodChannel? = null
  private var connection: WorkspaceTerminalServiceConnection? = null

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    val serviceConnection = WorkspaceTerminalServiceConnection(
      binding.applicationContext,
    )
    connection = serviceConnection
    serviceConnection.bind()
    channel = MethodChannel(
      binding.binaryMessenger,
      "cuplivo/workspace_terminal",
    ).also { it.setMethodCallHandler(this) }
    binding.platformViewRegistry.registerViewFactory(
      "cuplivo/workspace_terminal_view",
      WorkspaceTerminalPlatformViewFactory(
        binding.binaryMessenger,
        serviceConnection,
      ),
    )
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel?.setMethodCallHandler(null)
    channel = null
    connection?.close()
    connection = null
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    val activeConnection = connection
    if (activeConnection == null) {
      result.error("service_unavailable", "Terminal plugin is detached", null)
      return
    }
    try {
      when (call.method) {
        "startSession" -> {
          val request = parseLaunchRequest(call.arguments)
          activeConnection.withService(
            onReady = { service ->
              try {
                result.success(service.startSession(request))
              } catch (error: Exception) {
                result.error("session_start_failed", error.message, null)
              }
            },
            onError = { result.error("service_unavailable", it, null) },
          )
        }
        "getSessionState" -> {
          val workspaceId = requiredWorkspaceId(argumentsMap(call.arguments))
          activeConnection.withService(
            onReady = {
              try {
                result.success(it.getSessionState(workspaceId))
              } catch (error: Exception) {
                result.error("session_state_failed", error.message, null)
              }
            },
            onError = { result.error("service_unavailable", it, null) },
          )
        }
        "setDurable" -> {
          val args = argumentsMap(call.arguments)
          val workspaceId = requiredWorkspaceId(args)
          val durable = args["durable"] as? Boolean
            ?: throw IllegalArgumentException("durable must be boolean")
          val notification = parseNotification(args["notification"])
          activeConnection.withService(
            onReady = {
              try {
                result.success(it.setDurable(workspaceId, durable, notification))
              } catch (error: Exception) {
                result.error("durability_update_failed", error.message, null)
              }
            },
            onError = { result.error("service_unavailable", it, null) },
          )
        }
        "stopSession" -> {
          val workspaceId = requiredWorkspaceId(argumentsMap(call.arguments))
          activeConnection.withService(
            onReady = { service ->
              service.stopSession(workspaceId) { success ->
                completeStop(result, success)
              }
            },
            onError = { result.error("service_unavailable", it, null) },
          )
        }
        "stopSessionForWorkspacePath" -> {
          val args = argumentsMap(call.arguments)
          val workspacePath = requiredAbsolutePath(args, "workspaceHostPath")
          activeConnection.withService(
            onReady = { service ->
              service.stopSessionForWorkspacePath(workspacePath) { success ->
                completeStop(result, success)
              }
            },
            onError = { result.error("service_unavailable", it, null) },
          )
        }
        "stopAutoSessionIfDetached" -> {
          val workspaceId = requiredWorkspaceId(argumentsMap(call.arguments))
          activeConnection.withService(
            onReady = { service ->
              service.stopAutoSessionIfDetached(workspaceId) { success ->
                completeStop(result, success)
              }
            },
            onError = { result.error("service_unavailable", it, null) },
          )
        }
        "stopAllSessions" -> activeConnection.withService(
          onReady = { service ->
            service.stopAllSessions { success -> completeStop(result, success) }
          },
          onError = { result.error("service_unavailable", it, null) },
        )
        else -> result.notImplemented()
      }
    } catch (error: IllegalArgumentException) {
      result.error("bad_args", error.message, null)
    }
  }

  private fun completeStop(result: MethodChannel.Result, success: Boolean) {
    if (success) result.success(null) else result.error(
      "session_stop_failed",
      "Timed out waiting for terminal process to exit",
      null,
    )
  }

  private fun parseLaunchRequest(arguments: Any?): WorkspaceTerminalLaunchRequest {
    val args = argumentsMap(arguments)
    val workspaceId = requiredWorkspaceId(args)
    val workspaceHostPath = requiredAbsolutePath(args, "workspaceHostPath")
    val executable = requiredAbsolutePath(args, "executable")
    val workingDirectory = requiredAbsolutePath(args, "workingDirectory")
    val rawArguments = args["arguments"] as? List<*>
      ?: throw IllegalArgumentException("arguments must be a list")
    val commandArguments = rawArguments.map {
      val argument = it as? String
        ?: throw IllegalArgumentException("arguments must contain strings")
      if (argument.indexOf('\u0000') >= 0) {
        throw IllegalArgumentException("arguments must not contain NUL")
      }
      argument
    }
    val rawEnvironment = args["environment"] as? Map<*, *>
      ?: throw IllegalArgumentException("environment must be a map")
    val environment = linkedMapOf<String, String>()
    rawEnvironment.forEach { (key, value) ->
      if (
        key !is String ||
        value !is String ||
        key.isBlank() ||
        key.contains('=') ||
        key.indexOf('\u0000') >= 0 ||
        value.indexOf('\u0000') >= 0
      ) {
        throw IllegalArgumentException("environment contains an invalid entry")
      }
      environment[key] = value
    }
    val durable = args["durable"] as? Boolean
      ?: throw IllegalArgumentException("durable must be boolean")
    val autoStarted = args["autoStarted"] as? Boolean
      ?: throw IllegalArgumentException("autoStarted must be boolean")
    return WorkspaceTerminalLaunchRequest(
      workspaceId = workspaceId,
      workspaceHostPath = workspaceHostPath,
      executable = executable,
      arguments = commandArguments,
      environment = environment,
      workingDirectory = workingDirectory,
      durable = durable,
      autoStarted = autoStarted,
      notification = parseNotification(args["notification"]),
    )
  }

  private fun parseNotification(value: Any?): WorkspaceTerminalNotification {
    val args = value as? Map<*, *>
      ?: throw IllegalArgumentException("notification must be a map")
    fun string(name: String): String {
      val result = (args[name] as? String)?.trim().orEmpty()
      if (result.isEmpty()) throw IllegalArgumentException("notification.$name required")
      return result
    }
    return WorkspaceTerminalNotification(
      channelName = string("channelName"),
      title = string("title"),
      text = string("text"),
    )
  }

  private fun argumentsMap(arguments: Any?): Map<*, *> =
    arguments as? Map<*, *> ?: throw IllegalArgumentException("arguments must be a map")

  private fun requiredWorkspaceId(args: Map<*, *>): String {
    val value = (args["workspaceId"] as? String)?.trim().orEmpty()
    if (!WORKSPACE_ID.matches(value)) {
      throw IllegalArgumentException("workspaceId is invalid")
    }
    return value
  }

  private fun requiredAbsolutePath(args: Map<*, *>, key: String): String {
    val value = (args[key] as? String)?.trim().orEmpty()
    if (!value.startsWith('/') || value.indexOf('\u0000') >= 0) {
      throw IllegalArgumentException("$key must be an absolute path")
    }
    return value
  }

  companion object {
    private val WORKSPACE_ID = Regex("^[A-Za-z0-9_-]{1,128}$")
  }
}
