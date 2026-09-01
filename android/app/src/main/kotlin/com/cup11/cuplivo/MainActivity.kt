package com.cup11.cuplivo

import android.app.Activity
import android.content.ActivityNotFoundException
import android.net.Uri
import android.content.Intent
import android.os.Build
import android.util.Log
import android.view.KeyEvent
import android.view.Surface
import android.view.SurfaceHolder
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.FlutterSurfaceView
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream

class MainActivity : FlutterActivity() {
    private companion object {
        const val CREATE_DOCUMENT_REQUEST_CODE = 4107
        const val TAG = "MainActivity"
    }

    private val processTextChannelName = "app.process_text"
    private val fileSaveChannelName = "app.file_save"
    private val displayModeChannelName = "app.display_mode"
    private var processTextChannel: MethodChannel? = null
    private var fileSaveChannel: MethodChannel? = null
    private var displayModeChannel: MethodChannel? = null
    private var flutterSurfaceView: FlutterSurfaceView? = null
    private var pendingProcessText: String? = null
    private var pendingSaveResult: MethodChannel.Result? = null
    private var pendingSaveSourcePath: String? = null
    var volumeCtrlPlugin: LinuxSandboxPlugin? = null
    private var deviceLocalToolsHandler: DeviceLocalToolsHandler? = null
    private var webChatPdfHandler: AndroidWebChatPdfHandler? = null

