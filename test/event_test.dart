import 'package:dijji/src/event.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('properties — strings beyond 500 chars truncate', () {
    final long = 'a' * 1200;
    final event = DijjiEvent(
      eventId: 'eid',
      name: 'test',
      properties: {'long': long},
      tsSeconds: 1,
    );
    final json = event.toJson();
    expect((json['properties'] as Map)['long'], hasLength(500));
  });

  test('properties — keys beyond 64 chars truncate', () {
    final key = 'k' * 80;
    final event = DijjiEvent(
      eventId: 'eid',
      name: 'test',
      properties: {key: 'v'},
      tsSeconds: 1,
    );
    final out = event.toJson()['properties'] as Map;
    expect(out.keys.first, hasLength(64));
  });

  test('properties — nested maps allowed one level deep', () {
    final event = DijjiEvent(
      eventId: 'eid',
      name: 'test',
      properties: {
        'item': {'id': 'i_1', 'name': 'Pro'},
      },
      tsSeconds: 1,
    );
    final out = event.toJson()['properties'] as Map;
    expect(out['item'], isA<Map>());
    expect((out['item'] as Map)['id'], equals('i_1'));
  });

  test('storage round-trip preserves event fields', () {
    final original = DijjiEvent(
      eventId: 'eid',
      name: 'signup',
      screen: 'Pricing',
      properties: {'plan': 'pro', 'count': 3},
      tsSeconds: 12345,
      sessionId: 'sess_1',
    );
    final restored = DijjiEvent.fromStorage(original.toStorage());
    expect(restored.eventId, equals(original.eventId));
    expect(restored.name, equals(original.name));
    expect(restored.screen, equals(original.screen));
    expect(restored.properties?['plan'], equals('pro'));
    expect(restored.properties?['count'], equals(3));
    expect(restored.sessionId, equals(original.sessionId));
    expect(restored.tsSeconds, equals(original.tsSeconds));
  });
}
