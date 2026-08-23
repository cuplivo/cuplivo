package com.cup11.cuplivo

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import androidx.documentfile.provider.DocumentFile
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import io.flutter.plugin.common.StandardMethodCodec
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import java.io.File
import java.io.FileInputStream
import java.io.FileNotFoundException
import java.io.FileOutputStream

/**
 * Android SAF (Storage Access Framework) bridge for external-directory
 * mounts (ADR-0037).
 *
 * The user picks a directory via ACTION_OPEN_DOCUMENT_TREE; the grant is
 * persisted with takePersistableUriPermission. All IO goes through
 * ContentResolver / DocumentFile — content URIs never expose a host path.
 * The Dart side keeps a mirror directory in two-way sync.
 */
class SafMountPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware {

  private lateinit var channel: MethodChannel
  private lateinit var appContext: Context
  private var activity: Activity? = null
  private val mainHandler = Handler(Looper.getMainLooper())

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    appContext = binding.applicationContext
    channel = MethodChannel(
      binding.binaryMessenger,
      "cuplivo/saf_mount",
      StandardMethodCodec.INSTANCE,
    )
    channel.setMethodCallHandler(this)
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
    // The engine is being torn down mid-pick (process death / engine
    // recreation while the system picker is open): fail the outstanding
    // Dart future instead of letting it hang forever. The picker itself is
    // not timeout-wrapped by design (it is interactive).
    val pending = sharedPendingPickResult
    if (pending != null) {
      sharedPendingPickResult = null
      mainHandler.post {
        pending.error("engine_detached", "SAF picker cancelled by engine teardown", null)
      }
    }
  }

  override fun onAttachedToActivity(binding: ActivityPluginBinding) {
    activity = binding.activity
    binding.addActivityResultListener(activityResultListener)
  }

  override fun onDetachedFromActivityForConfigChanges() {
    activity = null
  }

  override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
    onAttachedToActivity(binding)
  }

  override fun onDetachedFromActivity() {
    activity = null
  }

  private val activityResultListener =
    PluginRegistry.ActivityResultListener { requestCode: Int, resultCode: Int, data: Intent? ->
      if (requestCode != PICK_TREE_REQUEST_CODE) return@ActivityResultListener false
      val pending = sharedPendingPickResult
      if (pending == null) return@ActivityResultListener true
      sharedPendingPickResult = null
      if (resultCode != Activity.RESULT_OK || data?.data == null) {
        mainHandler.post { pending.success(null) }
        return@ActivityResultListener true
      }
      val uri = data.data!!
      val requiredFlags = Intent.FLAG_GRANT_READ_URI_PERMISSION or
        Intent.FLAG_GRANT_WRITE_URI_PERMISSION
      val grantedFlags = data.flags and requiredFlags
      if (grantedFlags != requiredFlags) {
        mainHandler.post {
          pending.error(
            "access_denied",
            "The selected directory did not grant persistent read/write access",
            null,
          )
        }
        return@ActivityResultListener true
      }
      try {
        appContext.contentResolver.takePersistableUriPermission(uri, grantedFlags)
      } catch (e: Exception) {
        android.util.Log.w(TAG, "takePersistableUriPermission failed: ${e.message}")
        mainHandler.post {
          pending.error(
            "access_denied",
            "The selected directory cannot grant persistent read/write access",
            null,
          )
        }
        return@ActivityResultListener true
      }
      val doc = DocumentFile.fromTreeUri(appContext, uri)
      val displayName = doc?.name?.takeIf { it.isNotBlank() } ?: uri.lastPathSegment.orEmpty()
      mainHandler.post {
        pending.success(mapOf("uri" to uri.toString(), "displayName" to displayName))
      }
      true
    }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "pickTree" -> pickTree(result)
      "list" -> {
        val uri = parseUri(call, "uri", result) ?: return
        runBackground(result) { list(uri) }
      }
      "copyToPath" -> {
        val uri = parseUri(call, "uri", result) ?: return
        val target = parseInternalFile(call, "targetPath", result) ?: return
        runBackground(result) { copyToPath(uri, target) }
      }
      "copyFromPath" -> {
        val uri = parseUri(call, "uri", result) ?: return
        val source = parseInternalFile(call, "sourcePath", result) ?: return
        runBackground(result) { copyFromPath(uri, source) }
      }
      "createFile" -> {
        val parent = parseUri(call, "parentUri", result) ?: return
        val name = call.argument<String>("name").orEmpty()
        if (name.isEmpty()) {
          result.error("bad_args", "name required", null)
          return
        }
        runBackground(result) { createFile(parent, name) }
      }
      "mkdir" -> {
        val parent = parseUri(call, "parentUri", result) ?: return
        val name = call.argument<String>("name").orEmpty()
        if (name.isEmpty()) {
          result.error("bad_args", "name required", null)
          return
        }
        runBackground(result) { mkdir(parent, name) }
      }
      "delete" -> {
        val uri = parseUri(call, "uri", result) ?: return
        runBackground(result) { delete(uri) }
      }
      "checkAccess" -> {
        val uri = parseUri(call, "uri", result) ?: return
        runBackground(result) { checkAccess(uri) }
      }
      else -> result.notImplemented()
    }
  }

  private fun pickTree(result: MethodChannel.Result) {
    val act = activity
    if (act == null) {
      result.error("no_activity", "Activity not attached", null)
      return
    }
    if (sharedPendingPickResult != null) {
      result.error("busy", "Another SAF pick is in progress", null)
      return
    }
    sharedPendingPickResult = result
    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
      addFlags(
        Intent.FLAG_GRANT_READ_URI_PERMISSION or
          Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
          Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
          Intent.FLAG_GRANT_PREFIX_URI_PERMISSION,
      )
    }
    try {
      act.startActivityForResult(intent, PICK_TREE_REQUEST_CODE)
    } catch (e: ActivityNotFoundException) {
      sharedPendingPickResult = null
      result.error("launch_failed", e.message, null)
    }
  }

  // ------------------------------------------------------------------
  // Background IO
  // ------------------------------------------------------------------

  private fun runBackground(result: MethodChannel.Result, block: () -> Any?) {
    Thread {
      try {
        val value = block()
        mainHandler.post { result.success(value) }
      } catch (e: SecurityException) {
        android.util.Log.w(TAG, "access_denied: ${e.message}")
        mainHandler.post { result.error("access_denied", e.message, null) }
      } catch (e: FileNotFoundException) {
        android.util.Log.w(TAG, "uri_not_found: ${e.message}")
        mainHandler.post { result.error("uri_not_found", e.message, null) }
      } catch (e: Exception) {
        android.util.Log.w(
          TAG,
          "access_failed: ${e.javaClass.simpleName} ${e.message}",
        )
        mainHandler.post { result.error("access_failed", e.message ?: e.javaClass.simpleName, null) }
      }
    }.start()
  }

  private fun parseUri(
    call: MethodCall,
    key: String,
    result: MethodChannel.Result,
  ): Uri? {
    val raw = call.argument<String>(key)?.trim().orEmpty()
    val uri = Uri.parse(raw)
    if (raw.isEmpty() || uri.scheme != "content") {
      result.error("bad_args", "$key must be a content URI", null)
      return null
    }
    return uri
  }

  private fun parseInternalFile(
    call: MethodCall,
    key: String,
    result: MethodChannel.Result,
  ): File? {
    val raw = call.argument<String>(key).orEmpty()
    if (raw.isBlank()) {
      result.error("bad_args", "$key required", null)
      return null
    }
    return try {
      val root = appContext.filesDir.canonicalFile
      val file = File(raw).canonicalFile
      val rootPrefix = root.path + File.separator
      if (!file.path.startsWith(rootPrefix)) {
        result.error("bad_args", "$key must stay inside app storage", null)
        null
      } else {
        file
      }
    } catch (e: Exception) {
      result.error("bad_args", "$key could not be resolved: ${e.message}", null)
      null
    }
  }

  private fun list(uri: Uri): List<Map<String, Any?>> {
    val docId = documentIdFor(uri.pathSegments)
      ?: throw FileNotFoundException("Cannot resolve tree: $uri")
    val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(uri, docId)
    val projection =
      arrayOf(
        DocumentsContract.Document.COLUMN_DOCUMENT_ID,
        DocumentsContract.Document.COLUMN_DISPLAY_NAME,
        DocumentsContract.Document.COLUMN_MIME_TYPE,
        DocumentsContract.Document.COLUMN_LAST_MODIFIED,
        DocumentsContract.Document.COLUMN_SIZE,
      )
    val cursor =
      appContext.contentResolver.query(childrenUri, projection, null, null, null)
        ?: throw FileNotFoundException("Cannot list: $uri")
    return cursor.use { c ->
      val result = mutableListOf<Map<String, Any?>>()
      while (c.moveToNext()) {
        val childDocId = c.getString(0) ?: continue
        result.add(
          mapOf(
            "name" to (c.getString(1) ?: ""),
            "isDirectory" to
              (c.getString(2) == DocumentsContract.Document.MIME_TYPE_DIR),
            "lastModified" to c.getLong(3),
            "size" to c.getLong(4),
            "uri" to
              DocumentsContract.buildDocumentUriUsingTree(uri, childDocId)
                .toString(),
          ),
        )
      }
      result
    }
  }

  private fun copyToPath(uri: Uri, target: File) {
    val input = appContext.contentResolver.openInputStream(uri)
      ?: throw FileNotFoundException("Cannot open: $uri")
    target.parentFile?.mkdirs()
    input.use { source ->
      FileOutputStream(target).use { destination -> source.copyTo(destination) }
    }
  }

  private fun copyFromPath(uri: Uri, source: File) {
    if (!source.isFile) throw FileNotFoundException("Cannot open: $source")
    // "rwt": read, write, truncate — overwrite in place without recreating
    // the document (keeps its identity and mtime behavior provider-side).
    val pfd = appContext.contentResolver.openFileDescriptor(uri, "rwt")
      ?: throw FileNotFoundException("Cannot open for write: $uri")
    pfd.use { descriptor ->
      FileInputStream(source).use { input ->
        FileOutputStream(descriptor.fileDescriptor).use { output -> input.copyTo(output) }
      }
    }
  }

  private fun createFile(parentUri: Uri, name: String): String {
    val docId = documentIdFor(parentUri.pathSegments)
      ?: throw FileNotFoundException("Cannot resolve parent: $parentUri")
    val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(parentUri, docId)
    val mime = mimeForName(name)
    val created =
      DocumentsContract.createDocument(appContext.contentResolver, childrenUri, mime, name)
        ?: throw IllegalStateException("Provider refused createFile($name)")
    return canonicalDocumentUri(parentUri, created)
  }

  private fun mkdir(parentUri: Uri, name: String): String {
    val docId = documentIdFor(parentUri.pathSegments)
      ?: throw FileNotFoundException("Cannot resolve parent: $parentUri")
    val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(parentUri, docId)
    val created =
      DocumentsContract.createDocument(
        appContext.contentResolver,
        childrenUri,
        DocumentsContract.Document.MIME_TYPE_DIR,
        name,
      ) ?: throw IllegalStateException("Provider refused createDirectory($name)")
    return canonicalDocumentUri(parentUri, created)
  }

  /**
   * Normalizes a createDocument() result to the canonical
   * `tree/.../document/<id>` form expected by the Dart side. Anything that
   * is NOT exactly that shape — a provider echoing the requested children
   * URI back, a foreign single-document URI, a `/children` tail — aborts
   * the round loudly instead of silently recording the wrong URI (which
   * would route later child pushes to the wrong level of the user's real
   * directory). The sequence is safe to retry: nothing was created under
   * the wrong path, the round can re-attempt.
   */
  private fun canonicalDocumentUri(parentUri: Uri, created: Uri): String {
    if (!isCanonicalTreeDocumentUriShape(created.pathSegments)) {
      val error = "provider returned a non-canonical document URI from createDocument()"
      android.util.Log.w(TAG, error)
      throw IllegalStateException(error)
    }
    val docId = documentIdFor(created.pathSegments)!!
    return DocumentsContract.buildDocumentUriUsingTree(parentUri, docId).toString()
  }

  private fun delete(uri: Uri): Boolean {
    return try {
      DocumentsContract.deleteDocument(appContext.contentResolver, uri)
      true
    } catch (e: Exception) {
      android.util.Log.w(TAG, "delete failed: ${e.javaClass.simpleName}: ${e.message}")
      false
    }
  }

  private fun checkAccess(uri: Uri): Boolean {
    return try {
      val treeId = DocumentsContract.getTreeDocumentId(uri)
      val rootDoc = DocumentsContract.buildDocumentUriUsingTree(uri, treeId)
      val projection = arrayOf(OpenableColumns.DISPLAY_NAME)
      val queried = appContext.contentResolver.query(rootDoc, projection, null, null, null)?.use { cursor ->
        cursor.moveToFirst()
      } ?: false
      if (queried) return true
      // Some providers refuse a DISPLAY_NAME query on the root document yet
      // still grant access — probe with the real operation (a tree listing)
      // so a valid mount is not marked unavailable.
      val doc = DocumentFile.fromTreeUri(appContext, uri) ?: return false
      try {
        doc.listFiles()
        true
      } catch (e: Exception) {
        false
      }
    } catch (e: Exception) {
      false
    }
  }

  private fun mimeForName(name: String): String {
    val ext = name.substringAfterLast('.', "")
    return if (ext.isEmpty()) {
      "application/octet-stream"
    } else {
      MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext.lowercase())
        ?: "application/octet-stream"
    }
  }

  companion object {
    private const val TAG = "SafMountPlugin"
    private const val PICK_TREE_REQUEST_CODE = 4201

    /**
     * The outstanding pickTree result, shared across plugin instances.
     * A pick is a full-screen interactive flow that can outlive the engine
     * that started it (rotation / engine recreation while the system picker
     * is open): a per-instance field would be dropped on recreation and the
     * Dart future would hang forever. The shared holder lets a reattached
     * instance still complete (or fail, on teardown) the original future.
     */
    @Volatile
    var sharedPendingPickResult: MethodChannel.Result? = null
  }
}

