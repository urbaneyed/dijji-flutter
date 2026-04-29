import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Super-properties — persistent key/value bag attached to every event.
///
/// Mirrors the Android `Properties.kt` and the iOS `setUserProperty` path:
/// pairs persist across launches in [SharedPreferences] so a user's
/// "plan=pro" sticks until the app explicitly clears it. Bulk operations
/// are atomic so a partial failure can't leave the bag half-updated.
class Properties {
  static const String _kKey = 'dijji.super_properties';
  static const int _maxKeys = 100;

  Properties._(this._prefs, this._values);

  final SharedPreferences _prefs;
  final Map<String, Object?> _values;

  static Future<Properties> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kKey);
    Map<String, Object?> parsed = <String, Object?>{};
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) parsed = Map<String, Object?>.from(decoded);
      } catch (_) {/* corrupt — discard */}
    }
    return Properties._(prefs, parsed);
  }

  Map<String, Object?> snapshot() => Map<String, Object?>.from(_values);

  Future<void> set(String key, Object? value) async {
    if (key.isEmpty) return;
    if (value == null) {
      _values.remove(key);
    } else {
      _values[key] = value;
    }
    await _persist();
  }

  Future<void> setAll(Map<String, Object?> values) async {
    values.forEach((k, v) {
      if (k.isEmpty) return;
      if (v == null) {
        _values.remove(k);
      } else {
        _values[k] = v;
      }
    });
    await _persist();
  }

  Future<void> unset(String key) async {
    if (_values.remove(key) != null) await _persist();
  }

  Future<void> clear() async {
    _values.clear();
    await _prefs.remove(_kKey);
  }

  Future<void> _persist() async {
    if (_values.length > _maxKeys) {
      final overflow = _values.length - _maxKeys;
      final keys = _values.keys.take(overflow).toList();
      for (final k in keys) {
        _values.remove(k);
      }
    }
    await _prefs.setString(_kKey, jsonEncode(_values));
  }
}
