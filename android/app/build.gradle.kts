import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android Gradle plugin.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.cup11.cuplivo"
    compileSdk = flutter.compileSdkVersion
//    ndkVersion = flutter.ndkVersion
    ndkVersion = "27.0.12077973"
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.cup11.cuplivo"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
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

    testOptions {
        // JVM unit tests exercise Java-only Android services such as the
        // rootfs extractor; framework logging stubs should behave as no-ops.
        unitTests.isReturnDefaultValues = true
    }

    packaging {
        jniLibs {
            // Extract vendored proot binaries to nativeLibraryDir at install
            // time (system-set exec bit + SELinux label), so the sandbox can
            // spawn them directly instead of copying to filesDir and chmod.
            useLegacyPackaging = true
        }
    }
}

// AndroidX brings the standalone ListenableFuture stub transitively, while
// termux-shared supplies Guava, which contains the same class.
configurations.configureEach {
    exclude(group = "com.google.guava", module = "listenablefuture")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_11
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Required for core library desugaring (used by flutter_local_notifications)
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")
    // Secure HTTPS-origin loading for the Android Web conversation shell.
    implementation("androidx.webkit:webkit:1.15.0")
    implementation("androidx.core:core:1.13.1")
    // SAF document-tree access for external-directory mounts (ADR-0037)
    implementation("androidx.documentfile:documentfile:1.0.1")
    implementation(project(":terminal-emulator"))
    implementation(project(":terminal-view"))
    implementation(project(":termux-shared"))
    testImplementation("junit:junit:4.13.2")
}
