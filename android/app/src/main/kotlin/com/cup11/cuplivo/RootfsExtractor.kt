package com.cup11.cuplivo

import android.util.Log
import java.io.BufferedInputStream
import java.io.EOFException
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.nio.file.Files
import java.util.Locale
import java.util.zip.GZIPInputStream

/**
 * Streaming unpacker for rootfs tarballs (.tar / .tar.gz / .tgz).
 *
 * Android's bundled tar cannot materialize the hardlinks used by Ubuntu
 * base archives (link(2) is rejected with EACCES), so entries are written
 * out manually: hardlinks fall back to a plain copy, and relative symlinks
 * are kept inside the guest root while absolute targets are preserved for
 * proot.
 */
object RootfsExtractor {
  private const val TAG = "RootfsExtractor"
  private const val BLOCK_BYTES = 512
  private const val COPY_CHUNK = 64 * 1024
  private const val MAX_INDIRECTION = 8
  private const val READ_BIT = 0b100_000_000
  private const val WRITE_BIT = 0b010_000_000
  private const val EXEC_BIT = 0b001_000_000

  /** Entry flavors a ustar type flag can denote. */
  private enum class Kind {
    FILE,
    DIR,
    LINK,
    HARD,
    LONG_NAME,
    LONG_LINK,
    PAX,
    OTHER,
  }

  /** A decoded header with any GNU/PAX indirection already resolved. */
  private class Entry(
    val name: String,
    val mode: Int,
    val size: Long,
    val mtime: Long,
    val kind: Kind,
    val link: String,
  ) {
    fun renamed(value: String?): Entry = value?.let { Entry(it, mode, size, mtime, kind, link) } ?: this

    fun relinked(value: String?): Entry = value?.let { Entry(name, mode, size, mtime, kind, it) } ?: this
  }

  fun extract(archive: File, targetDir: File) {
    if (!archive.isFile || archive.length() == 0L) {
      throw IllegalArgumentException("Archive is missing or empty: ${archive.absolutePath}")
    }
    targetDir.mkdirs()
    val fileName = archive.name.lowercase(Locale.US)
    val gzipped = fileName.endsWith(".tar.gz") || fileName.endsWith(".tgz")
    if (!gzipped && !fileName.endsWith(".tar")) {
      throw IllegalArgumentException("Unsupported archive format: ${archive.name} (only tar.gz/tgz/tar)")
    }

    val buffered = BufferedInputStream(archive.inputStream(), COPY_CHUNK)
    val input: InputStream = if (gzipped) GZIPInputStream(buffered, COPY_CHUNK) else buffered
    try {
      unpack(input, targetDir)
    } finally {
      input.close()
    }
  }

  private fun unpack(input: InputStream, targetDir: File) {
    val reader = TarStream(input)
    var extracted = 0
    while (true) {
      val entry = reader.nextEntry() ?: break
      writeEntry(reader, targetDir, entry)
      extracted++
      if (extracted % 500 == 0) {
        Log.d(TAG, "extracted $extracted entries… (${entry.name})")
      }
    }
    Log.i(TAG, "extract complete: $extracted entries → ${targetDir.absolutePath}")
  }

  /** Materializes a single entry, then consumes and realigns its record. */
  private fun writeEntry(reader: TarStream, root: File, entry: Entry) {
    val target = root.safeTarget(entry.name)
    target.parentFile?.mkdirs()
    when (entry.kind) {
      Kind.DIR -> target.mkdirs()
      Kind.LINK -> writeSymlink(root, target, entry.link)
      Kind.HARD -> writeHardlink(root, target, entry.link)
      Kind.FILE -> {
        target.outputStream().use { out -> reader.drainInto(out, entry.size) }
        applyMode(target, entry.mode)
      }
      Kind.LONG_NAME,
      Kind.LONG_LINK,
      Kind.PAX,
      Kind.OTHER -> Unit
    }
    if (entry.kind != Kind.FILE) {
      reader.skipCount(entry.size)
    }
    reader.alignRecord(entry.size)
    if (entry.mtime > 0 && entry.kind != Kind.LINK) {
      try {
        target.setLastModified(entry.mtime * 1000)
      } catch (_: Exception) {
      }
    }
  }

  /** Pull-based ustar reader that follows GNU long-name and PAX records. */
  private class TarStream(private val source: InputStream) {
    private val block = ByteArray(BLOCK_BYTES)

