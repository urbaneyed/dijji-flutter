/// One row in the outbound batch sent to /t/app/collect. Properties are
/// truncated and depth-limited to match the server's `encodeProps` rules:
/// max 64-char keys, 500-char string values, one level of nesting.
class DijjiEvent {
  final String eventId;
  final String name;
  final String? screen;
  final Map<String, Object?>? properties;
  final int tsSeconds;
  final String? sessionId;

  DijjiEvent({
    required this.eventId,
    required this.name,
    this.screen,
    this.properties,
    required this.tsSeconds,
    this.sessionId,
  });

  /// Wire shape — keys match `AppTracker::collect` parsing.
  Map<String, Object?> toJson() => {
        'event_id': eventId,
        'name': name,
        if (screen != null) 'screen': screen,
        if (properties != null && properties!.isNotEmpty)
          'properties': _flatten(properties!),
        'ts': tsSeconds,
        if (sessionId != null) 'session_id': sessionId,
      };

  Map<String, Object?> toStorage() => {
        'event_id': eventId,
        'name': name,
        'screen': screen,
        'properties': properties,
        'ts': tsSeconds,
        'session_id': sessionId,
      };

  static DijjiEvent fromStorage(Map<String, Object?> raw) => DijjiEvent(
        eventId: raw['event_id'] as String? ?? '',
        name: raw['name'] as String? ?? '',
        screen: raw['screen'] as String?,
        properties: raw['properties'] is Map
            ? Map<String, Object?>.from(raw['properties'] as Map)
            : null,
        tsSeconds: (raw['ts'] as num?)?.toInt() ?? 0,
        sessionId: raw['session_id'] as String?,
      );

  /// Mirrors the server's encodeProps rules so we don't ship payloads we
  /// know will be reshaped on the other side.
  static Map<String, Object?> _flatten(Map<String, Object?> raw) {
    final out = <String, Object?>{};
    raw.forEach((k, v) {
      final kk = k.length > 64 ? k.substring(0, 64) : k;
      if (v == null || v is num || v is bool) {
        out[kk] = v;
      } else if (v is String) {
        out[kk] = v.length > 500 ? v.substring(0, 500) : v;
      } else if (v is Map) {
        final inner = <String, Object?>{};
        v.forEach((ik, iv) {
          if (ik is! String) return;
          final ikk = ik.length > 64 ? ik.substring(0, 64) : ik;
          if (iv == null || iv is num || iv is bool) {
            inner[ikk] = iv;
          } else if (iv is String) {
            inner[ikk] = iv.length > 500 ? iv.substring(0, 500) : iv;
          }
        });
        if (inner.isNotEmpty) out[kk] = inner;
      } else if (v is List) {
        // Lists of scalars only — drop on the floor if heterogeneous.
        final scalars = v
            .where((e) => e == null || e is num || e is bool || e is String)
            .map((e) => (e is String && e.length > 500) ? e.substring(0, 500) : e)
            .toList();
        if (scalars.isNotEmpty) out[kk] = scalars;
      }
    });
    return out;
  }
}
