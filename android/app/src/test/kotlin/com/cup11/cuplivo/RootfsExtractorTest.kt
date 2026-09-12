package com.cup11.cuplivo

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.tukaani.xz.LZMA2Options
import org.tukaani.xz.XZOutputStream
import java.io.ByteArrayOutputStream
import java.io.EOFException
import java.io.File
import java.nio.file.Files
import java.util.zip.GZIPOutputStream

/** Behavior parity tests for the streaming rootfs unpacker. */
class RootfsExtractorTest {
  private val work = File(
    System.getProperty("java.io.tmpdir"),
    "rootfs_extractor_test_${System.nanoTime()}",
  )

  private val outDir: File = File(work, "extracted").apply { mkdirs() }

  /** Serializes raw tar bytes (no trailing zero blocks) into an archive file. */
  private fun writeArchive(
    fileName: String = "rootfs.tar.gz",
    builder: ByteArrayOutputStream.() -> Unit,
  ): File {
    val raw = ByteArrayOutputStream()
    raw.builder()
    raw.write(ByteArray(1024)) // end-of-archive marker
    val archive = File(work, fileName)
    archive.parentFile?.mkdirs()
    if (fileName.endsWith(".gz") || fileName.endsWith(".tgz")) {
      GZIPOutputStream(archive.outputStream()).use { it.write(raw.toByteArray()) }
    } else if (fileName.endsWith(".xz") || fileName.endsWith(".txz")) {
      XZOutputStream(archive.outputStream(), LZMA2Options()).use {
        it.write(raw.toByteArray())
      }
    } else {
      archive.writeBytes(raw.toByteArray())
    }
    return archive
  }

  /** Encodes one 512-byte ustar header block. */
  private fun header(
    name: String,
    size: Long = 0,
    type: Char = '0',
    link: String = "",
    mode: Long = 0x1ED,
    mtime: Long = 1_700_000_000,
  ): ByteArray {
    val h = ByteArray(512)
    put(h, 0, 100, name)
    putOctal(h, 100, 8, mode)
    putOctal(h, 108, 8, 0) // uid
    putOctal(h, 116, 8, 0) // gid
    putOctal(h, 124, 12, size)
    putOctal(h, 136, 12, mtime)
    h[156] = type.code.toByte()
    put(h, 157, 100, link)
    put(h, 257, 6, "ustar\u0000")
    put(h, 263, 2, "00")
    return h
  }

  /** Pads a record payload to the 512-byte block boundary. */
  private fun padded(data: ByteArray): ByteArray {
    val out = ByteArray((data.size + 511) / 512 * 512)
    data.copyInto(out)
    return out
  }

  private fun put(dst: ByteArray, offset: Int, width: Int, text: String) {
    val bytes = text.toByteArray(Charsets.UTF_8)
    bytes.copyInto(dst, offset, 0, minOf(bytes.size, width))
  }

  private fun putOctal(dst: ByteArray, offset: Int, width: Int, value: Long) {
    val digits = "%0${width - 1}o".format(value)
    put(dst, offset, width, digits + "\u0000")
  }

  private fun records(vararg chunks: ByteArray): ByteArray =
    ByteArrayOutputStream().apply {
      chunks.forEach { write(it) }
    }.toByteArray()

  private fun fileRecord(name: String, content: String): ByteArray = records(
    header(name, size = content.length.toLong()),
    padded(content.toByteArray()),
  )

  private fun dirRecord(name: String): ByteArray = header(name, type = '5')

  private fun symlinkRecord(name: String, target: String): ByteArray =
    header(name, type = '2', link = target)

  private fun hardlinkRecord(name: String, source: String): ByteArray =
    header(name, type = '1', link = source)

  private fun longNameRecord(fullName: String, real: ByteArray): ByteArray = records(
    header("././@LongLink", size = fullName.length.toLong(), type = 'L'),
    padded(fullName.toByteArray()),
    real,
  )

  private fun paxRecord(fields: Map<String, String>, real: ByteArray): ByteArray {
    val body = fields.entries.joinToString("") { (key, value) -> paxField(key, value) }
    val bodyBytes = body.toByteArray()
    return records(
      header("pax", size = bodyBytes.size.toLong(), type = 'x'),
      padded(bodyBytes),
      real,
    )
  }

