import 'package:dijji/src/config.dart';
import 'package:dijji/src/transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const config = DijjiConfig(siteKey: 'ws_test_abc');

  test('empty events list short-circuits to true without a request', () async {
    final transport = Transport(config);
    transport.setRuntimePlatform('android');
    final ok = await transport.postCollect(
      visitorId: 'v1',
      context: const {},
      superProperties: null,
      events: const [],
    );
    expect(ok, isTrue);
  });

  test('empty token short-circuits to false', () async {
    final transport = Transport(config);
    transport.setRuntimePlatform('ios');
    final ok = await transport.postToken(token: '', visitorId: 'v1');
    expect(ok, isFalse);
  });

  test('endpoint trailing slash is stripped', () {
    const cfg = DijjiConfig(
      siteKey: 'ws_test',
      endpoint: 'https://staging.dijji.com/',
    );
    expect(cfg.sanitizedEndpoint, equals('https://staging.dijji.com'));
  });

  test('config clamps maxQueueSize into [50, 5000]', () {
    expect(
        const DijjiConfig(siteKey: 'k', maxQueueSize: 10).clampedMaxQueueSize,
        equals(50));
    expect(
        const DijjiConfig(siteKey: 'k', maxQueueSize: 9999).clampedMaxQueueSize,
        equals(5000));
    expect(
        const DijjiConfig(siteKey: 'k', maxQueueSize: 250).clampedMaxQueueSize,
        equals(250));
  });
}
