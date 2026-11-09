package com.cuplivo.cuplivo.workspace

import com.cuplivo.cuplivo.PosixHost
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

class ProotArgvTest {
    @Test
    fun execArgvMatchesGoldenString() {
        val nativeLibDir = File("/nativelib")
        val rootfsDir = File("/data/rootfs")
        val tmpDir = File("/data/tmp")
        val launch = ProotCommand.build(
            nativeLibDir = nativeLibDir,
            rootfsDir = rootfsDir,
            tmpDir = tmpDir,
            binds = listOf(BindMount("/host/files", "/workspace")),
            cwd = "/workspace",
            command = "echo hello",
            env = linkedMapOf(
                "HOME" to "/root",
                "PATH" to "/bin",
            ),
            includeLibraryPath = true,
            kernelRelease = null,
        )
        // The argv spells host paths the way the host does, so the golden is
        // derived from the same `File`s instead of restating them: `/nativelib`
        // is an absolute path on Android and drive-relative on Windows.
        val golden =
            "${File(nativeLibDir, ProotCommand.EXEC_LIB).absolutePath} --root-id --link2symlink --kill-on-exit " +
                "-r ${rootfsDir.absolutePath} -w /workspace -b /host/files:/workspace " +
                "-b /dev -b /proc -b /sys /usr/bin/env -i HOME=/root PATH=/bin LANG=C.UTF-8 " +
                "/bin/sh -lc " + ProotCommand.BASH_EVAL + " kelivo /workspace echo hello"
        assertEquals(golden, launch.argv.joinToString(" "))
        assertEquals(rootfsDir.parentFile!!.absolutePath, launch.workingDirectory.absolutePath)
        assertEquals(
            File(nativeLibDir, ProotCommand.LOADER_LIB).absolutePath,
            launch.processEnv["PROOT_LOADER"],
        )
        assertEquals(tmpDir.absolutePath, launch.processEnv["PROOT_TMP_DIR"])
        assertEquals(tmpDir.absolutePath, launch.processEnv["TMPDIR"])
        assertEquals(
            tmpDir.absolutePath + File.pathSeparator + nativeLibDir.absolutePath,
            launch.processEnv["LD_LIBRARY_PATH"],
        )
    }

    @Test
    fun ptyArgvUsesLoginShellAndTerm() {
        val launch = ProotCommand.build(
            nativeLibDir = File("/nativelib"),
            rootfsDir = File("/data/rootfs"),
            tmpDir = File("/data/tmp"),
            binds = emptyList(),
            cwd = "/root",
            command = null,
            env = linkedMapOf("HOME" to "/root"),
            includeLibraryPath = false,
            kernelRelease = null,
        )
        assertEquals("/bin/sh", launch.argv[launch.argv.size - 2])
        assertEquals("-l", launch.argv.last())
        assertEquals("HOME=/root", launch.argv[launch.argv.indexOf("-i") + 1])
        assertTrue(launch.argv.contains("TERM=xterm-256color"))
        assertTrue(launch.argv.contains("PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"))
    }

    @Test
    fun emptyExecEnvironmentExportsGuestDefaultsToChildProcesses() {
        assumeTrue(File("/bin/bash").canExecute() && File("/usr/bin/env").canExecute())
        val launch = ProotCommand.build(
            nativeLibDir = File("/nativelib"),
            rootfsDir = File("/data/rootfs"),
            tmpDir = File("/data/tmp"),
            binds = emptyList(),
            cwd = "/",
            command = "/usr/bin/env",
            shell = "/bin/bash",
            env = emptyMap(),
            includeLibraryPath = false,
            kernelRelease = null,
        )
        val argv = launch.argv.drop(launch.argv.indexOf("/usr/bin/env")).toMutableList()
        // Run the guest shell launch on the test host without its login profiles,
        // which could mask a missing exported PATH by setting one themselves.
        argv.addAll(argv.indexOf("/bin/bash") + 1, listOf("--noprofile", "--norc"))
        val process = ProcessBuilder(argv).redirectErrorStream(true).start()
        val output = process.inputStream.bufferedReader().use { it.readText() }
        assertEquals(output, 0, process.waitFor())
        val lines = output.lineSequence().toSet()
        assertTrue(output, lines.contains("PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"))
        assertTrue(output, lines.contains("HOME=/root"))
        assertTrue(output, lines.contains("LANG=C.UTF-8"))
    }

