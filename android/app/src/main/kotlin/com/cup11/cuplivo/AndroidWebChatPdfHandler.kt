package com.cup11.cuplivo

import android.app.Activity
import android.content.Context
import android.os.Bundle
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import android.print.PageRange
import android.print.PrintAttributes
import android.print.PrintDocumentAdapter
import android.print.PrintJob
import android.print.PrintManager
import android.util.Log
import android.view.View
import android.view.ViewGroup
import android.webkit.ConsoleMessage
import android.webkit.PermissionRequest
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.widget.FrameLayout
import androidx.webkit.WebMessageCompat
import androidx.webkit.WebResourceErrorCompat
import androidx.webkit.WebViewClientCompat
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.ByteArrayInputStream

private const val PDF_CHANNEL_NAME = "cuplivo/web_chat_pdf"
private const val PDF_LOG_TAG = "CuplivoWebChatPdf"
private const val PRINT_VIEW_WIDTH_PX = 794
private const val PRINT_VIEW_HEIGHT_PX = 1123
private const val PRINT_MARGIN_MILS = 551

internal fun sanitizeWebChatPrintDocumentName(raw: String): String {
  val sanitized = raw
    .replace(Regex("[\\p{Cc}/\\\\]"), "_")
    .trim()
    .trim('_')
    .take(80)
  return sanitized.ifEmpty { "Cuplivo" }
}

internal fun isAllowedWebChatResourceUrl(url: String): Boolean =
  url.startsWith("$WEB_CHAT_ORIGIN/assets/") && !url.contains("..")

