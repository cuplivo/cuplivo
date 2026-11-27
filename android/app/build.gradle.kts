import java.io.File
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android Gradle plugin.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.cuplivo.cuplivo"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "28.2.13676358"
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.cuplivo.cuplivo"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // Flutter controls APK ABI filtering, including --split-per-abi.
        externalNativeBuild {
            cmake {
                abiFilters += listOf("armeabi-v7a", "arm64-v8a", "x86_64")
            }
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
        }
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }

    testOptions {
        unitTests.isReturnDefaultValues = true
        unitTests.isIncludeAndroidResources = true
    }

    val keystorePropertiesFile = rootProject.file("key.properties")
    val keystoreProperties = Properties()
    if (keystorePropertiesFile.exists()) {
        keystoreProperties.load(keystorePropertiesFile.inputStream())
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
            }
        }
    }

    buildTypes {
        getByName("release") {
            if (keystorePropertiesFile.exists()) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_11
    }
}

flutter {
    source = "../.."
}

/**
 * The POSIX shell `fetchProot` runs its script with.
 *
 * Plain `bash` from PATH is wrong on Windows: `C:\Windows\System32\bash.exe` is
 * the WSL relay, which dies with `execvpe(/bin/bash): No such file or
 * directory` when no distribution is installed — the failure names neither WSL
 * nor the real problem. Git for Windows ships a real bash *and* the coreutils
 * the script needs (`mktemp`, `sha256sum`, a POSIX `find`), so prefer its own
 * copy, located through `git --exec-path` so any install location works. Then
 * MSYS2/Cygwin, then PATH for Linux and macOS.
 *
 * Override with `-Pcuplivo.bash=<path>` or `CUPLIVO_BASH=<path>`.
 */
fun resolvePosixShell(): String {
    val override = (project.findProperty("cuplivo.bash") as String?)
        ?.takeIf { it.isNotBlank() }
        ?: System.getenv("CUPLIVO_BASH")?.takeIf { it.isNotBlank() }
    if (override != null) return override

    // <gitRoot>/mingw64/libexec/git-core → <gitRoot>/bin/bash.exe
    val gitBash = runCatching {
        val execPath = providers.exec { commandLine("git", "--exec-path") }
            .standardOutput.asText.get().trim()
        File(execPath).parentFile?.parentFile?.parentFile?.resolve("bin/bash.exe")
    }.getOrNull()

    return listOfNotNull(
        gitBash,
        System.getenv("ProgramFiles")?.let { File(it, "Git/bin/bash.exe") },
        System.getenv("ProgramFiles(x86)")?.let { File(it, "Git/bin/bash.exe") },
        System.getenv("LOCALAPPDATA")?.let { File(it, "Programs/Git/bin/bash.exe") },
        File("C:/msys64/usr/bin/bash.exe"),
        File("C:/cygwin64/bin/bash.exe"),
    ).firstOrNull { it.isFile }?.absolutePath ?: "bash"
}

val requiredProotLibs = listOf(
    "armeabi-v7a/libproot_exec.so",
    "armeabi-v7a/libproot_loader.so",
    "armeabi-v7a/libtalloc.so",
    "armeabi-v7a/libandroid-shmem.so",
    "arm64-v8a/libproot_exec.so",
    "arm64-v8a/libproot_loader.so",
    "arm64-v8a/libtalloc.so",
    "arm64-v8a/libandroid-shmem.so",
    "x86_64/libproot_exec.so",
    "x86_64/libproot_loader.so",
    "x86_64/libtalloc.so",
    "x86_64/libandroid-shmem.so",
)

tasks.register<Exec>("fetchProot") {
    val repoRoot = rootProject.projectDir.parentFile
    val posixShell = resolvePosixShell()
    // Relative, not absolute: an MSYS bash would read `D:\...\tool\x.sh` as one
    // word with escape characters. The working directory below anchors it.
    commandLine(posixShell, "tool/fetch_proot.sh")
    workingDir = repoRoot
    doFirst {
        logger.lifecycle("fetchProot: shell=$posixShell cwd=$repoRoot")
    }
    onlyIf {
        val jniLibs = layout.projectDirectory.dir("src/main/jniLibs")
        requiredProotLibs.any { name ->
            val so = jniLibs.file(name).asFile
            !so.isFile || so.length() == 0L
        }
    }
}

tasks.whenTaskAdded {
    if (name == "preBuild") {
        dependsOn("fetchProot")
    }
}
tasks.findByName("preBuild")?.dependsOn("fetchProot")

dependencies {
    implementation("androidx.browser:browser:1.9.0")
    implementation("org.tukaani:xz:1.10")
    // Required for core library desugaring (used by flutter_local_notifications)
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.16.1")
}