  private fun paxField(key: String, value: String): String {
    val content = "$key=$value\n"
    var length = content.toByteArray().size + 2
    while (true) {
      val record = "$length $content"
      val encodedLength = record.toByteArray().size
      if (encodedLength == length) return record
      length = encodedLength
    }
  }

  private fun base256SizeHeader(name: String, size: Long, type: Char = '0'): ByteArray {
    val h = header(name, type = type)
    h[124] = 0x80.toByte()
    for (i in 125 until 136) h[i] = 0
    var value = size
    var pos = 135
    while (value > 0 && pos > 124) {
      h[pos] = (value and 0xFF).toByte()
      value = value shr 8
      pos--
    }
    return h
  }

  @Test
  fun extractsRegularFilesWithModeAndMtime() {
    val archive = writeArchive {
      write(fileRecord("bin/hello", "hi"))
    }
    RootfsExtractor.extract(archive, outDir)
    val file = File(outDir, "bin/hello")
    assertTrue(file.isFile)
    assertEquals("hi", file.readText())
    assertTrue(file.canRead())
    assertTrue(file.canWrite())
    assertTrue(file.canExecute())
    assertTrue(Math.abs(file.lastModified() - 1_700_000_000_000) <= 1_000)
  }

  @Test
  fun extractsDirectories() {
    val archive = writeArchive {
      write(dirRecord("etc/sub"))
    }
    RootfsExtractor.extract(archive, outDir)
    assertTrue(File(outDir, "etc/sub").isDirectory)
  }

  @Test
  fun keepsRelativeSymlinkTargetsInsideRootfs() {
    val archive = writeArchive {
      write(fileRecord("bin/hello", "hi"))
      write(symlinkRecord("lib/x", "../bin/hello"))
    }
    RootfsExtractor.extract(archive, outDir)
    val link = File(outDir, "lib/x")
    assertTrue(Files.isSymbolicLink(link.toPath()))
    assertEquals("../bin/hello", Files.readSymbolicLink(link.toPath()).toString())
  }

  @Test
  fun keepsAbsoluteSymlinkTargets() {
    val archive = writeArchive {
      write(symlinkRecord("usr", "/usr"))
    }
    RootfsExtractor.extract(archive, outDir)
    val link = File(outDir, "usr")
    assertTrue(Files.isSymbolicLink(link.toPath()))
    assertTrue(Files.readSymbolicLink(link.toPath()).isAbsolute)
  }

  @Test
  fun rejectsSymlinksEscapingTheRoot() {
    val archive = writeArchive {
      write(symlinkRecord("evil", "../../../../outside"))
    }
    try {
      RootfsExtractor.extract(archive, outDir)
      fail("escape symlink should have been rejected")
    } catch (expected: IllegalArgumentException) {
      // expected
    }
  }

  @Test
  fun materializesHardlinks() {
    val archive = writeArchive {
      write(fileRecord("a", "same-data"))
      write(hardlinkRecord("b", "a"))
    }
    RootfsExtractor.extract(archive, outDir)
    val a = File(outDir, "a")
    val b = File(outDir, "b")
    assertTrue(a.isFile)
    assertTrue(b.isFile)
    assertEquals("same-data", b.readText())
  }

  @Test
  fun handlesGnuLongNames() {
    val fullName = "very/long/directory/name/${"x".repeat(100)}/file"
    val archive = writeArchive {
      write(longNameRecord(fullName, header("short", size = 4)))
      write(padded("data".toByteArray()))
    }
    RootfsExtractor.extract(archive, outDir)
    val file = File(outDir, fullName)
    assertTrue(file.isFile)
    assertEquals("data", file.readText())
  }

  @Test
  fun handlesPaxPathOverrides() {
    val archive = writeArchive {
      write(paxRecord(mapOf("path" to "deep/pax/name"), header("placeholder", size = 2)))
      write(padded("ok".toByteArray()))
    }
    RootfsExtractor.extract(archive, outDir)
    assertTrue(File(outDir, "deep/pax/name").isFile)
  }

  @Test
  fun laterIndirectionRecordWins() {
    val archive = writeArchive {
      write(longNameRecord("first/name", header("dummy", size = 0, type = '5')))
      write(longNameRecord("second/name", header("dummy", size = 0, type = '5')))
    }
    RootfsExtractor.extract(archive, outDir)
    assertTrue(File(outDir, "first/name").isDirectory)
    assertTrue(File(outDir, "second/name").isDirectory)
  }

