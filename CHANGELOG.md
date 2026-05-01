# Changelog

## 1.1.5-alpha · 2026-05-01

### Added
- **`in_app_survey`** — multi-step bottom sheet for the new Surveys pillar.
  Supports 5 question types: rating (3/5/7/10-point), single-choice (radio),
  multi-choice (checkbox), free text, yes/no. Multi-step navigation with
  per-step progress bar, back/next, required-field gating. Posts answers
  to `/t/survey` (start → answer × N → complete), with a `SurveyPostCallback`
  injected from the host SDK so `MessageRenderer` stays free of HTTP.
- End-screen variants: `thanks` (auto-dismiss after 2.5s), `cta`
  (button stays open), `share`, `nothing`.
- `Transport.postSurvey(body)` JSON helper added — same wire format as
  `/t/survey` accepts on the server (now JSON-aware in addition to form).

### Wire format
- Server payload from `/t/app/inbox` is shape:
  `{ kind: 'in_app_survey', config: { survey_id, name, questions[], end_screen{} } }`.
- Client posts `{ action: 'start' | 'answer' | 'complete', site, survey_id?,
  response_id?, question_id?, question_type?, value?, visitor_id? }`.

## 1.1.4-alpha · 2026-04-30

Three new in-app survey/urgency formats — bringing the Flutter SDK to parity
with the web tracker on collection-style and urgency-style messages.

### Added
- **`in_app_nps`** — 0–10 score sheet with low/high labels under a colour-graded
  number row (red 0–6, amber 7–8, green 9–10). Tap a number, sheet flashes a
  thank-you and auto-closes after 1.4 s. Fires `__dijji_nps_submitted` with
  `score` (int 0–10).
- **`in_app_reactions`** — emoji feedback bar. Accepts a `emojis` array (2–5
  recommended, defaults to `['😍','🙂','😐','😕']` if none supplied), shows the
  picked emoji at 56 px after submission with a thank-you line. Fires
  `__dijji_reaction_submitted` with `reaction` (the emoji string) and `index`.
- **`in_app_countdown`** — modal with a live-ticking deadline. Accepts:
  - `deadline` — ISO-8601 (`2026-05-01T18:00:00Z`), relative (`+24 hours`,
    `+30 minutes`, `+3 days`, `+2 weeks`), or unix-seconds number.
  - Optional `image_url` (16:9 hero on top), `cta_text` / `cta_url`,
    `ended_text` (replaces the timer when zero is reached).
  - Renders `D : HH : MM : SS` boxes, hides the days cell when 0. Tabular
    figures so digits don't jitter as the seconds tick. CTA disables when
    the timer reaches zero.

All three follow the same dismiss-event contract as the existing formats —
fire `__dijji_message_dismissed` with `reason` set to one of `manual`,
`submitted`, `cta`.

## 1.1.3-alpha · 2026-04-30

In-app message format upgrade — image support across all renderers and a new
full-bleed `in_app_hero` takeover format.

### Added
- **`image_url` support on all in-app formats**:
  - `in_app_banner` — 40×40 thumbnail rendered inside the strip alongside the
    title/body. `BoxFit.cover` with rounded corners.
  - `in_app_bottom_sheet` — 16:9 hero image at the top of the sheet, above the
    title.
  - `in_app_modal` — 16:9 image flush against the top of the modal card
    (full-bleed under the rounded corners via `clipBehavior: Clip.antiAlias`).
  - All renderers fail soft on broken URLs — `Image.network`'s `errorBuilder`
    returns an empty `SizedBox` so a missing/blocked image never breaks the
    surrounding layout.
- **New `in_app_hero` format** — full-bleed takeover dialog with a 4:3 hero
  image, dark gradient overlay, prominent title + body, primary CTA button,
  optional secondary CTA (via `secondary_cta_text`), and a translucent close
  button in the top-right. Backdrop is fully blocking; tap-outside dismisses
  via the standard `barrierDismissible`. Centered on-screen with a max-width
  of 420 and max-height of 86% viewport — looks right on phones and tablets.

### Changed
- `_ModalWidget` now uses `Column` + `Padding` rather than a single root
  `Padding(child: Column)` so the hero image can sit flush against the modal
  edges while the title/body/CTA still get their inner padding.

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
