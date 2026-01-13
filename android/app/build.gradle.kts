plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    val includeX86 = (project.findProperty("includeX86") as String?)?.toBoolean() == true
    // Optional: compress native libs to shrink APKs (faster installs over ADB).
    val compressNativeLibs =
        (project.findProperty("compressNativeLibs") as String?)?.toBoolean() == true
    val targetPlatforms = (project.findProperty("target-platform") as String?)
        ?.split(',')
        ?.map { it.trim() }
        ?.filter { it.isNotEmpty() }
        .orEmpty()

    fun abiForTargetPlatform(platform: String): String? =
        when (platform) {
            "android-arm" -> "armeabi-v7a"
            "android-arm64" -> "arm64-v8a"
            "android-x86" -> "x86"
            "android-x64" -> "x86_64"
            else -> null
        }

    // Flutter passes -Ptarget-platform=... for `flutter run`, so we can build only the
    // ABI required by the current device. This drastically reduces APK size and the
    // time spent installing over wireless ADB.
    val flutterAbis = targetPlatforms.mapNotNull(::abiForTargetPlatform).distinct()

    // Fallback for builds that don't set -Ptarget-platform (e.g. some Gradle/IDE builds).
    val defaultAbis = buildList {
        add("armeabi-v7a")
        add("arm64-v8a")
        if (includeX86) {
            add("x86")
            add("x86_64")
        }
    }

    val selectedAbis = if (flutterAbis.isNotEmpty()) flutterAbis else defaultAbis

    namespace = "com.example.validador_retratos_flutter"
    compileSdk = 36
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.validador_retratos_flutter"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // Keep `flutter run` installs smaller/faster by building only the device ABI.
        // (Override for non-Flutter builds with: -PincludeX86=true)
        ndk {
            abiFilters.clear()
            abiFilters += selectedAbis
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    packaging {
        jniLibs {
            useLegacyPackaging = compressNativeLibs
            val excluded = buildSet {
                if (!selectedAbis.contains("armeabi-v7a")) add("**/armeabi-v7a/**")
                if (!selectedAbis.contains("arm64-v8a")) add("**/arm64-v8a/**")
                if (!selectedAbis.contains("x86")) add("**/x86/**")
                if (!selectedAbis.contains("x86_64")) add("**/x86_64/**")
            }
            excludes += excluded
        }
    }
}

flutter {
    source = "../.."
}
