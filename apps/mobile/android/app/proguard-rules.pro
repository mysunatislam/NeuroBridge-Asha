# ---------------------------------------------------------------------------
# FingerSpeak Asha - Android R8 / ProGuard keep rules
#
# WHY THIS FILE EXISTS
# --------------------
# A minified release build crashed at process start, before any Dart code ran:
#
#   FATAL EXCEPTION: main
#   java.lang.RuntimeException: Unable to get provider
#     androidx.startup.InitializationProvider:
#   java.lang.RuntimeException: Failed to create an instance of
#     androidx.work.impl.WorkDatabase
#       at androidx.work.WorkManagerInitializer.create(...)
#
# R8's own usage.txt reported that it had removed:
#
#   androidx.work.impl.WorkDatabase_Impl:
#       public void <init>()
#       public void clearAllTables()
#       protected androidx.room.InvalidationTracker createInvalidationTracker()
#
# Room resolves its generated implementation class by NAME at runtime --
#   Class.forName("...WorkDatabase_Impl").getDeclaredConstructor().newInstance()
# -- so nothing in the bytecode ever references that constructor and R8 is free
# to delete it. newInstance() then throws InstantiationException, which Room
# rethrows as "Failed to create an instance of <database>".
#
# WorkManager auto-initialises through androidx.startup's ContentProvider, which
# Android installs during Application bind -- so this kills the process on
# launch, with no chance for any Dart-side try/catch to intervene.
#
# Every rule below protects a class that is reached reflectively, by name, or
# from the merged manifest, and is therefore invisible to R8's reachability
# analysis.
# ---------------------------------------------------------------------------

# --- Attributes needed for reflection, generics and annotations ------------
-keepattributes Signature
-keepattributes *Annotation*
-keepattributes InnerClasses
-keepattributes EnclosingMethod

# --- Room -------------------------------------------------------------------
# The rule that fixes the crash above: keep every RoomDatabase subclass and
# every generated *_Impl together with its no-argument constructor.
-keep class * extends androidx.room.RoomDatabase { <init>(); }
-keep class **_Impl { <init>(); }
-keep class androidx.room.** { *; }
-keep @androidx.room.Database class * { *; }
-keep @androidx.room.Entity class * { *; }
-keep @androidx.room.Dao class * { *; }
-dontwarn androidx.room.paging.**

# --- WorkManager ------------------------------------------------------------
-keep class androidx.work.** { *; }
-keep class * extends androidx.work.Worker { <init>(...); }
-keep class * extends androidx.work.ListenableWorker { <init>(...); }
-keep class * extends androidx.work.InputMerger { <init>(...); }
-dontwarn androidx.work.**

# --- androidx.startup -------------------------------------------------------
# Initializers are named in the merged manifest and constructed reflectively.
-keep class androidx.startup.** { *; }
-keep class * implements androidx.startup.Initializer { <init>(); }

# --- SQLite backing store ---------------------------------------------------
-keep class androidx.sqlite.** { *; }
-dontwarn androidx.sqlite.**

# --- Flutter engine, embedding and generated plugin registrant -------------
-keep class io.flutter.** { *; }
-keep class io.flutter.embedding.** { *; }
-keep class io.flutter.plugins.** { *; }
-dontwarn io.flutter.embedding.**

# --- Google ML Kit (face + pose detection) ---------------------------------
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_** { *; }
-dontwarn com.google.mlkit.**
-dontwarn com.google.android.gms.**

# --- flutter_local_notifications (serialises schedules through Gson) -------
-keep class com.dexterous.** { *; }
-keep class * extends com.google.gson.TypeAdapter
-keep class * implements com.google.gson.TypeAdapterFactory
-keep class * implements com.google.gson.JsonSerializer
-keep class * implements com.google.gson.JsonDeserializer
-keepclassmembers,allowobfuscation class * {
    @com.google.gson.annotations.SerializedName <fields>;
}
-dontwarn com.google.gson.**

# --- CameraX (camera_android_camerax) --------------------------------------
-keep class androidx.camera.** { *; }
-dontwarn androidx.camera.**

# --- WebView JS bridges (webview_flutter, flutter_inappwebview) ------------
-keepattributes JavascriptInterface
-keepclassmembers class * {
    @android.webkit.JavascriptInterface <methods>;
}

# --- Kotlin -----------------------------------------------------------------
-keep class kotlin.Metadata { *; }
-dontwarn kotlinx.coroutines.**

# --- App entry point (named in AndroidManifest.xml) ------------------------
-keep class org.fingerspeak.mobile.MainActivity { *; }
