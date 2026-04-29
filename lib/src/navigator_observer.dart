import 'package:flutter/widgets.dart';

import 'session.dart';

/// Captures `screen_view` events from any [Navigator] this observer is
/// attached to. Drop into MaterialApp / CupertinoApp / Navigator like:
///
/// ```dart
/// MaterialApp(
///   navigatorObservers: [Dijji.instance.navigatorObserver],
///   ...,
/// )
/// ```
///
/// Resolves the screen name from `RouteSettings.name` first, falling back
/// to the route's runtime type. This matches what the Android SDK reports
/// for activities ("HomeActivity") and gives Cupertino + custom routes a
/// reasonable fallback when the dev hasn't named them.
class DijjiNavigatorObserver extends NavigatorObserver {
  DijjiNavigatorObserver({
    required void Function(String name, {Map<String, Object?>? properties})
        trackScreen,
    required Session session,
  })  : _trackScreen = trackScreen,
        _session = session;

  final void Function(String name, {Map<String, Object?>? properties})
      _trackScreen;
  final Session _session;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _record(route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (newRoute != null) _record(newRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute != null) _record(previousRoute);
  }

  void _record(Route<dynamic> route) {
    final name = _resolveName(route);
    if (name == null) return;
    _session.bumpScreens();
    _trackScreen(name);
  }

  String? _resolveName(Route<dynamic> route) {
    final settings = route.settings;
    final n = settings.name;
    if (n != null && n.isNotEmpty) return n;
    // Anonymous route — fall back to a stable type name so the dashboard
    // shows something distinct rather than every modal collapsing onto
    // "MaterialPageRoute".
    return route.runtimeType.toString();
  }
}
