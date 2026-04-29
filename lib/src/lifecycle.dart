import 'package:flutter/widgets.dart';

import 'queue.dart';
import 'session.dart';

/// Bridges Flutter's [WidgetsBindingObserver] into Dijji's session/event
/// bookkeeping. Same shape as Android `Lifecycle.kt`:
///
///   resumed       → app_open (cold) / app_foreground (warm) + session.touch()
///   inactive      → ignored (transient state on iOS, e.g. control centre)
///   paused/hidden → app_background + queue.flush() + session.end()
///   detached      → final flush attempt, but the OS is killing us — best effort
class DijjiLifecycle extends WidgetsBindingObserver {
  DijjiLifecycle({
    required EventQueue queue,
    required Session session,
    required void Function() onForeground,
    required void Function() onBackground,
  })  : _queue = queue,
        _session = session,
        _onForeground = onForeground,
        _onBackground = onBackground;

  final EventQueue _queue;
  final Session _session;
  final void Function() _onForeground;
  final void Function() _onBackground;

  bool _hasFiredColdOpen = false;
  bool _wasBackgrounded = false;

  void start() {
    WidgetsBinding.instance.addObserver(this);
    // Defer the cold-start app_open to after the first frame so the app's
    // initial route name is already in the navigator (and screen_view fires
    // immediately after, in the right order).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_hasFiredColdOpen) {
        _hasFiredColdOpen = true;
        _session.touch();
        _queue.enqueue(name: 'app_open', properties: const {'cold_start': true});
        _onForeground();
      }
    });
  }

  void stop() {
    WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        if (_wasBackgrounded) {
          _wasBackgrounded = false;
          _session.touch();
          _queue.enqueue(name: 'app_foreground');
          _onForeground();
        }
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        if (!_wasBackgrounded) {
          _wasBackgrounded = true;
          _queue.enqueue(name: 'app_background');
          _onBackground();
          // Flush eagerly — process may not survive long.
          // ignore: discarded_futures
          _queue.flush();
        }
        break;
      case AppLifecycleState.detached:
        // ignore: discarded_futures
        _queue.flush();
        break;
      case AppLifecycleState.inactive:
        // No-op on iOS this is "between two scenes"; on Android it's a no-op too.
        break;
    }
  }
}
