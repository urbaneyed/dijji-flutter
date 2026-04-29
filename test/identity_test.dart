import 'package:dijji/src/identity.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('first load mints a v4 UUID and persists it', () async {
    final id = await Identity.load();
    expect(id.visitorId, matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));

    final id2 = await Identity.load();
    expect(id2.visitorId, equals(id.visitorId));
  });

  test('reset rotates visitor_id and clears user_id', () async {
    final id = await Identity.load();
    await id.setUserId('user_1');
    final original = id.visitorId;

    await id.reset();
    expect(id.visitorId, isNot(equals(original)));
    expect(id.userId, isNull);
  });

  test('opt-out flag persists across reloads', () async {
    final id = await Identity.load();
    await id.setOptedOut(true);

    final reloaded = await Identity.load();
    expect(reloaded.optedOut, isTrue);
  });

  test('newUuid generates distinct ids', () {
    final ids = List.generate(50, (_) => Identity.newUuid());
    expect(ids.toSet().length, equals(50));
  });
}