    /**
     * Returns the next concrete entry, or null at the end of the archive.
     *
     * Indirection records (L / K / x) are consumed recursively and their
     * overrides travel downward, so a later record wins over an earlier
     * one, matching how GNU tar emits chained long names. An override is
     * consumed by the first real entry it reaches; if that entry ends up
     * with an empty name (including via a PAX `path=`), the record is
     * skipped and extraction continues with fresh state.
     */
    fun nextEntry(
      depth: Int = 0,
      nameOverride: String? = null,
      linkOverride: String? = null,
    ): Entry? {
      val header = readHeader() ?: return null
      if (header.name.isBlank() && nameOverride == null && linkOverride == null) {
        skipCount(header.size)
        alignRecord(header.size)
        return nextEntry()
      }
      return when (header.kind) {
        Kind.LONG_NAME -> {
          guardDepth(depth)
          val name = readPayloadText(header.size)
          alignRecord(header.size)
          nextEntry(depth + 1, name, linkOverride)
        }
        Kind.LONG_LINK -> {
          guardDepth(depth)
          val link = readPayloadText(header.size)
          alignRecord(header.size)
          nextEntry(depth + 1, nameOverride, link)
        }
        Kind.PAX -> {
          guardDepth(depth)
          val fields = readPayloadText(header.size).let(::parsePaxRecords)
          alignRecord(header.size)
          nextEntry(
            depth + 1,
            fields["path"] ?: nameOverride,
            fields["linkpath"] ?: linkOverride,
          )
        }
        else -> {
          val entry = header.renamed(nameOverride).relinked(linkOverride)
          if (entry.name.isBlank()) {
            skipCount(entry.size)
            alignRecord(entry.size)
            return nextEntry()
          }
          entry
        }
      }
    }

    private fun guardDepth(depth: Int) {
      if (depth >= MAX_INDIRECTION) {
        throw IllegalStateException("Tar indirection records nested too deeply")
      }
    }

    /** Reads one 512-byte header block; null on clean EOF. */
    private fun readHeader(): Entry? {
      val got = readInto(block)
      if (got == 0) return null
      if (got < BLOCK_BYTES) throw EOFException("Tar stream ended mid-header")
      if (block.all { it == 0.toByte() }) return null
      return decodeBlock()
    }

    private fun decodeBlock(): Entry {
      val name = textField(0, 100)
      val prefix = textField(345, 155)
      val segments = listOf(prefix, name).filter { it.isNotBlank() }
      val fullName = segments.joinToString("/")
      val kind = when (block[156].toInt().toChar()) {
        '0', '\u0000' -> Kind.FILE
        '5' -> Kind.DIR
        '2' -> Kind.LINK
        '1' -> Kind.HARD
        'L' -> Kind.LONG_NAME
        'K' -> Kind.LONG_LINK
        'x', 'g' -> Kind.PAX
        else -> Kind.OTHER
      }
      return Entry(
        name = if (fullName.isBlank()) "" else sanitizeEntryPath(fullName),
        mode = octalField(100, 8).toInt(),
        size = octalField(124, 12),
        mtime = octalField(136, 12),
        kind = kind,
        link = textField(157, 100),
      )
    }

    /** NUL-terminated (zero-filled) header string. */
    private fun textField(offset: Int, width: Int): String {
      var end = offset + width
      for (i in offset until offset + width) {
        if (block[i] == 0.toByte()) {
          end = i
          break
        }
      }
      return String(block, offset, end - offset, Charsets.UTF_8).trim()
    }

    /** Octal field with GNU base-256 fallback for oversized values. */
    private fun octalField(offset: Int, width: Int): Long {
      val first = block[offset].toInt() and 0xFF
      if (first and 0x80 != 0) {
        var value = 0L
        for (i in 1 until width) {
          value = (value shl 8) or (block[offset + i].toLong() and 0xFF)
        }
        return value
      }
      val digits = textField(offset, width).lowercase(Locale.US).filter { it in '0'..'7' }
      return digits.toLongOrNull(8) ?: 0L
    }

    /** Buffers the data section of indirection records. */
    private fun readPayloadText(size: Long): String {
      if (size > Int.MAX_VALUE) throw IllegalArgumentException("Tar record too large to buffer: $size")
      return String(readExactly(size.toInt()), Charsets.UTF_8)
    }

    fun drainInto(out: OutputStream, size: Long) {
      var remaining = size
      val chunk = ByteArray(COPY_CHUNK)
      while (remaining > 0) {
        alive()
        val want = minOf(chunk.size.toLong(), remaining).toInt()
        val read = source.read(chunk, 0, want)
        if (read < 0) throw EOFException("Tar payload ended early")
        out.write(chunk, 0, read)
        remaining -= read
      }
    }

    fun skipCount(size: Long) {
      var remaining = size
      while (remaining > 0) {
        alive()
        val skipped = source.skip(remaining)
        if (skipped > 0) {
          remaining -= skipped
        } else if (source.read() >= 0) {
          remaining--
        } else {
          throw EOFException("Tar payload ended early")
        }
      }
    }

    private fun readExactly(count: Int): ByteArray {
      val buffer = ByteArray(count)
      val read = readInto(buffer)
      if (read != count) throw EOFException("Tar payload ended early")
      return buffer
    }

