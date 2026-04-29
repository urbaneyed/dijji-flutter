# Changelog

## 1.0.0-alpha · 2026-04-29

Initial alpha. Pure-Dart implementation, full ingestion-protocol parity with the
Android and iOS SDKs.

- `Dijji.initialize(siteKey:)` — two-line install
- `track`, `identify`, `screen`, `setUserProperty(s)`, `unsetUserProperty`,
  `optIn`, `optOut`, `reset`, `flush`, `registerPushToken`, `trackPushEvent`,
  `runGuarded`
- Auto-captured events: `app_open`, `app_foreground`, `app_background`,
  `session_start`, `session_end`, `screen_view`, `app_crash`
- Dart-side crash capture (`FlutterError.onError`, `PlatformDispatcher.onError`,
  `runZonedGuarded`)
- Persistent event queue across app restarts (SharedPreferences-backed)
- Device context: OS, model, locale, network, battery, display, dark mode,
  orientation, font scale, timezone, days_since_install, session_sequence
- In-app message renderer for `banner`, `bottom_sheet`, and `modal`
- Inbox polling at 30 s (configurable)

Known gaps:
- Native crash capture (SIGSEGV, NSException) — v1.1
- Play Install Referrer attribution — v1.1
- Carrier on iOS unavailable (Apple removed the API in iOS 16)
