package com.cup11.cuplivo

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Color
import android.util.Log
import android.view.MotionEvent
import android.view.View
import android.webkit.ConsoleMessage
import android.webkit.PermissionRequest
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import androidx.webkit.WebMessageCompat
import androidx.webkit.WebResourceErrorCompat
import androidx.webkit.WebViewAssetLoader
import androidx.webkit.WebViewClientCompat
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.io.ByteArrayInputStream

internal const val WEB_CHAT_ORIGIN = "https://appassets.androidplatform.net"
internal const val WEB_CHAT_SHELL_URL =
  "$WEB_CHAT_ORIGIN/assets/flutter_assets/assets/web_chat/index.html"
internal const val WEB_CHAT_PRINT_SHELL_URL =
  "$WEB_CHAT_SHELL_URL?platform=android&mode=print"
private const val FLUTTER_ASSET_PREFIX = "flutter_assets/assets/"
private const val WEB_CHAT_ASSET_PREFIX = "${FLUTTER_ASSET_PREFIX}web_chat/"
private const val MERMAID_ASSET_PATH = "${FLUTTER_ASSET_PREFIX}mermaid.min.js"
internal const val WEB_CHAT_LOG_TAG = "CuplivoWebChat"
private const val STOP_WEB_SCROLLING_SCRIPT =
  "window.CuplivoWeb?.stopScrolling?.('programmatic');"
private const val STOP_WEB_SCROLLING_TOUCH_SCRIPT =
  "window.CuplivoWeb?.stopScrolling?.('touch');"
private const val STOP_WEB_SCROLLING_POINTER_SCRIPT =
  "window.CuplivoWeb?.stopScrolling?.('pointer');"

private fun webStopScrollingScript(origin: String?): String = when (origin) {
  "touch" -> STOP_WEB_SCROLLING_TOUCH_SCRIPT
  "pointer" -> STOP_WEB_SCROLLING_POINTER_SCRIPT
  else -> STOP_WEB_SCROLLING_SCRIPT
}

internal fun isAllowedWebChatAssetPath(path: String): Boolean {
  if (path.contains("..") || path.startsWith('/')) return false
  return path == MERMAID_ASSET_PATH ||
    (path.startsWith(WEB_CHAT_ASSET_PREFIX) && path.length > WEB_CHAT_ASSET_PREFIX.length)
}

internal fun webChatAssetMimeType(path: String): String = when (path.substringAfterLast('.').lowercase()) {
  "html" -> "text/html"
  "css" -> "text/css"
  "js", "mjs" -> "text/javascript"
  "json" -> "application/json"
  "svg" -> "image/svg+xml"
  "png" -> "image/png"
  "jpg", "jpeg" -> "image/jpeg"
  "gif" -> "image/gif"
  "webp" -> "image/webp"
  "woff" -> "font/woff"
  "woff2" -> "font/woff2"
  "ttf" -> "font/ttf"
  else -> "application/octet-stream"
}

internal fun isAllowedWebChatMainFrameUrl(url: String, printMode: Boolean): Boolean =
  url == if (printMode) WEB_CHAT_PRINT_SHELL_URL else WEB_CHAT_SHELL_URL

internal class WebChatAssetPathHandler(
  private val context: Context,
) : WebViewAssetLoader.PathHandler {
  override fun handle(path: String): WebResourceResponse {
    if (!isAllowedWebChatAssetPath(path)) return notFoundResponse()
    return try {
      val mimeType = webChatAssetMimeType(path)
      val encoding = if (mimeType.startsWith("text/") || mimeType == "application/json") {
        Charsets.UTF_8.name()
      } else {
        null
      }
      WebResourceResponse(mimeType, encoding, context.assets.open(path)).apply {
        responseHeaders = mapOf(
          "Cache-Control" to "no-store",
          "X-Content-Type-Options" to "nosniff",
        )
      }
    } catch (error: Exception) {
      Log.d(
        WEB_CHAT_LOG_TAG,
        "Failed to load bundled Web chat asset (${error.javaClass.simpleName})",
      )
      notFoundResponse()
    }
  }

  private fun notFoundResponse() = WebResourceResponse(
    "text/plain",
    Charsets.UTF_8.name(),
    404,
    "Not Found",
    mapOf("Cache-Control" to "no-store"),
    ByteArrayInputStream(ByteArray(0)),
  )
}

internal fun createWebChatAssetLoader(context: Context): WebViewAssetLoader =
  WebViewAssetLoader.Builder()
    .addPathHandler("/assets/", WebChatAssetPathHandler(context))
    .build()

@SuppressLint("SetJavaScriptEnabled")
@Suppress("DEPRECATION")
internal fun configureSecureWebChatSettings(webView: WebView) {
  webView.setBackgroundColor(Color.TRANSPARENT)
  webView.settings.apply {
    javaScriptEnabled = true
    domStorageEnabled = false
    allowFileAccess = false
    allowContentAccess = false
    allowFileAccessFromFileURLs = false
    allowUniversalAccessFromFileURLs = false
    javaScriptCanOpenWindowsAutomatically = false
    setSupportMultipleWindows(false)
    mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
    mediaPlaybackRequiresUserGesture = true
  }
}

