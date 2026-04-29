import 'dart:async';

import 'config.dart';
import 'identity.dart';
import 'logger.dart';
import 'transport.dart';

/// Polls /t/app/inbox at [DijjiConfig.inboxPollInterval] and hands any
/// returned messages to a renderer. The endpoint marks messages delivered
/// on read, so each one is dispatched at most once.
///
/// The renderer is decoupled from the poller so apps that want to handle
/// in-app messages themselves (e.g. wire them into their own Material
/// design system) can pass `renderInAppMessages: false` in [DijjiConfig]
/// and consume the stream via [InboxPoller.messagesStream].
class InboxPoller {
  InboxPoller({
    required DijjiConfig config,
    required Transport transport,
    required Identity identity,
  })  : _config = config,
        _transport = transport,
        _identity = identity;

  final DijjiConfig _config;
  final Transport _transport;
  final Identity _identity;

  final StreamController<List<Map<String, Object?>>> _controller =
      StreamController<List<Map<String, Object?>>>.broadcast();
  Timer? _timer;
  bool _polling = false;

  Stream<List<Map<String, Object?>>> get messagesStream => _controller.stream;

  void start() {
    if (_timer != null) return;
    // First fetch on next microtask so it doesn't block app startup.
    scheduleMicrotask(_pollOnce);
    _timer = Timer.periodic(_config.inboxPollInterval, (_) => _pollOnce());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _pollOnce() async {
    if (_polling) return;
    if (_identity.optedOut) return;
    _polling = true;
    try {
      final messages =
          await _transport.getInbox(visitorId: _identity.visitorId);
      if (messages.isEmpty) return;
      DijjiLog.d('inbox: ${messages.length} messages');
      _controller.add(messages);
    } finally {
      _polling = false;
    }
  }

  void dispose() {
    _timer?.cancel();
    _controller.close();
  }
}
