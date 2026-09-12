package com.cup11.cuplivo

import android.app.Activity
import android.content.ActivityNotFoundException
import android.net.Uri
import android.content.Intent
import android.os.Build
import android.provider.OpenableColumns
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
import java.util.UUID

class MainActivity : FlutterActivity() {
    private companion object {
        const val CREATE_DOCUMENT_REQUEST_CODE = 4107
        const val TAG = "MainActivity"
        const val SHARE_STAGING_TTL_MS = 24 * 60 * 60 * 1000L
        const val SHARE_MAX_FILES = 20
        const val SHARE_MAX_TOTAL_BYTES = 200L * 1024 * 1024
    }

    private val processTextChannelName = "app.process_text"
    private val fileSaveChannelName = "app.file_save"
    private val displayModeChannelName = "app.display_mode"
    private val inboundShareChannelName = "app.inbound_share"
    private var processTextChannel: MethodChannel? = null
    private var fileSaveChannel: MethodChannel? = null
    private var displayModeChannel: MethodChannel? = null
    private var inboundShareChannel: MethodChannel? = null
    private var flutterSurfaceView: FlutterSurfaceView? = null
    private var pendingProcessText: String? = null
    @Volatile private var pendingShare: Map<String, Any?>? = null
    private var launchShareExtracted = false
    private var pendingSaveResult: MethodChannel.Result? = null
    private var pendingSaveSourcePath: String? = null
    var volumeCtrlPlugin: LinuxSandboxPlugin? = null
    private var deviceLocalToolsHandler: DeviceLocalToolsHandler? = null
    private var webChatPdfHandler: AndroidWebChatPdfHandler? = null
    private var backgroundProtectionHandler: BackgroundProtectionHandler? = null

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
        flutterEngine.plugins.add(WorkspaceTerminalPlugin())
        deviceLocalToolsHandler = DeviceLocalToolsHandler(this).also {
            it.configure(flutterEngine.dartExecutor.binaryMessenger)
        }
        webChatPdfHandler = AndroidWebChatPdfHandler(this).also {
            it.configure(flutterEngine.dartExecutor.binaryMessenger)
        }
        backgroundProtectionHandler = BackgroundProtectionHandler(this).also {
            it.configure(flutterEngine.dartExecutor.binaryMessenger)
        }
        ProactiveCareSettingsHandler(this).configure(flutterEngine.dartExecutor.binaryMessenger)
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
        inboundShareChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, inboundShareChannelName)
        inboundShareChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "getInitialShare" -> handleGetInitialShare(result)
                else -> result.notImplemented()
            }
        }
        pruneShareStaging()
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

    override fun onDestroy() {
        deviceLocalToolsHandler?.dispose()
        super.onDestroy()
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
        val text = extractProcessText(intent)
        if (text != null) {
            val ch = processTextChannel
            if (ch != null) {
                ch.invokeMethod("onProcessText", text)
            } else {
                pendingProcessText = text
            }
            return
        }
        if (isShareIntent(intent)) {
            val shareIntent = intent
            Thread {
                val payload =
                    try {
                        extractSharePayload(shareIntent)
                    } catch (error: Exception) {
                        // Uncaught on a plain thread this would kill the process.
                        Log.w(TAG, "Failed to parse shared content", error)
                        null
                    }
                if (payload != null) {
                    runOnUiThread {
                        val ch = inboundShareChannel
                        if (ch != null) {
                            ch.invokeMethod("onShare", payload)
                        } else {
                            pendingShare = payload
                        }
                    }
                }
            }.start()
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

    private fun isShareIntent(intent: Intent?): Boolean {
        val action = intent?.action ?: return false
        return action == Intent.ACTION_SEND || action == Intent.ACTION_SEND_MULTIPLE
    }

    /**
     * Cold-start pull for the OS share target. Returns the payload staged from
     * the launch intent (one-shot) or null when there is nothing to consume.
     */
    private fun handleGetInitialShare(result: MethodChannel.Result) {
        val pending = pendingShare
        if (pending != null) {
            pendingShare = null
            result.success(pending)
            return
        }
        if (launchShareExtracted || !isShareIntent(intent)) {
            result.success(null)
            return
        }
        // Restoring the task from Recents re-delivers the original launch
        // intent; that share was already consumed, so do not import it twice.
        if (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) {
            result.success(null)
            return
        }
        launchShareExtracted = true
        val launchIntent = intent
        Thread {
            val payload =
                try {
                    extractSharePayload(launchIntent)
                } catch (error: Exception) {
                    Log.w(TAG, "Failed to parse shared content", error)
                    null
                }
            runOnUiThread { result.success(payload) }
        }.start()
    }

    /**
     * Parses an ACTION_SEND / ACTION_SEND_MULTIPLE intent into the Dart payload
     * map, copying every content:// stream into a per-share staging directory.
     * Returns null when the intent carries no usable content.
     */
    private fun extractSharePayload(intent: Intent): Map<String, Any?>? {
        // Some sources put the caption in EXTRA_SUBJECT instead of EXTRA_TEXT.
        val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()?.trim()?.takeIf { it.isNotEmpty() }
            ?: intent.getCharSequenceExtra(Intent.EXTRA_SUBJECT)?.toString()?.trim()?.takeIf { it.isNotEmpty() }
        val uris = mutableListOf<Uri>()
        when (intent.action) {
            Intent.ACTION_SEND -> {
                @Suppress("DEPRECATION")
                val uri = intent.getParcelableExtra(Intent.EXTRA_STREAM) as? Uri
                if (uri != null) uris.add(uri)
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                @Suppress("DEPRECATION")
                val list = intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
                if (list != null) uris.addAll(list)
            }
        }
        if (text == null && uris.isEmpty()) return null

        val stagingDir = File(cacheDir, "share_inbox/${UUID.randomUUID()}")
        val images = mutableListOf<String>()
        val files = mutableListOf<Map<String, Any?>>()
        var failed = 0

        // Bound count and bytes before touching the cache: a hostile source
        // must not be able to fill internal storage. Mirrors the Dart
        // importer's budget (InboundShareImporter.maxInboundTotalBytes).
        if (uris.size > SHARE_MAX_FILES) {
            failed += uris.size - SHARE_MAX_FILES
            while (uris.size > SHARE_MAX_FILES) {
                uris.removeAt(uris.size - 1)
            }
        }
        var remainingBytes = SHARE_MAX_TOTAL_BYTES

        for (uri in uris) {
            // One hostile/uninstalled provider must fail only its own item,
            // not the whole share.
            val copied =
                try {
                    val resolved = contentResolver.getType(uri) ?: intent.type
                    val mime = if (resolved.isNullOrBlank() || resolved == "*/*") {
                        "application/octet-stream"
                    } else {
                        resolved.lowercase()
                    }
                    val displayName = resolveDisplayName(uri, mime)
                    val destination = uniqueTarget(stagingDir, sanitizeFileName(displayName))
                    val bytes = copyUriToFile(uri, destination, remainingBytes)
                    if (bytes < 0) {
                        destination.delete()
                        null
                    } else {
                        Triple(destination, mime, bytes)
                    }
                } catch (error: Exception) {
                    Log.w(TAG, "Failed to stage shared uri: $uri", error)
                    null
                }
            if (copied == null) {
                failed++
                continue
            }
            val (destination, mime, bytes) = copied
            remainingBytes -= bytes
            if (mime.startsWith("image/")) {
                images.add(destination.absolutePath)
            } else {
                files.add(
                    hashMapOf(
                        "path" to destination.absolutePath,
                        "name" to destination.name,
                        "mime" to mime,
                    ),
                )
            }
        }

        val payload = HashMap<String, Any?>()
        payload["text"] = text
        payload["images"] = images
        payload["files"] = files
        payload["failed"] = failed
        payload["stagingDir"] =
            if (images.isNotEmpty() || files.isNotEmpty()) stagingDir.absolutePath else null
        return payload
    }

    /**
     * Deletes share staging directories older than [SHARE_STAGING_TTL_MS] so a
     * process death between native copy and Dart import cannot accumulate
     * orphaned files in the cache.
     */
    private fun pruneShareStaging() {
        Thread {
            val root = File(cacheDir, "share_inbox")
            val entries = root.listFiles() ?: return@Thread
            val cutoff = System.currentTimeMillis() - SHARE_STAGING_TTL_MS
            for (entry in entries) {
                if (entry.lastModified() >= cutoff) continue
                if (!entry.deleteRecursively()) {
                    Log.w(TAG, "Unable to prune stale share staging: ${entry.name}")
                }
            }
        }.start()
    }

    private fun resolveDisplayName(uri: Uri, mime: String): String {
        try {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (index >= 0 && cursor.moveToFirst()) {
                    val name = cursor.getString(index)
                    if (!name.isNullOrBlank()) return name
                }
            }
        } catch (error: Exception) {
            Log.w(TAG, "Unable to resolve display name for $uri", error)
        }
        val extension = android.webkit.MimeTypeMap.getSingleton().getExtensionFromMimeType(mime)
        val base = "shared_${System.currentTimeMillis()}"
        return if (extension.isNullOrEmpty()) base else "$base.$extension"
    }

    private fun sanitizeFileName(raw: String): String {
        val base = File(raw).name
        val cleaned = base.replace(Regex("[\\\\/:*?\"<>|\\u0000-\\u001f]"), "_").trim()
        if (cleaned.isEmpty() || cleaned == "." || cleaned == "..") {
            return "shared_${System.currentTimeMillis()}"
        }
        if (cleaned.length <= 200) return cleaned
        // Preserve the extension when truncating: Dart infers mime from it.
        val dot = cleaned.lastIndexOf('.')
        if (dot <= 0 || dot == cleaned.length - 1) return cleaned.substring(0, 200)
        val extension = cleaned.substring(dot)
        val keep = 200 - extension.length
        return if (keep <= 0) cleaned.substring(0, 200) else cleaned.substring(0, keep) + extension
    }

    private fun uniqueTarget(dir: File, name: String): File {
        if (!dir.exists()) dir.mkdirs()
        var candidate = File(dir, name)
        if (!candidate.exists()) return candidate
        val dot = name.lastIndexOf('.')
        val base = if (dot > 0) name.substring(0, dot) else name
        val extension = if (dot > 0) name.substring(dot) else ""
        var counter = 1
        while (candidate.exists()) {
            candidate = File(dir, "$base($counter)$extension")
            counter++
        }
        return candidate
    }

    /**
     * Copies [uri] into [destination], stopping once [maxBytes] would be
     * exceeded. Returns the number of bytes copied, or -1 on failure/budget
     * exhaustion (the caller deletes the partial file).
     */
    private fun copyUriToFile(uri: Uri, destination: File, maxBytes: Long): Long {
        if (maxBytes <= 0) {
            Log.w(TAG, "Share byte budget exhausted before $uri")
            return -1
        }
        return try {
            val input = contentResolver.openInputStream(uri)
            if (input == null) {
                Log.w(TAG, "No input stream for shared uri: $uri")
                return -1
            }
            input.use { source ->
                destination.outputStream().use { output ->
                    val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                    var total = 0L
                    while (true) {
                        val read = source.read(buffer)
                        if (read < 0) break
                        total += read
                        if (total > maxBytes) {
                            Log.w(TAG, "Shared uri exceeds the share byte budget: $uri")
                            return -1
                        }
                        output.write(buffer, 0, read)
                    }
                    total
                }
            }
        } catch (error: Exception) {
            Log.w(TAG, "Failed to copy shared uri: $uri", error)
            -1
        }
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
