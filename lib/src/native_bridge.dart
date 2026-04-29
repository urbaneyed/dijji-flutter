import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'logger.dart';
import 'transport.dart';

/// Dart end of the `dijji/native` MethodChannel. Bridges:
///
///   • Native crash capture — installs JVM `Thread.setDefaultUncaughtExceptionHandler`
///     (Android) and `NSSetUncaughtExceptionHandler` + signal handlers (iOS).
///     Markers are written from inside the crash handler and forwarded
///     after the next process launch.
///   • Play Install Referrer (Android) — fetches once per install and
///     persists a flag so we never re-fetch.
///
/// All entry points fail-safe: any exception bubbles out as a no-op; the SDK
/// must never be the reason an app crashes.
class NativeBridge {
  NativeBridge({required this.transport});

  static const MethodChannel _channel = MethodChannel('dijji/native');
  static const String _kReferrerSent = 'dijji.referrer_sent';

  final Transport transport;

  /// Installs the native crash handlers AND drains any crash marker written
  /// during the previous run. Marker forwarding happens via [onPendingCrash].
  Future<void> install({
    required String siteKey,
    required String visitorId,
    String? userId,
    String? sessionId,
    String? appId,
    String? appVersion,
    String? osVersion,
    String? deviceModel,
  }) async {
    if (!_isSupported) return;
    try {
      await _channel.invokeMethod<void>('installCrashHandler');
    } catch (e) {
      DijjiLog.d('installCrashHandler failed: $e');
    }

    // iOS path: drain the file marker written by the previous-run crash.
    // Android path: in-process forwarding via the Kotlin plugin's
    // `nativeCrash` callback (registered below).
    if (Platform.isIOS) {
      await _drainPendingIosCrash(
        siteKey: siteKey,
        visitorId: visitorId,
        userId: userId,
        sessionId: sessionId,
        appId: appId,
        appVersion: appVersion,
        osVersion: osVersion,
        deviceModel: deviceModel,
      );
    }

    // Android: register a callback that fires when the JVM uncaught handler
    // marshals a crash up to Dart. This happens at process-death moment, so
    // the post is best-effort with a tight timeout.
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'nativeCrash') {
        final m = (call.arguments is Map)
            ? Map<String, Object?>.from(call.arguments as Map)
            : <String, Object?>{};
        await _forwardCrashToServer(
          siteKey: siteKey,
          visitorId: visitorId,
          userId: userId,
          sessionId: sessionId,
          appId: appId,
          appVersion: appVersion,
          osVersion: osVersion,
          deviceModel: deviceModel,
          crashType: (m['type'] as String?) ?? 'java.lang.Throwable',
          reason: m['reason'] as String?,
          stack: (m['stack'] as String?) ?? '',
        );
      }
      return null;
    });
  }

  /// Fetch + forward Play Install Referrer once per install. Idempotent —
  /// uses [SharedPreferences] to remember success.
  Future<void> fetchInstallReferrerOnce({
    required String siteKey,
    required String visitorId,
    String? appId,
    String? appVersion,
    String? osVersion,
    String? deviceModel,
  }) async {
    if (!Platform.isAndroid) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_kReferrerSent) == true) return;

      final raw = await _channel
          .invokeMethod<Map<Object?, Object?>>('fetchInstallReferrer');
      if (raw == null) {
        // Service unavailable / feature unsupported. Don't mark as sent —
        // we'll retry on next launch.
        return;
      }
      final referrer = raw['referrer'] as String? ?? '';
      if (referrer.isEmpty) {
        await prefs.setBool(_kReferrerSent, true); // empty referrer is final.
        return;
      }

      final ok = await transport.postInstall(
        siteKey: siteKey,
        visitorId: visitorId,
        installReferrer: referrer,
        clickTs: (raw['click_ts'] as num?)?.toInt(),
        installTs: (raw['install_ts'] as num?)?.toInt(),
        appId: appId,
        appVersion: appVersion,
        osVersion: osVersion,
        deviceModel: deviceModel,
      );
      if (ok) await prefs.setBool(_kReferrerSent, true);
    } catch (e) {
      DijjiLog.d('install-referrer fetch failed: $e');
    }
  }

  Future<void> _drainPendingIosCrash({
    required String siteKey,
    required String visitorId,
    String? userId,
    String? sessionId,
    String? appId,
    String? appVersion,
    String? osVersion,
    String? deviceModel,
  }) async {
    try {
      final raw = await _channel
          .invokeMethod<Map<Object?, Object?>>('drainPendingCrash');
      if (raw == null) return;
      final m = Map<String, Object?>.from(raw);
      // Build crash_type that's clearly disambiguatable on the server.
      // NSException → "<exception name>" e.g. "NSInvalidArgumentException"
      // signal → "SIGSEGV (signal 11)"
      final kind = m['kind'] as String? ?? 'unknown';
      final crashType = kind == 'nsexception'
          ? (m['type'] as String? ?? 'NSException')
          : (m['name'] as String? ??
              'SIG${(m['signal'] as num?)?.toInt() ?? 0}');
      final reason = m['reason'] as String?;
      final stack = (m['stack'] as String?) ?? '';
      await _forwardCrashToServer(
        siteKey: siteKey,
        visitorId: visitorId,
        userId: userId,
        sessionId: sessionId,
        appId: appId,
        appVersion: appVersion,
        osVersion: osVersion,
        deviceModel: deviceModel,
        crashType: crashType,
        reason: reason,
        stack: stack,
      );
    } catch (e) {
      DijjiLog.d('iOS crash drain failed: $e');
    }
  }

  Future<void> _forwardCrashToServer({
    required String siteKey,
    required String visitorId,
    String? userId,
    String? sessionId,
    String? appId,
    String? appVersion,
    String? osVersion,
    String? deviceModel,
    required String crashType,
    String? reason,
    required String stack,
  }) async {
    try {
      await transport.postCrash(
        visitorId: visitorId,
        userId: userId,
        sessionId: sessionId,
        appId: appId,
        appVersion: appVersion,
        osVersion: osVersion,
        deviceModel: deviceModel,
        crashType: crashType,
        reason: reason,
        stackTrace: stack,
      );
    } catch (e) {
      DijjiLog.d('native crash forward failed: $e');
    }
  }

  bool get _isSupported => Platform.isAndroid || Platform.isIOS;
}