/**
 * SAF document addressing (issue #528): maps a content URI's path segments
 * to the document-ID segment a subtree operation must key off.
 *
 * - `tree/<treeId>` (mount root) → `<treeId>` — the tree's root document.
 * - `tree/<treeId>/document/<docId>` (child, or its `/children` tail) →
 *   `<docId>` — the child itself. A child URI must NEVER be re-resolved
 *   with [DocumentFile.fromTreeUri]: that API keeps only the tree id and
 *   silently returns the tree root, which made the walker re-enumerate the
 *   mount root on every directory step until the 30 s round timeout.
 *
 * Deliberately pure Kotlin ([List], no [android.net.Uri]) so the grammar
 * is host-JVM unit-testable; the plugin wires [Uri.pathSegments] through.
 * Anything else (foreign `document/`-first shapes, empty ids) resolves to
 * null and is rejected by the caller.
 */
internal fun documentIdFor(pathSegments: List<String>): String? {
  if (pathSegments.size < 2 || pathSegments[0] != "tree") return null
  val treeId = pathSegments[1]
  return when {
    pathSegments.size == 2 && treeId.isNotEmpty() -> treeId
    pathSegments.size >= 4 &&
        pathSegments[2] == "document" &&
        pathSegments[3].isNotEmpty() -> pathSegments[3]
    else -> null
  }
}

/**
 * True only for the canonical created-document shape
 * `tree/<treeId>/document/<docId>` — exactly four segments, no `/children`
 * tail. `documentIdFor` stays tolerant (a children tail is a legitimate
 * listing target), but a CREATE result must be this exact shape: a provider
 * echoing the requested children URI back (5 segments, the PARENT's id)
 * would otherwise be silently treated as the created URI and route later
 * pushes to the wrong level. Anything else is rejected by the caller.
 */
internal fun isCanonicalTreeDocumentUriShape(pathSegments: List<String>): Boolean =
  pathSegments.size == 4 &&
      pathSegments[0] == "tree" &&
      pathSegments[2] == "document" &&
      pathSegments[1].isNotEmpty() &&
      pathSegments[3].isNotEmpty()
