import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/widgets.dart';

import 'config.dart';
import 'crash.dart';
import 'device_context.dart';
import 'identity.dart';
import 'inbox.dart';
import 'lifecycle.dart';
import 'logger.dart';
import 'messages.dart';
import 'native_bridge.dart';
import 'navigator_observer.dart';
import 'properties.dart';
import 'queue.dart';
import 'session.dart';
import 'transport.dart';

/// Dijji — Flutter SDK entry point.
///
/// ```dart
/// void main() async {
///   WidgetsFlutterBinding.ensureInitialized();
///   await Dijji.instance.initialize(siteKey: 'ws_abc123');
///   runApp(MyApp());
/// }
///
/// MaterialApp(
///   navigatorObservers: [Dijji.instance.navigatorObserver],
///   navigatorKey: Dijji.instance.navigatorKey,  // for in-app messages
///   ...
/// )
/// ```
///
/// All public methods are safe to call from any isolate event-loop context.
/// Calls before [initialize] log a warning and no-op rather than throwing —
/// the SDK should never be the reason an app crashes.
class Dijji {
  Dijji._();

  static final Dijji _instance = Dijji._();

  /// Singleton accessor. Same lifetime as the app process.
  static Dijji get instance => _instance;

  // ── Internal state ──────────────────────────────────────────────

  bool _initialized = false;
  Identity? _identity;
  Properties? _properties;
  DeviceContext? _deviceContext;
  Transport? _transport;
  Session? _session;
  EventQueue? _queue;
  CrashRecorder? _crashRecorder;
  DijjiLifecycle? _lifecycle;
  InboxPoller? _inbox;
  MessageRenderer? _messages;
  DijjiNavigatorObserver? _navigatorObserver;
  NativeBridge? _native;

  /// Provided to the host app to attach to MaterialApp / CupertinoApp.
  /// Required for in-app message rendering — without it, the SDK has no
  /// way to find the Overlay it needs to insert messages into.
  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  /// True once [initialize] has completed at least once.
  bool get isInitialized => _initialized;

  /// The persisted visitor identity. Empty string before init.
  String get visitorId => _identity?.visitorId ?? '';

  /// The user_id set via [identify], or null if anonymous.
  String? get userId => _identity?.userId;

  /// True if the user has opted out of analytics.
  bool get isOptedOut => _identity?.optedOut ?? false;

  /// The drop-in observer for `MaterialApp.navigatorObservers`. Returns a
  /// no-op observer until [initialize] completes — safe to reference at
  /// build time.
  NavigatorObserver get navigatorObserver =>
      _navigatorObserver ?? _NoopNavigatorObserver();

  // ── Initialization ──────────────────────────────────────────────

