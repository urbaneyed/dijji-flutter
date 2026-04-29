# Changelog

## 1.1.2-alpha · 2026-04-30

Fixes the in-app banner renderer: `MessageRenderer._showBanner` was calling
`Overlay.of(ctx, rootOverlay: true)` from the overlay's own context, which
fires an assertion in Flutter 3.16+ — the throw was silently swallowed by
`_drain`'s try/catch, so banners never rendered while modals (which use
`showDialog`) worked fine. Now reaches the overlay state directly via the
navigator key. Surfaced on the byde app on 2026-04-30; no other behaviour
change.

## 1.1.1-alpha · 2026-04-29

Brand-positioning patch — pub.dev description and README headline updated
to lead with the Dijji pillar framing ("Intelligence · Engagement · Defense")
rather than the generic "analytics" category. No code changes; existing
1.1.0-alpha consumers see no behaviour difference.

## 1.1.0-alpha · 2026-04-29

The "close the gaps" release. Package is now a Flutter plugin (with Android +
iOS scaffolding). Two-line install for users is unchanged.

### Added
- **Native crash capture (Android)** — installs a chained
  `Thread.setDefaultUncaughtExceptionHandler` that forwards JVM/Kotlin crashes
  (e.g. `kotlin.OutOfMemoryError`, `java.lang.NullPointerException`) to
  `/t/app/crash` before terminating. Plugged into the existing crash
  dashboard.
- **Native crash capture (iOS)** — installs both `NSSetUncaughtExceptionHandler`
  and POSIX signal handlers (SIGABRT, SIGILL, SIGSEGV, SIGFPE, SIGBUS,
  SIGTRAP). Catches the pure-Swift crashes Dart can't see (`fatalError`,
  forced unwrap of nil, array OOB). Marker-on-disk pattern — write inside
  the signal handler (async-signal-safe APIs only), forward on next launch.
- **Play Install Referrer (Android)** — fetches once per install and posts
  to `/t/app/install` for UTM-stamped install attribution. Idempotent via
  `SharedPreferences` flag.
- `DijjiConfig.captureNativeCrashes` (default `true`) and
  `DijjiConfig.captureInstallReferrer` (default `true`) for opt-out.

### Changed
- Package converted from pure-Dart library to Flutter plugin. Customers
  upgrading from 1.0.0-alpha get the new native code automatically; no
  pubspec changes beyond the version bump.

### Removed (caveats from 1.0.0-alpha CHANGELOG)
- ~~"Native crashes punted to v1.1"~~ — done in this release.
- ~~"Play Install Referrer punted to v1.1"~~ — done in this release.

### Known gaps
- Carrier on iOS still null (Apple removed the API in iOS 16; will not be
  added).
- Symbolicated stack traces still server-side-only; raw addresses for now.

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
