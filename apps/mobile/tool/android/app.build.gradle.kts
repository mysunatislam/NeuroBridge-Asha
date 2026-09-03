plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "org.fingerspeak.mobile"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "org.fingerspeak.mobile"
        // Floor of 23 rather than plain flutter.minSdkVersion:
        // flutter_secure_storage 9.x stores Pi credentials through AndroidX
        // Security Crypto, which requires API 23. maxOf() means a future
        // Flutter SDK that raises its own floor still wins.
        minSdk = maxOf(flutter.minSdkVersion, 23)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // GitHub produces a testable artifact, not a store-signed release.
            signingConfig = signingConfigs.getByName("debug")

            // Code shrinking is OFF for this evaluation artifact.
            //
            // Do not enable it without keeping proguard-rules.pro wired below.
            // A previous minified build removed
            //   androidx.work.impl.WorkDatabase_Impl.<init>()
            // which Room instantiates reflectively by name. WorkManager
            // auto-initialises through androidx.startup's ContentProvider, so
            // the app died during Application bind with
            //   "Failed to create an instance of androidx.work.impl.WorkDatabase"
            // before any Dart code could run. See proguard-rules.pro.
            isMinifyEnabled = false
            isShrinkResources = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

// ---------------------------------------------------------------------------
// Escape hatch for ART baseline-profile generation.
//
// The compile*ArtProfile tasks write into
//   build/app/intermediates/dex_metadata_directory/<variant>/...
// which OneDrive intermittently locks on a synced project tree, failing with:
//   java.nio.file.AccessDeniedException: ...\compileReleaseArtProfile\0
//
// Baseline profiles only pre-warm ART for a faster cold start; skipping them
// yields a fully functional APK. This is a no-op unless explicitly requested:
//   gradlew assembleRelease -PfingerspeakSkipArtProfile=true
// ---------------------------------------------------------------------------
if (project.findProperty("fingerspeakSkipArtProfile") == "true") {
    tasks.matching { it.name.contains("ArtProfile") }.configureEach {
        enabled = false
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    implementation("androidx.concurrent:concurrent-futures:1.2.0")
    implementation("androidx.concurrent:concurrent-futures-ktx:1.2.0")
}