  /// Initialize the SDK. Idempotent — second call returns immediately.
  /// Must be awaited before the first [track] call so identity, persistent
  /// queue, and device context are ready.
  Future<void> initialize({
    required String siteKey,
    DijjiConfig? config,
  }) async {
    if (_initialized) {
      DijjiLog.w('initialize called twice — ignoring');
      return;
    }
    if (siteKey.isEmpty) {
      DijjiLog.w('initialize called with empty siteKey — SDK disabled');
      return;
    }

    final cfg = config ?? DijjiConfig(siteKey: siteKey);
    final effectiveConfig = cfg.siteKey == siteKey
        ? cfg
        : DijjiConfig(
            siteKey: siteKey,
            endpoint: cfg.endpoint,
            autoCaptureScreens: cfg.autoCaptureScreens,
            sessionTimeout: cfg.sessionTimeout,
            flushInterval: cfg.flushInterval,
            inboxPollInterval: cfg.inboxPollInterval,
            maxQueueSize: cfg.maxQueueSize,
            captureCrashes: cfg.captureCrashes,
            captureNativeCrashes: cfg.captureNativeCrashes,
            captureInstallReferrer: cfg.captureInstallReferrer,
            renderInAppMessages: cfg.renderInAppMessages,
            debug: cfg.debug,
          );
    DijjiLog.debugEnabled = effectiveConfig.debug;

    WidgetsFlutterBinding.ensureInitialized();

    _identity = await Identity.load();
    _properties = await Properties.load();
    _deviceContext = await DeviceContext.gather();
    _transport = Transport(effectiveConfig)
      ..setRuntimePlatform(_resolveRuntimePlatform());

    _crashRecorder = CrashRecorder(
      transport: _transport!,
      identity: _identity!,
      deviceContext: _deviceContext!,
      sessionIdProvider: () => _session?.id,
    );
    if (effectiveConfig.captureCrashes) _crashRecorder!.install();

    _queue = EventQueue(
      config: effectiveConfig,
      transport: _transport!,
      identity: _identity!,
      properties: _properties!,
      deviceContext: _deviceContext!,
      crashRecorder: _crashRecorder!,
      sessionIdProvider: () => _session?.id,
    );
    await _queue!.restore();

    _session = Session(
      effectiveConfig.sessionTimeout.inSeconds,
      (name, props) => _queue!.enqueue(name: name, properties: props),
    );

    _navigatorObserver = DijjiNavigatorObserver(
      session: _session!,
      trackScreen: (name, {properties}) {
        if (!effectiveConfig.autoCaptureScreens) return;
        _queue!.enqueue(
          name: 'screen_view',
          screen: name,
          properties: properties,
        );
      },
    );

    _inbox = InboxPoller(
      config: effectiveConfig,
      transport: _transport!,
      identity: _identity!,
    );
    if (effectiveConfig.renderInAppMessages) {
      _messages = MessageRenderer(
        navigatorKey: navigatorKey,
        onMessageEvent: (event, {properties}) {
          _queue!.enqueue(name: event, properties: properties);
        },
      );
      _messages!.attach(_inbox!.messagesStream);
    }

    _lifecycle = DijjiLifecycle(
      queue: _queue!,
      session: _session!,
      onForeground: () {
        _queue!.startPeriodicFlush();
        _inbox!.start();
      },
      onBackground: () {
        _session!.end();
        _queue!.stopPeriodicFlush();
        _inbox!.stop();
      },
    );
    _lifecycle!.start();

    // Native bridge — JVM/Objective-C uncaught exceptions + POSIX signals,
    // plus Play Install Referrer on Android. Async-init so initialize()
    // doesn't block on the platform service binding; either succeeds quietly
    // or fails quietly. The SDK works fine without these.
    _native = NativeBridge(transport: _transport!);
    if (effectiveConfig.captureNativeCrashes) {
      // ignore: discarded_futures
      _native!.install(
        siteKey: siteKey,
        visitorId: _identity!.visitorId,
        userId: _identity!.userId,
        sessionId: _session?.id,
        appId: _deviceContext!.appId,
        appVersion: _deviceContext!.appVersion,
        osVersion: _deviceContext!.osVersion,
        deviceModel: _deviceContext!.deviceModel,
      );
    }
    if (effectiveConfig.captureInstallReferrer) {
      // ignore: discarded_futures
      _native!.fetchInstallReferrerOnce(
        siteKey: siteKey,
        visitorId: _identity!.visitorId,
        appId: _deviceContext!.appId,
        appVersion: _deviceContext!.appVersion,
        osVersion: _deviceContext!.osVersion,
        deviceModel: _deviceContext!.deviceModel,
      );
    }
    _initialized = true;

    DijjiLog.d(
        'initialized site=$siteKey sdk=$dijjiSdkVariant-$dijjiSdkVersion');
  }

  // ── Public API ──────────────────────────────────────────────────

  /// Fire a custom event. Properties must be JSON-serialisable scalars,
  /// scalar lists, or one-level-nested maps. Server truncates strings at
  /// 500 chars and caps at 20 keys per properties bag.
  void track(String name, {Map<String, Object?>? properties}) {
    if (!_guard()) return;
    _session!.touch();
    _queue!.enqueue(name: name, properties: properties);
  }

  /// Manually report a screen view. Auto-capture via [navigatorObserver]
  /// covers most cases; use this when the observed name isn't right.
  void screen(String name, {Map<String, Object?>? properties}) {
    if (!_guard()) return;
    _session!.touch();
    _session!.bumpScreens();
    _queue!.enqueue(
      name: 'screen_view',
      screen: name,
      properties: properties,
    );
  }

