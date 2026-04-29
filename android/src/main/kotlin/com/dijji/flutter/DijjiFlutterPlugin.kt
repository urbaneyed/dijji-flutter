package com.dijji.flutter

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.android.installreferrer.api.InstallReferrerClient
import com.android.installreferrer.api.InstallReferrerStateListener
import com.android.installreferrer.api.ReferrerDetails
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.PrintWriter
import java.io.StringWriter

/**
 * The Android side of `package:dijji`. Two responsibilities:
 *
 * 1. **Native crash capture** — install a `Thread.setDefaultUncaughtExceptionHandler`
 *    that pushes the crash up to Dart via a method channel, then chains to the
 *    previously-installed handler so the JVM still tears the process down.
 *
 * 2. **Play Install Referrer** — bind to the Google Play `installreferrer`
 *    service on demand, fetch the referrer URL + click/install timestamps, and
 *    return them to Dart for forwarding to /t/app/install. Idempotent — Dart
 *    persists the "already fetched" flag so we don't burn quota on every cold start.
 *
 * Method-channel contract:
 *   "installCrashHandler"        (no args)         → null. Synchronous.
 *   "fetchInstallReferrer"       (no args)         → Map { referrer, click_ts, install_ts }.
 *                                                     Async (binds to Play service).
 */
class DijjiFlutterPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private lateinit var channel: MethodChannel
    private lateinit var appContext: Context
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "dijji/native")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "installCrashHandler" -> {
                installCrashHandler()
                result.success(null)
            }
            "fetchInstallReferrer" -> fetchInstallReferrer(result)
            else -> result.notImplemented()
        }
    }

    // ── Crash handler ──────────────────────────────────────────────

    private var previousHandler: Thread.UncaughtExceptionHandler? = null
    private var crashHandlerInstalled = false

    private fun installCrashHandler() {
        if (crashHandlerInstalled) return
        crashHandlerInstalled = true
        previousHandler = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            try {
                val sw = StringWriter()
                throwable.printStackTrace(PrintWriter(sw))
                val payload = mapOf<String, Any?>(
                    "type" to (throwable.javaClass.name ?: "java.lang.Throwable"),
                    "reason" to throwable.message,
                    "stack" to sw.toString(),
                    "thread" to thread.name,
                    "platform" to "android",
                )
                // The MethodChannel.invokeMethod call must happen on the main
                // thread. We're on whatever thread crashed — typically main,
                // sometimes a worker. Marshal to main and block briefly so the
                // Dart-side write can land before the JVM tears us down.
                if (Looper.myLooper() == Looper.getMainLooper()) {
                    channel.invokeMethod("nativeCrash", payload)
                } else {
                    mainHandler.post { channel.invokeMethod("nativeCrash", payload) }
                    // Tiny grace window so the cross-thread invokeMethod can
                    // schedule onto the platform queue before the OS reaps us.
                    Thread.sleep(150)
                }
            } catch (_: Throwable) {
                // Never throw out of a crash handler — masks the original.
            }
            // Chain to the original handler so the JVM still terminates the app
            // (matching what every native crash reporter does).
            previousHandler?.uncaughtException(thread, throwable)
        }
    }

    // ── Install Referrer ───────────────────────────────────────────

    private fun fetchInstallReferrer(result: MethodChannel.Result) {
        val client = InstallReferrerClient.newBuilder(appContext).build()
        // Track whether we've already replied — InstallReferrerStateListener can
        // fire onInstallReferrerSetupFinished more than once on flaky service
        // reconnects, and MethodChannel.Result doesn't tolerate double-reply.
        var replied = false
        client.startConnection(object : InstallReferrerStateListener {
            override fun onInstallReferrerSetupFinished(responseCode: Int) {
                if (replied) return
                replied = true
                try {
                    when (responseCode) {
                        InstallReferrerClient.InstallReferrerResponse.OK -> {
                            val details: ReferrerDetails = client.installReferrer
                            result.success(mapOf<String, Any?>(
                                "referrer" to details.installReferrer,
                                "click_ts" to details.referrerClickTimestampSeconds,
                                "install_ts" to details.installBeginTimestampSeconds,
                                "google_play" to details.googlePlayInstantParam,
                            ))
                        }
                        InstallReferrerClient.InstallReferrerResponse.FEATURE_NOT_SUPPORTED -> {
                            result.success(null) // Older Play Store, treat as no-data.
                        }
                        InstallReferrerClient.InstallReferrerResponse.SERVICE_UNAVAILABLE -> {
                            result.success(null) // Will retry on next launch via Dart.
                        }
                        else -> {
                            result.success(null)
                        }
                    }
                } catch (e: Throwable) {
                    result.error("REFERRER_ERROR", e.message, null)
                } finally {
                    try { client.endConnection() } catch (_: Throwable) {}
                }
            }
            override fun onInstallReferrerServiceDisconnected() {
                // Client will retry connection automatically; we just wait for
                // the next setup-finished call. If it never lands, Dart polling
                // logic re-runs on next cold-start.
            }
        })
    }
}
