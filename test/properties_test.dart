import 'package:dijji/src/properties.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('set + reload round-trips', () async {
    final p = await Properties.load();
    await p.set('plan', 'pro');
    await p.set('count', 3);

    final reloaded = await Properties.load();
    final snap = reloaded.snapshot();
    expect(snap['plan'], equals('pro'));
    expect(snap['count'], equals(3));
  });

  test('passing null clears a key', () async {
    final p = await Properties.load();
    await p.set('plan', 'pro');
    await p.set('plan', null);
    expect(p.snapshot().containsKey('plan'), isFalse);
  });

  test('clear empties everything', () async {
    final p = await Properties.load();
    await p.setAll({'a': 1, 'b': 2});
    await p.clear();
    expect(p.snapshot(), isEmpty);
  });
}
