import 'package:dijji/src/session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('first touch starts a session and emits session_start', () {
    final emitted = <String>[];
    final s = Session(60, (name, _) => emitted.add(name));

    final id = s.touch();
    expect(id, isNotEmpty);
    expect(emitted, equals(['session_start']));
  });

  test('end emits session_end and clears the id', () {
    final emitted = <String>[];
    final s = Session(60, (name, _) => emitted.add(name));
    s.touch();
    emitted.clear();

    s.end();
    expect(emitted, equals(['session_end']));
    expect(s.id, isNull);
  });

  test('after end, next touch starts a fresh session', () {
    final emitted = <String>[];
    final s = Session(60, (name, _) => emitted.add(name));
    s.touch();
    s.end();
    emitted.clear();

    final id2 = s.touch();
    expect(id2, isNotEmpty);
    expect(emitted, equals(['session_start']));
  });
}