    override fun onFlutterSurfaceViewCreated(flutterSurfaceView: FlutterSurfaceView) {
        super.onFlutterSurfaceViewCreated(flutterSurfaceView)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.VANILLA_ICE_CREAM) {
            this.flutterSurfaceView = flutterSurfaceView
            flutterSurfaceView.holder.addCallback(object : SurfaceHolder.Callback {
                override fun surfaceCreated(holder: SurfaceHolder) {
                    requestNativeHighRefreshRate()
                }

                override fun surfaceChanged(
                    holder: SurfaceHolder,
                    format: Int,
                    width: Int,
                    height: Int,
                ) {
                    requestNativeHighRefreshRate()
                }

                override fun surfaceDestroyed(holder: SurfaceHolder) = Unit
            })
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.platformViewsController.registry.registerViewFactory(
            "cuplivo/web_chat",
            AndroidWebChatViewFactory(flutterEngine.dartExecutor.binaryMessenger),
        )
        flutterEngine.plugins.add(LinuxSandboxPlugin())
        flutterEngine.plugins.add(SafMountPlugin())
        deviceLocalToolsHandler = DeviceLocalToolsHandler(this).also {
            it.configure(flutterEngine.dartExecutor.binaryMessenger)
        }
        webChatPdfHandler = AndroidWebChatPdfHandler(this).also {
            it.configure(flutterEngine.dartExecutor.binaryMessenger)
        }
        processTextChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, processTextChannelName)
        processTextChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "getInitialText" -> {
                    val text = pendingProcessText ?: extractProcessText(intent)
                    pendingProcessText = null
                    result.success(text)
                }
                else -> result.notImplemented()
            }
        }
        fileSaveChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, fileSaveChannelName)
        fileSaveChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "saveFileFromPath" -> handleSaveFileFromPath(call.arguments, result)
                else -> result.notImplemented()
            }
        }
        displayModeChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, displayModeChannelName)
        displayModeChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "requestHighRefreshRate" -> result.success(requestNativeHighRefreshRate())
                else -> result.notImplemented()
            }
        }
        pendingProcessText = extractProcessText(intent)
    }

    /**
     * Requests the highest refresh rate available at the current resolution by
     * hinting the Flutter rendering surface. Mode selection, adaptive refresh,
     * and system power limits stay with Android; only seamless switches are
     * requested. Returns false when the native path is unavailable (SDK < 35)
     * so the Dart side falls back to the legacy display-mode plugin.
     */
    private fun requestNativeHighRefreshRate(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.VANILLA_ICE_CREAM) return false

        try {
            val surface = flutterSurfaceView?.holder?.surface
            if (surface?.isValid == true) {
                val currentDisplay = display ?: return true
                val activeMode = currentDisplay.mode
                val targetRefreshRate = HighRefreshRateSelector.select(
                    activeMode.physicalWidth,
                    activeMode.physicalHeight,
                    currentDisplay.supportedModes.map { mode ->
                        SupportedDisplayMode(
                            mode.physicalWidth,
                            mode.physicalHeight,
                            mode.refreshRate,
                        )
                    },
                )
                if (targetRefreshRate != null) {
                    surface.setFrameRate(
                        targetRefreshRate,
                        Surface.FRAME_RATE_COMPATIBILITY_DEFAULT,
                        Surface.CHANGE_FRAME_RATE_ONLY_IF_SEAMLESS,
                    )
                }
            }
        } catch (error: RuntimeException) {
            Log.w(TAG, "Unable to request a high refresh rate", error)
        }
        return true
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        webChatPdfHandler?.dispose()
        webChatPdfHandler = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        val plugin = volumeCtrlPlugin
        if (plugin != null &&
            plugin.volumeCtrlEnabled &&
            event.keyCode == KeyEvent.KEYCODE_VOLUME_DOWN
        ) {
            when (event.action) {
                KeyEvent.ACTION_DOWN -> {
                    if (event.repeatCount == 0) plugin.emitVolumeCtrl(true)
                }
                KeyEvent.ACTION_UP -> {
                    plugin.emitVolumeCtrl(false)
                }
            }
            return true
        }
        return super.dispatchKeyEvent(event)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val text = extractProcessText(intent) ?: return
        val ch = processTextChannel
        if (ch != null) {
            ch.invokeMethod("onProcessText", text)
        } else {
            pendingProcessText = text
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != CREATE_DOCUMENT_REQUEST_CODE) {
            return
        }

        val destUri = if (resultCode == Activity.RESULT_OK) data?.data else null
        handleSaveDestination(destUri)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        if (deviceLocalToolsHandler?.onRequestPermissionsResult(requestCode, grantResults) == true) {
            return
        }
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    private fun extractProcessText(intent: Intent?): String? {
        if (intent?.action != Intent.ACTION_PROCESS_TEXT) return null
        val text = intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString()
        return text?.trim()?.takeIf { it.isNotEmpty() }
    }

    private fun handleSaveFileFromPath(arguments: Any?, result: MethodChannel.Result) {
        if (pendingSaveResult != null) {
            result.error("busy", "Another save operation is already in progress.", null)
            return
        }

        val args = arguments as? Map<*, *>
        val rawSourcePath = args?.get("sourcePath")?.toString()?.trim().orEmpty()
        if (rawSourcePath.isEmpty()) {
            result.error("invalid_args", "Missing sourcePath.", null)
            return
        }

        val sourceFile = File(rawSourcePath)
        if (!sourceFile.exists() || !sourceFile.isFile) {
            result.error("not_found", "Source file does not exist.", null)
            return
        }

        val suggestedFileName = args?.get("fileName")?.toString()?.trim().takeUnless { it.isNullOrEmpty() }
            ?: sourceFile.name

        pendingSaveResult = result
        pendingSaveSourcePath = sourceFile.absolutePath

        try {
            val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "application/zip"
                putExtra(Intent.EXTRA_TITLE, suggestedFileName)
            }
            startActivityForResult(intent, CREATE_DOCUMENT_REQUEST_CODE)
        } catch (e: ActivityNotFoundException) {
            pendingSaveResult = null
            pendingSaveSourcePath = null
            result.error("launch_failed", e.message, null)
        }
    }

    private fun handleSaveDestination(destUri: Uri?) {
        val result = pendingSaveResult ?: return
        val sourcePath = pendingSaveSourcePath

        if (destUri == null || sourcePath.isNullOrBlank()) {
            pendingSaveResult = null
            pendingSaveSourcePath = null
            result.success(false)
            return
        }

        Thread {
            try {
                contentResolver.openOutputStream(destUri)?.use { outputStream ->
                    FileInputStream(File(sourcePath)).use { inputStream ->
                        inputStream.copyTo(outputStream, DEFAULT_BUFFER_SIZE)
                    }
                } ?: throw IllegalStateException("Unable to open destination stream.")

                runOnUiThread {
                    pendingSaveResult = null
                    pendingSaveSourcePath = null
                    result.success(true)
                }
            } catch (e: Exception) {
                runOnUiThread {
                    pendingSaveResult = null
                    pendingSaveSourcePath = null
                    result.error("save_failed", e.message, null)
                }
            }
        }.start()
    }
}
