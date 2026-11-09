package com.cuplivo.cuplivo

import java.io.File
import java.util.Locale
import org.junit.Assume.assumeTrue

/**
 * Guards the cases whose fixtures are the Android runtime's own filesystem.
 *
 * The workspace/rootfs suites build real symlinks, set `r-x` modes, run `/bin/sh`
 * scripts through PRoot, and spell Android paths like `/storage/My Notes` as
 * *host* paths. None of that exists on a Windows host: symlink creation needs a
 * privilege, `setPosixFilePermissions` throws, `/bin/sh` is not executable, and
 * `/storage` is drive-relative — so those cases are skipped there instead of
 * reported as product failures. They run unchanged on a POSIX workstation.
 */
object PosixHost {
    val isWindows: Boolean =
        System.getProperty("os.name").orEmpty().lowercase(Locale.ROOT).contains("win")

    /** Symlinks, POSIX permission bits and Android-shaped absolute paths. */
    fun assumeFileSystem() {
        assumeTrue(
            "needs a POSIX host: symlinks, POSIX modes and Android-shaped paths",
            !isWindows,
        )
    }

    /** Cases that execute a `/bin/sh` fixture through the host's own shell. */
    fun assumeShell() {
        assumeTrue("needs an executable /bin/sh on the host", File("/bin/sh").canExecute())
    }
}