    /** Drops the padding that follows a record's data section. */
    fun alignRecord(size: Long) {
      val pad = size % BLOCK_BYTES
      if (pad != 0L) {
        skipCount(BLOCK_BYTES - pad)
      }
    }

    private fun readInto(buffer: ByteArray): Int {
      var offset = 0
      while (offset < buffer.size) {
        val read = source.read(buffer, offset, buffer.size - offset)
        if (read < 0) break
        offset += read
      }
      return offset
    }

    private fun alive() {
      if (Thread.currentThread().isInterrupted) {
        throw InterruptedException("Rootfs extract cancelled")
      }
    }
  }

  /** Decodes PAX records: each is "<length> <key>=<value>\n". */
  private fun parsePaxRecords(text: String): Map<String, String> {
    val fields = mutableMapOf<String, String>()
    var cursor = 0
    while (cursor < text.length) {
      val separator = text.indexOf(' ', cursor)
      if (separator < 0) break
      val recordLength = text.substring(cursor, separator).toIntOrNull() ?: break
      val recordEnd = (cursor + recordLength).coerceAtMost(text.length)
      val record = text.substring(separator + 1, recordEnd).trimEnd('\n')
      val equals = record.indexOf('=')
      if (equals > 0) {
        fields[record.substring(0, equals)] = record.substring(equals + 1)
      }
      cursor += recordLength
    }
    return fields
  }

  private fun writeSymlink(root: File, target: File, linkName: String) {
    if (linkName.isBlank()) return
    val linkTarget: File = if (File(linkName).isAbsolute) {
      // Absolute guest targets (e.g. /usr/lib/x) must survive for proot.
      File(linkName)
    } else {
      val resolved = File(target.parentFile ?: root, linkName).canonicalFile
      val rootPath = root.canonicalFile
      if (resolved.path != rootPath.path && !resolved.path.startsWith(rootPath.path + File.separator)) {
        throw IllegalArgumentException("Symlink points outside the guest rootfs: ${target.name} -> $linkName")
      }
      (target.parentFile ?: root).toPath().relativize(resolved.toPath()).toFile()
    }
    if (target.exists()) target.delete()
    try {
      Files.createSymbolicLink(target.toPath(), linkTarget.toPath())
    } catch (e: Exception) {
      Log.w(TAG, "symlink failed ${target.name} -> $linkName: ${e.message}")
    }
  }

  private fun writeHardlink(root: File, target: File, linkName: String) {
    if (linkName.isBlank()) return
    val source = try {
      root.safeTarget(linkName)
    } catch (e: Exception) {
      Log.w(TAG, "hardlink source rejected $linkName: ${e.message}")
      return
    }
    if (!source.exists()) {
      Log.w(TAG, "hardlink source missing: $linkName")
      return
    }
    if (target.exists()) target.delete()
    try {
      Files.createLink(target.toPath(), source.toPath())
    } catch (e: IOException) {
      // Android commonly rejects link(2); a copy keeps the rootfs usable.
      degradeToCopy(source, target)
    } catch (e: UnsupportedOperationException) {
      degradeToCopy(source, target)
    } catch (e: SecurityException) {
      degradeToCopy(source, target)
    }
  }

  private fun degradeToCopy(source: File, target: File) {
    source.copyTo(target, overwrite = true)
    target.setReadable(source.canRead(), false)
    target.setWritable(source.canWrite(), true)
    target.setExecutable(source.canExecute(), false)
    Log.d(TAG, "hardlink→copy ${target.name} ← ${source.name}")
  }

  /** Resolves an entry path inside [this] root, rejecting any escape. */
  private fun File.safeTarget(path: String): File {
    val root = canonicalFile
    val target = File(this, sanitizeEntryPath(path)).canonicalFile
    if (target.path != root.path && !target.path.startsWith(root.path + File.separator)) {
      throw IllegalArgumentException("Entry path escapes the extraction root: $path")
    }
    return target
  }

  private fun applyMode(file: File, mode: Int) {
    try {
      file.setReadable(mode and READ_BIT != 0, false)
      file.setWritable(mode and WRITE_BIT != 0, true)
      file.setExecutable(mode and EXEC_BIT != 0, false)
    } catch (_: Exception) {
    }
  }

  private fun sanitizeEntryPath(raw: String): String {
    val cleaned = raw.replace('\\', '/').trim().trimStart('/').removePrefix("./")
    if (cleaned.isEmpty()) throw IllegalArgumentException("Entry path is empty")
    if (cleaned.contains('\u0000')) throw IllegalArgumentException("Entry path contains a NUL byte")
    if (cleaned.split('/').contains("..")) {
      throw IllegalArgumentException("Entry path escapes the extraction root: $raw")
    }
    return cleaned
  }
}
