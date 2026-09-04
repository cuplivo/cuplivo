package com.cup11.cuplivo

import android.content.Context
import android.graphics.Color
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.inputmethod.InputMethodManager
import com.termux.shared.termux.terminal.TermuxTerminalViewClientBase
import com.termux.terminal.KeyHandler
import com.termux.terminal.TerminalSession
import com.termux.view.TerminalView
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import kotlin.math.roundToInt

internal class WorkspaceTerminalPlatformViewFactory(
  private val messenger: BinaryMessenger,
  private val connection: WorkspaceTerminalServiceConnection,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
  override fun create(context: Context, viewId: Int, args: Any?): PlatformView =
    WorkspaceTerminalPlatformView(context, viewId, args, messenger, connection)
}

internal class WorkspaceTerminalPlatformView(
  private val context: Context,
  viewId: Int,
  creationParams: Any?,
  messenger: BinaryMessenger,
  private val connection: WorkspaceTerminalServiceConnection,
) : PlatformView, MethodChannel.MethodCallHandler {
  private val workspaceId: String
  private val terminalView = TerminalView(context, null)
  private val channel = MethodChannel(
    messenger,
    "cuplivo/workspace_terminal_view/$viewId",
  )
  private var service: WorkspaceTerminalService? = null
  private var disposed = false
  private var fontSize = 12
  private var ctrlModifier = false
  private var altModifier = false

  init {
    val params = creationParams as? Map<*, *>
      ?: throw IllegalArgumentException("Terminal view params must be a map")
    workspaceId = (params["workspaceId"] as? String)?.trim().orEmpty()
    if (!Regex("^[A-Za-z0-9_-]{1,128}$").matches(workspaceId)) {
      throw IllegalArgumentException("Invalid terminal workspaceId")
    }
    fontSize = ((params["fontSize"] as? Number)?.toInt() ?: 12).coerceIn(8, 32)
    terminalView.setBackgroundColor(Color.BLACK)
    applyTextSize()
    terminalView.isFocusable = true
    terminalView.isFocusableInTouchMode = true
    terminalView.setTerminalViewClient(TerminalClient())
    channel.setMethodCallHandler(this)
    attachToService()
  }

  override fun getView(): View = terminalView

  override fun dispose() {
    if (disposed) return
    disposed = true
    channel.setMethodCallHandler(null)
    service?.detachView(workspaceId, this)
    service = null
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    try {
      when (call.method) {
        "attach" -> {
          attachToService()
          result.success(null)
        }
        "detach" -> {
          service?.detachView(workspaceId, this)
          result.success(null)
        }
        "sendText" -> {
          val args = call.arguments as? Map<*, *>
            ?: throw IllegalArgumentException("sendText arguments required")
          val text = args["text"] as? String
            ?: throw IllegalArgumentException("text must be a string")
          val ctrl = args["ctrl"] == true
          val alt = args["alt"] == true
          var offset = 0
          while (offset < text.length) {
            val codePoint = Character.codePointAt(text, offset)
            terminalView.inputCodePoint(
              TerminalView.KEY_EVENT_SOURCE_VIRTUAL_KEYBOARD,
              codePoint,
              ctrl,
              alt,
            )
            offset += Character.charCount(codePoint)
          }
          result.success(null)
        }
        "sendKey" -> {
          val args = call.arguments as? Map<*, *>
            ?: throw IllegalArgumentException("sendKey arguments required")
          val name = args["key"] as? String
            ?: throw IllegalArgumentException("key must be a string")
          var modifiers = 0
          if (args["ctrl"] == true) modifiers = modifiers or KeyHandler.KEYMOD_CTRL
          if (args["alt"] == true) modifiers = modifiers or KeyHandler.KEYMOD_ALT
          if (!terminalView.handleKeyCode(keyCode(name), modifiers)) {
            throw IllegalArgumentException("Unsupported terminal key: $name")
          }
          result.success(null)
        }
        "setModifiers" -> {
          val args = call.arguments as? Map<*, *>
            ?: throw IllegalArgumentException("setModifiers arguments required")
          ctrlModifier = args["ctrl"] == true
          altModifier = args["alt"] == true
          result.success(null)
        }
        "setTextSize" -> {
          val size = (call.arguments as? Number)?.toInt()
            ?: throw IllegalArgumentException("font size must be numeric")
          fontSize = size.coerceIn(8, 32)
          applyTextSize()
          result.success(fontSize)
        }
        "copySelection" -> {
          val selected = terminalView.selectedText
          if (!selected.isNullOrEmpty()) terminalView.stopTextSelectionMode()
          result.success(selected)
        }
        "clearSelection" -> {
          terminalView.stopTextSelectionMode()
          result.success(null)
        }
        else -> result.notImplemented()
      }
    } catch (error: Exception) {
      result.error("terminal_view_failed", error.message, null)
    }
  }

  internal fun attachSession(session: TerminalSession) {
    if (disposed) return
    terminalView.attachSession(session)
    terminalView.requestFocus()
    terminalView.invalidate()
  }

  internal fun onScreenChanged() {
    if (!disposed) terminalView.onScreenUpdated()
  }

  internal fun onSessionStateChanged(state: Map<String, Any?>) {
    if (!disposed) channel.invokeMethod("sessionStateChanged", state)
  }

  private fun attachToService() {
    if (disposed) return
    connection.withService(
      onReady = { connected ->
        if (disposed) return@withService
        try {
          if (service !== connected) {
            service?.detachView(workspaceId, this)
            service = connected
          }
          connected.attachView(workspaceId, this)
        } catch (error: Exception) {
          channel.invokeMethod(
            "attachFailed",
            error.message ?: error.javaClass.simpleName,
          )
        }
      },
      onError = { message ->
        if (!disposed) channel.invokeMethod("attachFailed", message)
      },
    )
  }

  private fun keyCode(name: String): Int = when (name) {
    "escape" -> KeyEvent.KEYCODE_ESCAPE
    "tab" -> KeyEvent.KEYCODE_TAB
    "home" -> KeyEvent.KEYCODE_MOVE_HOME
    "end" -> KeyEvent.KEYCODE_MOVE_END
    "arrowUp" -> KeyEvent.KEYCODE_DPAD_UP
    "arrowDown" -> KeyEvent.KEYCODE_DPAD_DOWN
    "arrowLeft" -> KeyEvent.KEYCODE_DPAD_LEFT
    "arrowRight" -> KeyEvent.KEYCODE_DPAD_RIGHT
    "pageUp" -> KeyEvent.KEYCODE_PAGE_UP
    "pageDown" -> KeyEvent.KEYCODE_PAGE_DOWN
    else -> throw IllegalArgumentException("Unknown terminal key")
  }

  private fun applyTextSize() {
    val pixels = (fontSize * context.resources.displayMetrics.density).roundToInt()
    terminalView.setTextSize(pixels)
  }

  private inner class TerminalClient : TermuxTerminalViewClientBase() {
    override fun onScale(scale: Float): Float {
      if (scale < 0.9f || scale > 1.1f) {
        val delta = if (scale > 1f) 2 else -2
        fontSize = (fontSize + delta).coerceIn(8, 32)
        applyTextSize()
        channel.invokeMethod("fontSizeChanged", fontSize)
        return 1f
      }
      return scale
    }

    override fun onSingleTapUp(event: MotionEvent) {
      terminalView.requestFocus()
      val input = context.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
      input.showSoftInput(terminalView, InputMethodManager.SHOW_IMPLICIT)
    }

    override fun shouldBackButtonBeMappedToEscape(): Boolean = false
    override fun shouldEnforceCharBasedInput(): Boolean = false
    override fun shouldUseCtrlSpaceWorkaround(): Boolean = false
    override fun isTerminalViewSelected(): Boolean = terminalView.hasFocus()

    override fun copyModeChanged(copyMode: Boolean) {
      channel.invokeMethod("copyModeChanged", copyMode)
    }

    override fun onKeyDown(
      keyCode: Int,
      event: KeyEvent,
      session: TerminalSession,
    ): Boolean = false

    override fun onKeyUp(keyCode: Int, event: KeyEvent): Boolean = false
    override fun onLongPress(event: MotionEvent): Boolean = false
    override fun readControlKey(): Boolean = ctrlModifier
    override fun readAltKey(): Boolean = altModifier
    override fun readShiftKey(): Boolean = false
    override fun readFnKey(): Boolean = false

    override fun onCodePoint(
      codePoint: Int,
      ctrlDown: Boolean,
      session: TerminalSession,
    ): Boolean {
      if (ctrlModifier || altModifier) channel.invokeMethod("modifierConsumed", null)
      return false
    }

    override fun onEmulatorSet() {
      terminalView.invalidate()
    }
  }
}