  @Test
  fun decodesBase256Sizes() {
    val payload = "payload-42-bytes".padEnd(42, 'x')
    val archive = writeArchive {
      write(base256SizeHeader("big", payload.length.toLong()))
      write(padded(payload.toByteArray()))
    }
    RootfsExtractor.extract(archive, outDir)
    val file = File(outDir, "big")
    assertTrue(file.isFile)
    assertEquals(payload, file.readText())
  }

  @Test
  fun rejectsTraversalEntries() {
    for (name in listOf("../escape.txt", "a/../../b.txt", "a/../..")) {
      val archive = writeArchive {
        write(fileRecord(name, "x"))
      }
      try {
        RootfsExtractor.extract(archive, outDir)
        fail("traversal entry should have been rejected: $name")
      } catch (expected: IllegalArgumentException) {
        // expected
      }
    }
  }

  @Test
  fun rejectsNulBytesInNames() {
    val archive = writeArchive {
      write(longNameRecord("bad\u0000name", header("placeholder", size = 1)))
      write(padded("x".toByteArray()))
    }
    try {
      RootfsExtractor.extract(archive, outDir)
      fail("NUL entry should have been rejected")
    } catch (expected: IllegalArgumentException) {
      // expected
    }
  }

  @Test
  fun skipsBlankNameRecords() {
    val archive = writeArchive {
      write(header("", size = 5))
      write(padded("junk".toByteArray()))
      write(fileRecord("real", "ok"))
    }
    RootfsExtractor.extract(archive, outDir)
    assertTrue(File(outDir, "real").isFile)
  }

  @Test
  fun throwsOnTruncatedPayloads() {
    val archive = writeArchive {
      write(header("broken", size = 2_000))
      write("only-ten".toByteArray()) // header claims far more than available
    }
    try {
      RootfsExtractor.extract(archive, outDir)
      fail("truncated payload should have raised EOFException")
    } catch (expected: EOFException) {
      // expected
    }
  }

  @Test
  fun supportsPlainTarAndTgz() {
    val plain = writeArchive("rootfs.tar") { write(fileRecord("plain", "1")) }
    RootfsExtractor.extract(plain, outDir)
    assertTrue(File(outDir, "plain").isFile)

    val tgz = writeArchive("rootfs.tgz") { write(fileRecord("tgz", "2")) }
    RootfsExtractor.extract(tgz, outDir)
    assertTrue(File(outDir, "tgz").isFile)
  }

  @Test
  fun abortsWhenWorkerThreadIsInterrupted() {
    val archive = writeArchive {
      write(fileRecord("a", "data-a".repeat(1000)))
      write(fileRecord("b", "data-b".repeat(1000)))
    }
    Thread.currentThread().interrupt()
    try {
      RootfsExtractor.extract(archive, outDir)
      fail("interrupted extraction should have aborted")
    } catch (expected: InterruptedException) {
      // expected: TarStream.alive() aborts on interrupt, which is how the
      // plugin cancels an in-flight extraction.
    } finally {
      Thread.interrupted() // clear the flag so later tests are unaffected
    }
  }

  @Test
  fun rejectsUnsupportedFormats() {
    val zip = File(work, "rootfs.zip")
    zip.writeBytes(byteArrayOf(1, 2, 3))
    try {
      RootfsExtractor.extract(zip, outDir)
      fail("zip should have been rejected")
    } catch (expected: IllegalArgumentException) {
      // expected
    }
  }

  @Test
  fun skipsDotSlashRootDirectoryEntry() {
    // Alpine minirootfs archives open with a literal "./" root-dir entry
    // (issue #322); it maps to the extraction root and must be skipped.
    val archive = writeArchive {
      write(dirRecord("./"))
      write(fileRecord("etc/hostname", "alpine"))
    }
    RootfsExtractor.extract(archive, outDir)
    assertEquals("alpine", File(outDir, "etc/hostname").readText())
  }

