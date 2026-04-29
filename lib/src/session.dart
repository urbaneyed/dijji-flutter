import 'identity.dart';

typedef SessionEnqueueCallback = void Function(String name, Map<String, Object?>? props);

/// Session state machine — rotates `session_id` after the configured idle
/// window. Lives entirely in memory; the server canonicalises sessions via
/// `/t/app/session` upserts so a process kill mid-session is fine.
///
/// Usage pattern (matches Android `Session.kt`):
///   - Foreground or first event:   [touch]      — extends or restarts session
///   - Background:                  [end]        — emits session_end
///   - Per screen visit:            [bumpScreens]
class Session {
  Session(this._timeoutSeconds, this._onEnqueue);

  final int _timeoutSeconds;
  final SessionEnqueueCallback _onEnqueue;

  String? _id;
  int _startedAt = 0;
  int _lastEventAt = 0;
  int _screensCount = 0;
  int _eventsCount = 0;

  String? get id => _id;
  int get startedAt => _startedAt;
  int get lastEventAt => _lastEventAt;
  int get screensCount => _screensCount;
  int get eventsCount => _eventsCount;

  /// Returns the active session id, starting a fresh one if none / expired.
  String touch() {
    final now = _nowSec();
    if (_id == null || (now - _lastEventAt) > _timeoutSeconds) {
      _start(now);
    }
    _lastEventAt = now;
    _eventsCount += 1;
    return _id!;
  }

  void bumpScreens() {
    _screensCount += 1;
  }

  void _start(int now) {
    _id = Identity.newUuid();
    _startedAt = now;
    _lastEventAt = now;
    _screensCount = 0;
    _eventsCount = 0;
    _onEnqueue('session_start', null);
  }

  /// Emit session_end and clear the active id. Subsequent `touch()` will
  /// start a fresh session.
  void end() {
    if (_id == null) return;
    _onEnqueue('session_end', {
      'duration_seconds': _lastEventAt - _startedAt,
      'screens_count': _screensCount,
      'events_count': _eventsCount,
    });
    _id = null;
  }

  int _nowSec() => DateTime.now().millisecondsSinceEpoch ~/ 1000;
}