  /// Attach a stable user identity to subsequent events. Optional traits
  /// are persisted as super-properties.
  void identify(String userId, {Map<String, Object?>? traits}) {
    if (!_guard()) return;
    if (userId.isEmpty) {
      DijjiLog.w('identify called with empty userId — ignoring');
      return;
    }
    // ignore: discarded_futures
    _identity!.setUserId(userId);
    if (traits != null && traits.isNotEmpty) {
      // ignore: discarded_futures
      _properties!.setAll(traits);
    }
    _queue!.enqueue(name: r'$identify', properties: traits);
  }

  /// Register a persistent user property attached to every future event.
  void setUserProperty(String key, Object? value) {
    if (!_guard()) return;
    // ignore: discarded_futures
    _properties!.set(key, value);
  }

  /// Bulk version of [setUserProperty].
  void setUserProperties(Map<String, Object?> values) {
    if (!_guard()) return;
    // ignore: discarded_futures
    _properties!.setAll(values);
  }

  /// Remove a previously-set user property.
  void unsetUserProperty(String key) {
    if (!_guard()) return;
    // ignore: discarded_futures
    _properties!.unset(key);
  }

  /// Register a push token (FCM on Android, APNS on iOS). The host app is
  /// responsible for obtaining the token via `firebase_messaging` or the
  /// equivalent — this just forwards it to the server.
  Future<void> registerPushToken(String token) async {
    if (!_guard()) return;
    if (token.isEmpty) return;
    await _transport!.postToken(
      token: token,
      visitorId: _identity!.visitorId,
      userId: _identity!.userId,
      appId: _deviceContext!.appId,
      appVersion: _deviceContext!.appVersion,
    );
  }

  /// Record a push interaction event (push_received, push_opened). Called
  /// by the host app from its Firebase / APNS callbacks. Stamps push_id
  /// and trigger_id when supplied so the dashboard's open-rate KPIs work.
  void trackPushEvent(
    String event, {
    String? pushId,
    String? triggerId,
    Map<String, Object?>? extra,
  }) {
    if (!_guard()) return;
    final props = <String, Object?>{
      if (pushId != null) 'push_id': pushId,
      if (triggerId != null) 'trigger_id': triggerId,
      if (extra != null) ...extra,
    };
    track(event, properties: props.isEmpty ? null : props);
  }

  /// Stop collecting. Persists across launches. Drops the in-memory queue.
  Future<void> optOut() async {
    if (!_guard()) return;
    await _identity!.setOptedOut(true);
    await _queue!.flush(); // sends nothing, but clears persistent storage
  }

  /// Resume collection. Visitor identity is preserved.
  Future<void> optIn() async {
    if (!_guard()) return;
    await _identity!.setOptedOut(false);
  }

  /// Logout. Flushes the queue with the OLD visitor_id, then rotates.
  Future<void> reset() async {
    if (!_guard()) return;
    await _queue!.flush();
    await _identity!.reset();
    await _properties!.clear();
  }

  /// Force the queue to flush now. Returns once the network call settles.
  Future<void> flush() async {
    if (!_guard()) return;
    await _queue!.flush();
  }

  /// Run [body] inside a guarded zone that forwards uncaught Dart errors
  /// to the crash endpoint. Use as the entry point in main():
  ///
  /// ```dart
  /// void main() => Dijji.instance.runGuarded(() {
  ///   WidgetsFlutterBinding.ensureInitialized();
  ///   runApp(MyApp());
  /// });
  /// ```
  T? runGuarded<T>(T Function() body) {
    if (_crashRecorder == null) {
      // Pre-init guard — at least preserve the body's side-effects.
      return body();
    }
    return _crashRecorder!.runGuarded(body);
  }

  // ── Internals ───────────────────────────────────────────────────

  bool _guard() {
    if (!_initialized) {
      DijjiLog.w('SDK call before initialize() — ignoring');
      return false;
    }
    return true;
  }

  String _resolveRuntimePlatform() {
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    if (Platform.isMacOS) return 'macos';
    // The server filters mobile data on platform IN ('android','ios') so
    // anything else still reaches /t/app/collect but won't show under
    // mobile-specific dashboards. Reasonable default for desktop preview.
    return 'android';
  }
}

class _NoopNavigatorObserver extends NavigatorObserver {}