  @Test
  fun extractsTarXzArchives() {
    val archive = writeArchive("rootfs.tar.xz") { write(fileRecord("xz", "3")) }
    RootfsExtractor.extract(archive, outDir)
    assertTrue(File(outDir, "xz").isFile)
    assertEquals("3", File(outDir, "xz").readText())
  }

  @Test
  fun resolvesGuestAbsoluteSymlinksInsideTheRootfs() {
    val root = File(work, "guest-absolute").apply { mkdirs() }
    File(root, "bin").mkdirs()
    File(root, "bin/busybox").writeText("elf")
    assumeTrue(
      "host cannot create symlinks",
      tryCreateSymlink(File(root, "bin/sh"), "/bin/busybox"),
    )

    val resolved = resolveGuestFile(root, "bin/sh")
    assertEquals(File(root, "bin/busybox").path, resolved!!.path)
  }

  @Test
  fun returnsNullForDanglingGuestSymlinksAndEscapes() {
    val root = File(work, "guest-dangling").apply { mkdirs() }
    assumeTrue(
      "host cannot create symlinks",
      tryCreateSymlink(File(root, "bin/sh"), "/bin/busybox"),
    )

    assertNull(resolveGuestFile(root, "bin/sh"))
    assertNull(resolveGuestFile(root, "../outside"))
    assertNull(resolveGuestFile(root, "bin/../../outside"))
    assertNull(resolveGuestFile(root, "bin/missing"))
  }

  @Test
  fun guestShellPrefersBashAndFallsBackToSh() {
    val root = File(work, "guest-shell").apply { mkdirs() }
    File(root, "bin").mkdirs()
    File(root, "bin/sh").writeText("sh")
    assertEquals("/bin/sh", guestShellFor(root))

    File(root, "bin/bash").writeText("bash")
    assertEquals("/bin/bash", guestShellFor(root))
  }

  @Test
  fun guestShellFollowsAlpineStyleAbsoluteBashSymlink() {
    val root = File(work, "guest-shell-link").apply { mkdirs() }
    File(root, "bin").mkdirs()
    File(root, "bin/busybox").writeText("busybox")
    assumeTrue(
      "host cannot create symlinks",
      tryCreateSymlink(File(root, "bin/bash"), "/bin/busybox"),
    )
    assertEquals("/bin/bash", guestShellFor(root))
  }

  @Test
  fun resolvesIntermediateDirectorySymlinksInsideTheRootfs() {
    // Ubuntu's merged-usr layout: /bin is a symlink to the real usr/bin.
    val root = File(work, "guest-merged-usr").apply { mkdirs() }
    File(root, "usr/bin").mkdirs()
    File(root, "usr/bin/bash").writeText("bash")
    assumeTrue(
      "host cannot create symlinks",
      tryCreateSymlink(File(root, "bin"), "usr/bin"),
    )

    assertEquals(
      File(root, "usr/bin/bash").path,
      resolveGuestFile(root, "bin/bash")!!.path,
    )
  }

  @Test
  fun rejectsIntermediateDirectorySymlinksPointingOutsideTheRootfs() {
    val outside = File(work, "host-outside").apply { mkdirs() }
    File(outside, "sh").writeText("host-shell")
    val root = File(work, "guest-intermediate-escape").apply { mkdirs() }
    assumeTrue(
      "host cannot create symlinks",
      tryCreateSymlink(File(root, "bin"), "../host-outside"),
    )

    // The host file exists but must never be reachable through the rootfs.
    assertTrue(File(outside, "sh").isFile)
    assertNull(resolveGuestFile(root, "bin/sh"))
  }

  @Test
  fun rejectsNulBytesInGuestPaths() {
    assertNull(normalizeGuestRelativePath("bin/\u0000sh"))
    assertNull(normalizeGuestRelativePath("\u0000"))
  }

  @Test
  fun guestShellThrowsWhenRootfsHasNoShell() {
    val root = File(work, "guest-shell-missing").apply { mkdirs() }
    try {
      guestShellFor(root)
      fail("missing guest shell should have thrown")
    } catch (expected: IllegalStateException) {
      // expected
    }
  }

  private fun tryCreateSymlink(link: File, target: String): Boolean = try {
    link.parentFile?.mkdirs()
    Files.createSymbolicLink(link.toPath(), File(target).toPath())
    true
  } catch (_: Exception) {
    // Windows without developer mode cannot create symlinks.
    false
  }
}