class AndroidWebChatPdfHandler(
  private val activity: Activity,
) : MethodChannel.MethodCallHandler {
  private var channel: MethodChannel? = null
  private var webView: WebView? = null
  private var offscreenHost: FrameLayout? = null
  private var printAdapter: PrintDocumentAdapter? = null
  private var printJob: PrintJob? = null
  private var pendingPrintResult: MethodChannel.Result? = null
  private var disposed = false

  fun configure(messenger: BinaryMessenger) {
    channel = MethodChannel(messenger, PDF_CHANNEL_NAME).also {
      it.setMethodCallHandler(this)
    }
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    if (disposed) {
      result.error("disposed", "Android PDF handler is disposed.", null)
      return
    }
    when (call.method) {
      "start" -> start(result)
      "postEnvelope" -> postEnvelope(call.arguments, result)
      "print" -> print(call.arguments, result)
      "dispose" -> {
        disposeCurrentTask(cancelPrint = true)
        result.success(null)
      }
      else -> result.notImplemented()
    }
  }

  private fun start(result: MethodChannel.Result) {
    if (webView != null || pendingPrintResult != null) {
      result.error("busy", "Another Android PDF print task is active.", null)
      return
    }
    if (!WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)) {
      result.error(
        "web_message_listener_unsupported",
        "Android System WebView does not support the secure message bridge.",
        null,
      )
      return
    }

    try {
      val root = activity.findViewById<ViewGroup>(android.R.id.content)
        ?: throw IllegalStateException("Activity content view is unavailable.")
      val host = FrameLayout(activity).apply {
        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
        isFocusable = false
        isClickable = false
        translationX = -10000f
        translationY = -10000f
      }
      val view = WebView(activity)
      configureSecureWebChatSettings(view)
      host.addView(
        view,
        FrameLayout.LayoutParams(
          ViewGroup.LayoutParams.MATCH_PARENT,
          ViewGroup.LayoutParams.MATCH_PARENT,
        ),
      )
      root.addView(
        host,
        ViewGroup.LayoutParams(PRINT_VIEW_WIDTH_PX, PRINT_VIEW_HEIGHT_PX),
      )
      offscreenHost = host
      webView = view
      configurePdfWebView(view)
      view.loadUrl(WEB_CHAT_PRINT_SHELL_URL)
      result.success(null)
    } catch (error: Exception) {
      Log.e(PDF_LOG_TAG, "Failed to start PDF WebView", error)
      disposeCurrentTask(cancelPrint = false)
      result.error("start_failed", error.message, null)
    }
  }

  private fun configurePdfWebView(view: WebView) {
    val assetLoader = createWebChatAssetLoader(activity)
    WebViewCompat.addWebMessageListener(
      view,
      "CuplivoChat",
      setOf(WEB_CHAT_ORIGIN),
    ) { _, message, sourceOrigin, isMainFrame, _ ->
      if (
        webView === view &&
        isMainFrame &&
        sourceOrigin.toString() == WEB_CHAT_ORIGIN &&
        message.type == WebMessageCompat.TYPE_STRING
      ) {
        channel?.invokeMethod("bridgeMessage", message.data)
      }
    }
    view.webViewClient = object : WebViewClientCompat() {
      override fun shouldInterceptRequest(
        view: WebView,
        request: WebResourceRequest,
      ): WebResourceResponse? {
        val url = request.url.toString()
        if (isAllowedWebChatResourceUrl(url)) {
          return assetLoader.shouldInterceptRequest(request.url)
        }
        return blockedResourceResponse()
      }

      override fun shouldOverrideUrlLoading(
        view: WebView,
        request: WebResourceRequest,
      ): Boolean {
        val allowed = request.isForMainFrame &&
          isAllowedWebChatMainFrameUrl(request.url.toString(), printMode = true)
        if (!allowed) {
          channel?.invokeMethod("diagnostic", "navigation_blocked")
        }
        return !allowed
      }

      override fun onReceivedError(
        view: WebView,
        request: WebResourceRequest,
        error: WebResourceErrorCompat,
      ) {
        if (request.isForMainFrame) {
          channel?.invokeMethod("resourceError", error.errorCode)
        }
      }

      override fun onRenderProcessGone(
        view: WebView,
        detail: RenderProcessGoneDetail,
      ): Boolean {
        channel?.invokeMethod("diagnostic", "render_process_gone")
        failPendingPrint("render_process_gone", "PDF WebView render process exited.")
        view.post { disposeCurrentTask(cancelPrint = false) }
        return true
      }
    }
    view.webChromeClient = object : WebChromeClient() {
      override fun onPermissionRequest(request: PermissionRequest) {
        request.deny()
      }

      override fun onConsoleMessage(consoleMessage: ConsoleMessage): Boolean {
        if (consoleMessage.messageLevel() == ConsoleMessage.MessageLevel.ERROR) {
          channel?.invokeMethod("diagnostic", "javascript_console_error")
        }
        return true
      }
    }
  }

  private fun postEnvelope(arguments: Any?, result: MethodChannel.Result) {
    val view = webView
    val envelope = arguments as? String
    if (view == null || envelope == null) {
      result.error("invalid_state", "PDF WebView or envelope is unavailable.", null)
      return
    }
    try {
      val script = "window.CuplivoWeb.receive(${JSONObject.quote(envelope)});"
      view.evaluateJavascript(script) { result.success(null) }
    } catch (error: Exception) {
      Log.e(PDF_LOG_TAG, "Failed to deliver PDF bridge envelope", error)
      result.error("bridge_send_failed", error.message, null)
    }
  }

  private fun print(arguments: Any?, result: MethodChannel.Result) {
    val view = webView
    if (view == null) {
      result.error("invalid_state", "PDF WebView is unavailable.", null)
      return
    }
    if (pendingPrintResult != null || printJob != null) {
      result.error("busy", "Another Android PDF print task is active.", null)
      return
    }
    val args = arguments as? Map<*, *>
    val documentName = sanitizeWebChatPrintDocumentName(
      args?.get("documentName")?.toString().orEmpty(),
    )

    try {
      val delegate = view.createPrintDocumentAdapter(documentName)
      val retained = RetainedPrintDocumentAdapter(delegate) {
        view.post { finishPrintTask() }
      }
      val attributes = PrintAttributes.Builder()
        .setMediaSize(PrintAttributes.MediaSize.ISO_A4.asPortrait())
        .setResolution(
          PrintAttributes.Resolution("cuplivo_pdf", "Cuplivo PDF", 600, 600),
        )
        .setMinMargins(
          PrintAttributes.Margins(
            PRINT_MARGIN_MILS,
            PRINT_MARGIN_MILS,
            PRINT_MARGIN_MILS,
            PRINT_MARGIN_MILS,
          ),
        )
        .setColorMode(PrintAttributes.COLOR_MODE_COLOR)
        .build()
      val manager = activity.getSystemService(Context.PRINT_SERVICE) as PrintManager
      pendingPrintResult = result
      printAdapter = retained
      printJob = manager.print(documentName, retained, attributes)
    } catch (error: Exception) {
      Log.e(PDF_LOG_TAG, "Failed to launch Android print UI", error)
      pendingPrintResult = null
      printAdapter = null
      printJob = null
      disposeCurrentTask(cancelPrint = false)
      result.error("print_failed", error.message, null)
    }
  }

  private fun finishPrintTask() {
    val result = pendingPrintResult ?: return
    val job = printJob
    pendingPrintResult = null
    val status = try {
      when {
        job?.isFailed == true -> null
        job?.isCancelled == true -> "cancelled"
        job?.isCompleted == true -> "completed"
        else -> "finished"
      }
    } catch (error: Exception) {
      Log.d(PDF_LOG_TAG, "Unable to read terminal print status", error)
      "finished"
    }
    if (status == null) {
      result.error("print_failed", "Android print job failed.", null)
    } else {
      result.success(status)
    }
    disposeCurrentTask(cancelPrint = false)
  }

  private fun failPendingPrint(code: String, message: String) {
    val result = pendingPrintResult ?: return
    pendingPrintResult = null
    result.error(code, message, null)
  }

  private fun disposeCurrentTask(cancelPrint: Boolean) {
    if (cancelPrint) {
      try {
        printJob?.cancel()
      } catch (error: Exception) {
        Log.d(PDF_LOG_TAG, "Failed to cancel Android print job", error)
      }
      pendingPrintResult?.success("cancelled")
      pendingPrintResult = null
    }
    printJob = null
    printAdapter = null
    val view = webView
    webView = null
    if (view != null) {
      try {
        WebViewCompat.removeWebMessageListener(view, "CuplivoChat")
      } catch (error: Exception) {
        Log.d(PDF_LOG_TAG, "Failed to remove PDF message listener", error)
      }
      view.stopLoading()
      view.webChromeClient = null
      (view.parent as? ViewGroup)?.removeView(view)
      view.destroy()
    }
    val host = offscreenHost
    offscreenHost = null
    (host?.parent as? ViewGroup)?.removeView(host)
  }

  fun dispose() {
    if (disposed) return
    disposed = true
    failPendingPrint("engine_detached", "Flutter engine detached during printing.")
    disposeCurrentTask(cancelPrint = true)
    channel?.setMethodCallHandler(null)
    channel = null
  }

  private fun blockedResourceResponse() = WebResourceResponse(
    "text/plain",
    Charsets.UTF_8.name(),
    403,
    "Forbidden",
    mapOf("Cache-Control" to "no-store"),
    ByteArrayInputStream(ByteArray(0)),
  )
}

private class RetainedPrintDocumentAdapter(
  private val delegate: PrintDocumentAdapter,
  private val finished: () -> Unit,
) : PrintDocumentAdapter() {
  override fun onStart() {
    delegate.onStart()
  }

  override fun onLayout(
    oldAttributes: PrintAttributes?,
    newAttributes: PrintAttributes,
    cancellationSignal: CancellationSignal,
    callback: LayoutResultCallback,
    extras: Bundle?,
  ) {
    delegate.onLayout(
      oldAttributes,
      newAttributes,
      cancellationSignal,
      callback,
      extras,
    )
  }

  override fun onWrite(
    pages: Array<out PageRange>,
    destination: ParcelFileDescriptor,
    cancellationSignal: CancellationSignal,
    callback: WriteResultCallback,
  ) {
    delegate.onWrite(pages, destination, cancellationSignal, callback)
  }

  override fun onFinish() {
    try {
      delegate.onFinish()
    } catch (error: Exception) {
      Log.e(PDF_LOG_TAG, "WebView print adapter failed to finish", error)
    } finally {
      finished()
    }
  }
}
