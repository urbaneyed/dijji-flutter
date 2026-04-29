import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'config.dart';
import 'crash.dart';
import 'device_context.dart';
import 'event.dart';
import 'identity.dart';
import 'logger.dart';
import 'properties.dart';
import 'transport.dart';

/// In-memory event queue with [SharedPreferences]-backed durability across
/// app restarts. Coalesces events into batches up to 50 (server cap) and
/// flushes on a timer or eagerly on "interesting" events.
///
/// Persistence model:
///   - On every enqueue and every failed flush, the queue is rewritten to
///     SharedPreferences as a JSON array. Reads happen exactly once at init.
///   - Newest-first overflow: when buffer hits [DijjiConfig.maxQueueSize] the
///     oldest event is dropped (network outage on day 12 shouldn't clog the
///     pipe with 12-day-old events).
///
/// Re-queue on flush failure preserves chronological order. Timestamp drift
/// from offline storage is acceptable because the server stamps `occurred_at`
/// from each event's own `ts` field.
class EventQueue {
  EventQueue({
    required DijjiConfig config,
    required Transport transport,
    required Identity identity,
    required Properties properties,
    required DeviceContext deviceContext,
    required CrashRecorder crashRecorder,
    String? Function()? sessionIdProvider,
  })  : _config = config,
        _transport = transport,
        _identity = identity,
        _properties = properties,
        _deviceContext = deviceContext,
        _crashRecorder = crashRecorder,
        _sessionIdProvider = sessionIdProvider ?? (() => null);

  static const String _kStorageKey = 'dijji.event_queue';
  static const int _serverBatchCap = 50;
  static const Set<String> _eagerEvents = {
    'app_open',
    'app_install',
    'session_start',
    'app_crash',
    r'$identify',
  };

  final DijjiConfig _config;
  final Transport _transport;
  final Identity _identity;
  final Properties _properties;
  final DeviceContext _deviceContext;
  final CrashRecorder _crashRecorder;
  final String? Function() _sessionIdProvider;

  final Queue<DijjiEvent> _buffer = Queue<DijjiEvent>();
  Timer? _flushTimer;
  bool _flushing = false;
  SharedPreferences? _prefs;

  /// Restore any events persisted from a previous launch. Idempotent.
  Future<void> restore() async {
    _prefs = await SharedPreferences.getInstance();
    final raw = _prefs!.getString(_kStorageKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      for (final entry in decoded) {
        if (entry is Map) {
          _buffer.add(DijjiEvent.fromStorage(Map<String, Object?>.from(entry)));
        }
      }
      DijjiLog.d('queue restored ${_buffer.length} events');
    } catch (e) {
      DijjiLog.w('queue restore failed: $e');
      await _prefs!.remove(_kStorageKey);
    }
  }

  /// Begin the periodic flush timer. Call after [restore].
  void startPeriodicFlush() {
    _flushTimer?.cancel();
    _flushTimer = Timer.periodic(_config.flushInterval, (_) => flush());
  }

  void stopPeriodicFlush() {
    _flushTimer?.cancel();
    _flushTimer = null;
  }

  /// Enqueue a single event. Stamps timestamp + session_id + event_id, adds
  /// a breadcrumb for crash context, then schedules a flush.
  void enqueue({
    required String name,
    Map<String, Object?>? properties,
    String? screen,
  }) {
    if (_identity.optedOut) return;
    final event = DijjiEvent(
      eventId: Identity.newUuid(),
      name: name,
      screen: screen,
      properties: properties,
      tsSeconds: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      sessionId: _sessionIdProvider(),
    );
    _crashRecorder.addBreadcrumb(name, properties, screen);
    _buffer.add(event);
    while (_buffer.length > _config.clampedMaxQueueSize) {
      _buffer.removeFirst();
    }
    _persist();
    if (_eagerEvents.contains(name) || _buffer.length >= _serverBatchCap) {
      // Microtask so the caller of track() returns synchronously; the actual
      // network call happens after the current synchronous chunk yields.
      scheduleMicrotask(flush);
    }
  }

  /// Force a flush of as many events as fit in one server batch. Returns
  /// once the network call has settled (success or failure). Safe to call
  /// from any isolate event-loop context.
  Future<void> flush() async {
    if (_flushing) return;
    if (_buffer.isEmpty) return;
    if (_identity.optedOut) {
      _buffer.clear();
      await _persist();
      return;
    }
    _flushing = true;
    try {
      final batch = <DijjiEvent>[];
      while (batch.length < _serverBatchCap && _buffer.isNotEmpty) {
        batch.add(_buffer.removeFirst());
      }
      if (batch.isEmpty) return;
      await _persist();

      final superProps = _properties.snapshot();
      final ctxSnapshot = await _deviceContext.snapshot();
      final ok = await _transport.postCollect(
        visitorId: _identity.visitorId,
        userId: _identity.userId,
        sessionId: _sessionIdProvider(),
        appId: _deviceContext.appId,
        appVersion: _deviceContext.appVersion,
        context: ctxSnapshot,
        superProperties: superProps.isEmpty ? null : superProps,
        events: batch.map((e) => e.toJson()).toList(),
      );

      if (!ok) {
        // Re-insert at head, preserving order. Cap-trim again in case enqueue
        // added more events while we were on the wire.
        for (final e in batch.reversed) {
          _buffer.addFirst(e);
        }
        while (_buffer.length > _config.clampedMaxQueueSize) {
          _buffer.removeFirst();
        }
        await _persist();
      }
    } finally {
      _flushing = false;
    }
  }

  Future<void> _persist() async {
    final prefs = _prefs;
    if (prefs == null) return;
    if (_buffer.isEmpty) {
      await prefs.remove(_kStorageKey);
      return;
    }
    final json = jsonEncode(_buffer.map((e) => e.toStorage()).toList());
    await prefs.setString(_kStorageKey, json);
  }

  int debugSize() => _buffer.length;
}
