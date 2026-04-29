# Dijji Flutter SDK

[![pub package](https://img.shields.io/pub/v/dijji.svg)](https://pub.dev/packages/dijji)
[![CI](https://github.com/urbaneyed/dijji-flutter/actions/workflows/ci.yml/badge.svg)](https://github.com/urbaneyed/dijji-flutter/actions/workflows/ci.yml)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![Flutter](https://img.shields.io/badge/Flutter-%E2%89%A53.10-02569B?logo=flutter)](https://flutter.dev)

**Intelligence · Engagement · Defense — for Flutter.**
The Dijji SDK replaces your analytics, crash reporter, push tooling, and
in-app messaging stack with one dependency. Two-line install. Full parity
with the [Android](https://github.com/urbaneyed/dijji-android) and
[iOS](https://github.com/urbaneyed/dijji-ios) SDKs — same data model, same
dashboard, same backend.

## Install

```yaml
# pubspec.yaml
dependencies:
  dijji: ^1.0.0-alpha
```

```dart
// main.dart
import 'package:dijji/dijji.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Dijji.instance.initialize(siteKey: 'ws_abc123');
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: Dijji.instance.navigatorKey,
      navigatorObservers: [Dijji.instance.navigatorObserver],
      home: const HomeScreen(),
    );
  }
}
```

That's the whole integration. Auto-capture is on by default.

## What ships out of the box

- `app_open` / `app_foreground` / `app_background`
- `session_start` / `session_end` (30-min idle timeout, configurable)
- `screen_view` (via the bundled `NavigatorObserver`)
- `app_install` (first launch)
- `app_crash` for any uncaught Dart error (caught via `FlutterError.onError`,
  `PlatformDispatcher.onError`, and an optional `runGuarded` zone)
- Device + OS + locale + battery + network + display context on every batch
- Persistent visitor identity across launches, even after process kill
- Offline event queue with re-flush on reconnect

## Custom events + identity

```dart
Dijji.instance.track('signup_completed', properties: {'plan': 'pro'});
Dijji.instance.identify('user_42', traits: {'plan': 'pro'});
Dijji.instance.setUserProperty('role', 'admin');
Dijji.instance.screen('Pricing');     // manual override; auto-capture covers most cases
Dijji.instance.optOut();              // privacy kill
Dijji.instance.reset();               // logout — flushes, then rotates visitor_id
```

## In-app messages

`banner`, `bottom_sheet`, and `modal` cards composed in the Dijji dashboard
render automatically via Flutter's overlay. Required wiring:

```dart
MaterialApp(
  navigatorKey: Dijji.instance.navigatorKey,   // mandatory for messages
  navigatorObservers: [Dijji.instance.navigatorObserver],
  ...
)
```

If you want to handle messages yourself, set `renderInAppMessages: false` in
[`DijjiConfig`] and consume the stream through your own widgets.

## Push notifications

You bring the FCM / APNS plugin (we recommend `firebase_messaging`); the SDK
just registers the token:

```dart
final token = await FirebaseMessaging.instance.getToken();
if (token != null) {
  await Dijji.instance.registerPushToken(token);
}

FirebaseMessaging.onMessage.listen((msg) {
  Dijji.instance.trackPushEvent('push_received',
    pushId: msg.data['dijji_push_id']);
});
```

## Crash capture

**Dart errors** are captured automatically once the SDK is initialized
(`FlutterError.onError`, `PlatformDispatcher.onError`). For maximum coverage
of uncaught async errors, wrap your `main` body:

```dart
void main() {
  Dijji.instance.runGuarded(() {
    WidgetsFlutterBinding.ensureInitialized();
    runApp(const MyApp());
  });
}
```

**Native crashes** are caught by the v1.1 plugin layer:

- **Android** — chained `Thread.setDefaultUncaughtExceptionHandler` (Kotlin /
  Java uncaught exceptions, `OutOfMemoryError`, etc.).
- **iOS** — `NSSetUncaughtExceptionHandler` plus POSIX signal handlers for
  the pure-Swift crashes that NSException misses (`fatalError`, forced unwrap
  of nil, array OOB). Marker-on-disk + next-launch forward, exactly the
  pattern Sentry / Crashlytics / Bugsnag use.

To opt out: `DijjiConfig(captureNativeCrashes: false)`. Useful only when you
already ship a competing native reporter that conflicts with chained
handlers.

## Configuration

```dart
await Dijji.instance.initialize(
  siteKey: 'ws_abc123',
  config: const DijjiConfig(
    siteKey: 'ws_abc123',
    endpoint: 'https://dijji.com',           // override for staging
    autoCaptureScreens: true,
    sessionTimeout: Duration(minutes: 30),
    flushInterval: Duration(seconds: 30),
    inboxPollInterval: Duration(seconds: 30),
    maxQueueSize: 500,                       // 50–5000
    captureCrashes: true,
    captureNativeCrashes: true,
    captureInstallReferrer: true,
    renderInAppMessages: true,
    debug: false,
  ),
);
```

## Privacy

- No cookies. No PII collected by the SDK itself.
- Visitor identity is a random UUID generated locally, persisted in
  SharedPreferences (Android) / NSUserDefaults (iOS).
- IP arrives at the server, never persists past geo resolution.
- `optOut()` is honoured locally and on the server; the in-memory queue is
  dropped on opt-out.

## Roadmap

- v1.1 (this release): Native crash capture on both platforms (NSException +
  POSIX signals + JVM uncaught), Play Install Referrer.
- v1.2: `dijji_firebase` companion package — one-line FCM/APNs token + push
  handling helpers around `firebase_messaging`.
- v1.3: Background isolate flushing, sqflite-backed durable queue, opt-in
  IDFV/AAID for ad-attribution.

## License

Apache 2.0. See [LICENSE](LICENSE).
