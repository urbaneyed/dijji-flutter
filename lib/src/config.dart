/// Runtime configuration for the Dijji SDK.
///
/// Defaults are tuned to match the Android and iOS SDKs so behaviour is
/// identical across platforms. Most apps construct this with just a site key
/// and never touch the rest.
class DijjiConfig {
  /// Opaque site key from your Dijji dashboard, e.g. `ws_abc123`.
  final String siteKey;

  /// Ingest host. Override for staging or self-hosted.
  final String endpoint;

  /// Auto-capture screen views via [DijjiNavigatorObserver]. The observer
  /// only fires events when this is true; the host app still has to wire
  /// the observer into MaterialApp / CupertinoApp.
  final bool autoCaptureScreens;

  /// Idle window that ends a session. Default 30 min, industry norm.
  final Duration sessionTimeout;

  /// How often the in-memory queue flushes while foreground.
  final Duration flushInterval;

  /// How often we poll /t/app/inbox for admin-triggered in-app messages.
  final Duration inboxPollInterval;

  /// Offline cap. Once the queue reaches this size oldest events drop.
  /// Coerced into [50, 5000] at construction.
  final int maxQueueSize;

  /// Install Dart-error capture. Calls
  /// `FlutterError.onError` and `PlatformDispatcher.onError` interceptors;
  /// existing handlers are chained, never swallowed.
  final bool captureCrashes;

  /// Install the native crash handlers (NSException + POSIX signals on iOS,
  /// `Thread.setDefaultUncaughtExceptionHandler` on Android). Catches the
  /// pure-native crashes Dart can't see — `fatalError` / forced unwrap of
  /// nil / `kotlin.OutOfMemoryError`. Defaults to true; turn off only if
  /// you already ship `firebase_crashlytics` or another native reporter
  /// that conflicts with the chained handlers.
  final bool captureNativeCrashes;

  /// Fetch the Play Install Referrer once per install (Android only). The
  /// payload is forwarded to /t/app/install for UTM-stamped install
  /// attribution. No-op on iOS — Apple has no equivalent API.
  final bool captureInstallReferrer;

  /// Render in-app banner / bottom_sheet / modal cards from the inbox.
  /// Disable if you want to claim and render messages yourself.
  final bool renderInAppMessages;

  /// Verbose log output via dart:developer / print.
  final bool debug;

  const DijjiConfig({
    required this.siteKey,
    this.endpoint = 'https://dijji.com',
    this.autoCaptureScreens = true,
    this.sessionTimeout = const Duration(minutes: 30),
    this.flushInterval = const Duration(seconds: 30),
    this.inboxPollInterval = const Duration(seconds: 30),
    this.maxQueueSize = 500,
    this.captureCrashes = true,
    this.captureNativeCrashes = true,
    this.captureInstallReferrer = true,
    this.renderInAppMessages = true,
    this.debug = false,
  });

  /// Clamps [maxQueueSize] into [50, 5000] so the SDK can't be misconfigured
  /// into either dropping every flush or eating unbounded memory.
  int get clampedMaxQueueSize {
    if (maxQueueSize < 50) return 50;
    if (maxQueueSize > 5000) return 5000;
    return maxQueueSize;
  }

  String get sanitizedEndpoint => endpoint.endsWith('/')
      ? endpoint.substring(0, endpoint.length - 1)
      : endpoint;
}

const String dijjiSdkVersion = '1.1.0-alpha';
const String dijjiSdkVariant = 'flutter';
