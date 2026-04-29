import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

/// Persists the per-install identity bundle: visitor_id (random UUID, stable
/// across launches), user_id (set by [Dijji.identify]), opt-out flag.
///
/// Storage is `SharedPreferences` to match the Android SDK's storage class
/// of choice. iOS native uses `UserDefaults` which is the same shape.
class Identity {
  static const String _kVisitorId = 'dijji.visitor_id';
  static const String _kUserId = 'dijji.user_id';
  static const String _kOptOut = 'dijji.opt_out';

  Identity._(this._prefs, this._visitorId, this._userId, this._optedOut);

  final SharedPreferences _prefs;
  String _visitorId;
  String? _userId;
  bool _optedOut;

  String get visitorId => _visitorId;
  String? get userId => _userId;
  bool get optedOut => _optedOut;

  static Future<Identity> load() async {
    final prefs = await SharedPreferences.getInstance();
    var visitor = prefs.getString(_kVisitorId);
    if (visitor == null || visitor.isEmpty) {
      visitor = _newUuid();
      await prefs.setString(_kVisitorId, visitor);
    }
    final user = prefs.getString(_kUserId);
    final opt = prefs.getBool(_kOptOut) ?? false;
    return Identity._(prefs, visitor, user, opt);
  }

  Future<void> setUserId(String userId) async {
    _userId = userId;
    await _prefs.setString(_kUserId, userId);
  }

  Future<void> setOptedOut(bool out) async {
    _optedOut = out;
    await _prefs.setBool(_kOptOut, out);
  }

  /// Logout. Clears user_id, rotates visitor_id. Keeps opt-out flag.
  Future<void> reset() async {
    _userId = null;
    _visitorId = _newUuid();
    await _prefs.remove(_kUserId);
    await _prefs.setString(_kVisitorId, _visitorId);
  }

  /// RFC4122 v4-shaped UUID without an extra dependency. The server treats
  /// visitor_id as opaque so cryptographic randomness isn't strictly needed,
  /// but we use Random.secure to be safe. Exposed (`newUuid`) so the
  /// session machine can mint session_ids with the same shape without
  /// pulling in `package:uuid`.
  static String newUuid() => _newUuid();

  static String _newUuid() {
    final r = Random.secure();
    final bytes = List<int>.generate(16, (_) => r.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 1
    String hex(int i) => bytes[i].toRadixString(16).padLeft(2, '0');
    final b = StringBuffer();
    for (var i = 0; i < 16; i++) {
      if (i == 4 || i == 6 || i == 8 || i == 10) b.write('-');
      b.write(hex(i));
    }
    return b.toString();
  }
}