class AndroidWebChatViewFactory(
  private val messenger: BinaryMessenger,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
  override fun create(context: Context, viewId: Int, args: Any?): PlatformView =
    AndroidWebChatPlatformView(context, messenger, viewId)
}

private class AndroidWebChatPlatformView(
  context: Context,
  messenger: BinaryMessenger,
  viewId: Int,
) : PlatformView, MethodChannel.MethodCallHandler {
  private val channel = MethodChannel(messenger, "cuplivo/web_chat/$viewId")
  private val assetLoader = createWebChatAssetLoader(context)
  private val webView = WebView(context)
  private var disposed = false
  private val supportsSecureBridge =
    WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)

  init {
    channel.setMethodCallHandler(this)
    configureWebView()
  }

  private fun configureWebView() {
    configureSecureWebChatSettings(webView)
    webView.setOnTouchListener { _, event ->
      if (event.actionMasked == MotionEvent.ACTION_DOWN) {
        stopScrolling(origin = "touch")
      }
      false
    }
    if (supportsSecureBridge) {
      WebViewCompat.addWebMessageListener(
        webView,
        "CuplivoChat",
        setOf(WEB_CHAT_ORIGIN),
      ) { _, message, sourceOrigin, isMainFrame, _ ->
        if (
          !disposed &&
          isMainFrame &&
          sourceOrigin.toString() == WEB_CHAT_ORIGIN &&
          message.type == WebMessageCompat.TYPE_STRING
        ) {
          channel.invokeMethod("bridgeMessage", message.data)
        }
      }
    }
    webView.webViewClient = object : WebViewClientCompat() {
      override fun shouldInterceptRequest(
        view: WebView,
        request: WebResourceRequest,
      ): WebResourceResponse? = assetLoader.shouldInterceptRequest(request.url)

      override fun shouldOverrideUrlLoading(
        view: WebView,
        request: WebResourceRequest,
      ): Boolean {
        if (!request.isForMainFrame) return false
        if (
          isAllowedWebChatMainFrameUrl(
            request.url.toString(),
            printMode = false,
          )
        ) return false
        channel.invokeMethod("navigationRequest", request.url.toString())
        return true
      }

      override fun onReceivedError(
        view: WebView,
        request: WebResourceRequest,
        error: WebResourceErrorCompat,
      ) {
        if (request.isForMainFrame) {
          channel.invokeMethod("resourceError", error.errorCode)
        }
      }

      override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
        channel.invokeMethod("diagnostic", "render_process_gone")
        return true
      }
    }
    webView.webChromeClient = object : WebChromeClient() {
      override fun onPermissionRequest(request: PermissionRequest) {
        request.deny()
      }

      override fun onConsoleMessage(consoleMessage: ConsoleMessage): Boolean {
        if (consoleMessage.messageLevel() == ConsoleMessage.MessageLevel.ERROR) {
          channel.invokeMethod("diagnostic", "javascript_console_error")
        }
        return true
      }
    }
  }

  override fun getView(): View = webView

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    if (disposed) {
      result.error("disposed", "Web chat view is disposed.", null)
      return
    }
    when (call.method) {
      "loadShell" -> {
        if (!supportsSecureBridge) {
          result.error(
            "web_message_listener_unsupported",
            "Android System WebView does not support the secure message bridge.",
            null,
          )
          return
        }
        webView.loadUrl(WEB_CHAT_SHELL_URL)
        result.success(null)
      }
      "runJavaScript" -> {
        val source = call.arguments as? String
        if (source == null) {
          result.error("invalid_args", "Missing JavaScript source.", null)
          return
        }
        webView.evaluateJavascript(source) { result.success(null) }
      }
      "stopScrolling" -> {
        stopScrolling(call.arguments as? String) { result.success(null) }
      }
      else -> result.notImplemented()
    }
  }

  private fun stopScrolling(
    origin: String? = null,
    onComplete: (() -> Unit)? = null,
  ) {
    // Flutter's vertical-drag recognizer buffers the native ACTION_DOWN until
    // the gesture arena resolves. Cancel Chromium's compositor fling from the
    // method channel immediately, then keep the nested timeline fixed in JS.
    // The origin is preserved into JS so touch-origin calls stay arming-free
    // on mobile while programmatic/pointer calls keep the lock.
    webView.flingScroll(0, 0)
    webView.evaluateJavascript(webStopScrollingScript(origin)) {
      onComplete?.invoke()
    }
  }

  override fun dispose() {
    if (disposed) return
    disposed = true
    channel.setMethodCallHandler(null)
    if (supportsSecureBridge) {
      WebViewCompat.removeWebMessageListener(webView, "CuplivoChat")
    }
    webView.stopLoading()
    webView.webChromeClient = null
    webView.destroy()
  }
}
