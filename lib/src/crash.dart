import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import 'device_context.dart';
import 'identity.dart';
import 'logger.dart';
import 'transport.dart';

/// Captures Dart-side errors and forwards them to /t/app/crash.
///
/// Three sources are intercepted:
///   1. `FlutterError.onError` — synchronous framework errors (build, layout,
///      paint failures). The previous handler is preserved and called after.
///   2. `PlatformDispatcher.instance.onError` — uncaught async Dart errors
///      that escape every zone. Returns true so the error is swallowed —
///      the alternative is process termination, and the app's existing
///      handler had its turn first.
///   3. [runGuarded] — caller-supplied entrypoint via `runZonedGuarded`. The
///      host app calls `Dijji.runGuarded(() => runApp(...))` for completeness.
///
/// Native SIGSEGV-class crashes are NOT caught — those need a platform-channel
/// hook into PLCrashReporter / NDK signals which v1.1 will add.
class CrashRecorder {
  CrashRecorder({
    required Transport transport,
    required Identity identity,
    required DeviceContext deviceContext,
    required String? Function() sessionIdProvider,
  })  : _transport = transport,
        _identity = identity,
        _deviceContext = deviceContext,
        _sessionIdProvider = sessionIdProvider;

  static const int _maxBreadcrumbs = 50;

  final Transport _transport;
  final Identity _identity;
  final DeviceContext _deviceContext;
  final String? Function() _sessionIdProvider;

  final Queue<Map<String, Object?>> _breadcrumbs =
      Queue<Map<String, Object?>>();
  FlutterExceptionHandler? _previousFlutterHandler;
  bool _installed = false;

  void install() {
    if (_installed) return;
    _installed = true;

    _previousFlutterHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      _capture(
        type: details.exception.runtimeType.toString(),
        reason: details.exceptionAsString(),
        stack: details.stack ?? StackTrace.current,
      );
      // Keep the host app's handler in the chain.
      _previousFlutterHandler?.call(details);
    };

    // Any Dart error not caught by a zone makes it here. Returning true tells
    // the engine "we handled it" — without this, debug builds keep the
    // existing crash logging, so we don't add a second red screen.
    PlatformDispatcher.instance.onError = (error, stack) {
      _capture(
        type: error.runtimeType.toString(),
        reason: error.toString(),
        stack: stack,
      );
      return true;
    };
  }

  /// Wrap [body] in a guarded zone that forwards any uncaught error to the
  /// crash endpoint. Call from main(): `Dijji.runGuarded(() => runApp(MyApp()))`.
  T? runGuarded<T>(T Function() body) {
    return runZonedGuarded<T>(body, (error, stack) {
      _capture(
        type: error.runtimeType.toString(),
        reason: error.toString(),
        stack: stack,
      );
    });
  }

  void addBreadcrumb(
      String eventName, Map<String, Object?>? props, String? screen) {
    _breadcrumbs.add({
      'ts': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      'event_name': eventName,
      'screen': screen,
      'data': (props == null || props.isEmpty) ? null : props,
    });
    while (_breadcrumbs.length > _maxBreadcrumbs) {
      _breadcrumbs.removeFirst();
    }
  }

  List<Map<String, Object?>> snapshot() => List.unmodifiable(_breadcrumbs);

  Future<void> _capture({
    required String type,
    required String reason,
    required StackTrace stack,
  }) async {
    if (_identity.optedOut) return;
    try {
      final ctx = await _deviceContext.snapshot();
      await _transport.postCrash(
        visitorId: _identity.visitorId,
        userId: _identity.userId,
        sessionId: _sessionIdProvider(),
        appId: _deviceContext.appId,
        appVersion: _deviceContext.appVersion,
        osVersion: _deviceContext.osVersion,
        deviceModel: _deviceContext.deviceModel,
        crashType: type,
        reason: reason.length > 500 ? reason.substring(0, 500) : reason,
        stackTrace: _truncate(stack.toString(), 60000),
        breadcrumbs: snapshot(),
        state: <String, Object?>{
          'thread': 'main',
          'memory_free_mb': ctx['memory_free_mb'],
          'memory_total_mb': ctx['memory_total_mb'],
          'disk_free_mb': ctx['disk_free_mb'],
          'battery_level': ctx['battery_level'],
          'charging': ctx['battery_charging'],
          'network': ctx['network_type'],
          'orientation': ctx['orientation'],
        },
      );
    } catch (e) {
      DijjiLog.e('crash post failed: $e');
    }
  }

  static String _truncate(String s, int max) =>
      s.length > max ? s.substring(0, max) : s;
}