    @Test
    fun readOnlyPreferenceUsesUnmodifiedProotForExecAndPty() {
        PosixHost.assumeFileSystem()
        for (command in listOf("echo hello", null)) {
            val binds = listOf(BindMount("/storage/My Notes", "/mounts/Notes", true))
            validateExternalMounts(binds)
            val launch = ProotCommand.build(File("/libs"), File("/rootfs"), File("/tmp"), binds, "/workspace", command, emptyMap(), kernelRelease = null)
            assertEquals("/libs/libproot_exec.so", launch.argv.first())
            assertTrue(launch.argv.contains("/storage/My Notes:/mounts/Notes"))
            assertFalse(launch.argv.any { it.startsWith("--read-only") })
            assertFalse(launch.processEnv.containsKey("PROOT_NO_SECCOMP"))
        }
    }

    @Test
    fun kernelDefaultUsesProcessBitnessAndActualKernelRelease() {
        val release = "4.19.198-28701120-abA135FXXSEEZB2"
        var reads = 0
        val readRelease = { reads++; release }
        assertNull(ProotCommand.defaultKernelRelease(true, readRelease))
        assertEquals(0, reads)
        // A 32-bit APK is affected even when the phone has an ARM64 CPU.
        assertEquals(release, ProotCommand.defaultKernelRelease(false, readRelease))
        assertEquals(1, reads)
    }

    @Test
    fun kernelCompatibilityAppliesToExecAndPtyWithoutChangingGuestCommand() {
        for (release in listOf("4.19.198-28701120-abA135FXXSEEZB2", "6.1.128-android14")) {
            for (command in listOf("date +%s", null)) {
                val launch = ProotCommand.build(
                    nativeLibDir = File("/libs"),
                    rootfsDir = File("/rootfs"),
                    tmpDir = File("/tmp"),
                    binds = emptyList(),
                    cwd = "/workspace",
                    command = command,
                    env = emptyMap(),
                    extraArgs = listOf("-v", "1"),
                    kernelRelease = release,
                )
                assertEquals(
                    listOf("--kernel-release=$release", "-v", "1", "-r", File("/rootfs").absolutePath),
                    launch.argv.subList(4, 9),
                )
                assertEquals(1, launch.argv.count { it.startsWith("--kernel-release=") })
                if (command == null) {
                    assertEquals(listOf("/bin/sh", "-l"), launch.argv.takeLast(2))
                    assertTrue(launch.argv.contains("TERM=xterm-256color"))
                } else {
                    assertEquals(command, launch.argv.last())
                    assertTrue(launch.argv.contains("-lc"))
                }
            }
        }
    }

    @Test
    fun explicitKernelOptionsRemainUnchangedForExecAndPty() {
        val overrides = listOf(
            listOf("-k", "5.10.0"),
            listOf("-k 5.10.0"),
            listOf("--kernel-release=5.10.0"),
        )
        for (override in overrides) {
            for (command in listOf("date +%s", null)) {
                val args = listOf("-v", "1") + override
                val launch = ProotCommand.build(
                    File("/libs"), File("/rootfs"), File("/tmp"), emptyList(),
                    "/", command, emptyMap(), extraArgs = args, kernelRelease = "4.19.198",
                )
                assertEquals(args, launch.argv.subList(4, 4 + args.size))
                assertEquals("-r", launch.argv[4 + args.size])
                assertFalse(launch.argv.contains("--kernel-release=4.19.198"))
            }
        }
    }

    @Test(expected = IllegalArgumentException::class)
    fun externalMountGuestCannotEscapeMountRoot() {
        validateExternalMounts(listOf(BindMount("/storage/Notes", "/mounts/../root")))
    }

    @Test(expected = IllegalArgumentException::class)
    fun externalMountHostCannotInjectProotDelimiter() {
        validateExternalMounts(listOf(BindMount("/storage/Notes:other", "/mounts/Notes")))
    }
}
