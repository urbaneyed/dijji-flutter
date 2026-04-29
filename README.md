# Dijji Flutter SDK

Analytics, engagement, and in-app messaging for Flutter apps. Two-line install.
Full parity with the [Android](https://github.com/urbaneyed/dijji-android) and
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

## Crash capture (Dart)

Dart errors are captured automatically once the SDK is initialized. For full
coverage of uncaught async errors, wrap your `main` body:

```dart
void main() {
  Dijji.instance.runGuarded(() {
    WidgetsFlutterBinding.ensureInitialized();
    runApp(const MyApp());
  });
}
```

> **Native crashes** (SIGSEGV, NSException) are not yet caught by this SDK.
> Use `firebase_crashlytics` alongside Dijji if you need them — they share
> nicely. v1.1 will add platform-channel hooks for native capture.

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

- v1.1: Play Install Referrer (Android-side platform channel), native SIGSEGV
  capture, opt-in IDFV/AAID for ad-attribution use cases.
- v1.2: Pigeon-bridged shortcut to the native SDK so customers who already
  ship `dijji-android` / `dijji-ios` can avoid duplicate event streams.

## License

Apache 2.0. See [LICENSE](LICENSE).
