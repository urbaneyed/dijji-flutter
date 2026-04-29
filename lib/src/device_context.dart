import 'dart:io' show Platform;
import 'dart:ui' show PlatformDispatcher, Brightness;

import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'logger.dart';

/// The rich-data snapshot sent with every /t/app/collect call.
///
/// Mirrors Android `Context.kt`:
///   Static fields: app_id, app_version, os_version, device_model, device_mfr,
///                  install_source, locale, carrier
///   Live fields:   network_type, dark_mode, orientation, font_scale,
///                  battery_level, battery_charging, screen_*, timezone
///   Lifecycle:     session_sequence, days_since_install
///
/// All collection is best-effort; any individual probe failing returns null
/// rather than throwing. The `dijji_app_users` server-side upsert tolerates
/// nulls everywhere.
class DeviceContext {
  static const String _kFirstRun = 'dijji.first_run_ts';
  static const String _kSessionSeq = 'dijji.session_sequence';

  DeviceContext._({
    required SharedPreferences prefs,
    required this.appId,
    required this.appVersion,
    required this.osVersion,
    required this.deviceModel,
    required this.deviceMfr,
    required this.installSource,
    required this.locale,
    required this.timezone,
  })  : _prefs = prefs,
        _battery = Battery(),
        _connectivity = Connectivity();

  final SharedPreferences _prefs;
  final Battery _battery;
  final Connectivity _connectivity;

  // Static, computed once.
  final String appId;
  final String? appVersion;
  final String? osVersion;
  final String? deviceModel;
  final String? deviceMfr;
  final String? installSource;
  final String? locale;
  final String? timezone;

  /// Carrier requires a Telephony permission on Android, and isn't readable
  /// at all on iOS (deprecated since iOS 16). We send null for now and
  /// surface this as an honest gap in the docs.
  String? get carrier => null;

  static Future<DeviceContext> gather() async {
    final prefs = await SharedPreferences.getInstance();
    final pkg = await _safe<PackageInfo>(PackageInfo.fromPlatform);
    final dev = DeviceInfoPlugin();

    String? osVer;
    String? model;
    String? mfr;
    String? installSource;
    if (Platform.isAndroid) {
      final info = await _safe<AndroidDeviceInfo>(() => dev.androidInfo);
      osVer = info != null ? 'Android ${info.version.release}' : null;
      model = info?.model;
      mfr = info?.manufacturer;
      // Android-side install source is best inferred via PackageManager,
      // which Dart can't reach without a platform channel. Punt to v1.1.
      installSource = null;
    } else if (Platform.isIOS) {
      final info = await _safe<IosDeviceInfo>(() => dev.iosInfo);
      osVer = info != null ? 'iOS ${info.systemVersion}' : null;
      model = info?.utsname.machine;
      mfr = 'Apple';
      installSource = 'app_store';
    }

    return DeviceContext._(
      prefs: prefs,
      appId: pkg?.packageName ?? '',
      appVersion: pkg?.version,
      osVersion: osVer,
      deviceModel: model,
      deviceMfr: mfr,
      installSource: installSource,
      locale: _resolveLocale(),
      timezone: DateTime.now().timeZoneName,
    );
  }

  Future<String?> networkType() async {
    try {
      final results = await _connectivity.checkConnectivity();
      if (results.isEmpty) return 'unknown';
      // Pick the strongest live connection to report. Order mirrors the
      // Android SDK's preference: wifi first, cellular, ethernet, other.
      final r = results.first;
      switch (r) {
        case ConnectivityResult.wifi:
          return 'wifi';
        case ConnectivityResult.mobile:
          return 'cellular';
        case ConnectivityResult.ethernet:
          return 'ethernet';
        case ConnectivityResult.vpn:
          return 'vpn';
        case ConnectivityResult.bluetooth:
          return 'bluetooth';
        case ConnectivityResult.none:
          return 'none';
        default:
          return 'other';
      }
    } catch (_) {
      return null;
    }
  }

  Future<int?> batteryLevel() async {
    try {
      return await _battery.batteryLevel;
    } catch (_) {
      return null;
    }
  }

  Future<bool?> batteryCharging() async {
    try {
      final s = await _battery.batteryState;
      return s == BatteryState.charging || s == BatteryState.full;
    } catch (_) {
      return null;
    }
  }

  bool darkMode() =>
      WidgetsBinding.instance.platformDispatcher.platformBrightness ==
      Brightness.dark;

  String orientation() {
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    return view.physicalSize.width > view.physicalSize.height
        ? 'landscape'
        : 'portrait';
  }

  double? fontScale() =>
      WidgetsBinding.instance.platformDispatcher.textScaleFactor;

  Map<String, num?> screenMetrics() {
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final size = view.physicalSize;
    return {
      'screen_width_px': size.width.toInt(),
      'screen_height_px': size.height.toInt(),
      'screen_density': view.devicePixelRatio,
    };
  }

  /// Bumps the persistent session counter and returns the new value. Called
  /// by [Session.start] when a fresh session begins.
  Future<int> bumpSessionSequence() async {
    final next = (_prefs.getInt(_kSessionSeq) ?? 0) + 1;
    await _prefs.setInt(_kSessionSeq, next);
    return next;
  }

  int sessionSequence() => _prefs.getInt(_kSessionSeq) ?? 0;

  Future<int> daysSinceInstall() async {
    final t = _prefs.getInt(_kFirstRun);
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (t == null || t <= 0) {
      await _prefs.setInt(_kFirstRun, nowSec);
      return 0;
    }
    final delta = (nowSec - t) ~/ 86400;
    return delta < 0 ? 0 : delta;
  }

  /// One canonical bag — keys match what `dijji_app_users` stores so the
  /// server-side upsert is a 1:1 pass.
  Future<Map<String, Object?>> snapshot() async {
    final dim = screenMetrics();
    return {
      'os_version': osVersion,
      'device_model': deviceModel,
      'device_mfr': deviceMfr,
      'install_source': installSource,
      'locale': locale,
      'carrier': carrier,
      'screen_width_px': dim['screen_width_px'],
      'screen_height_px': dim['screen_height_px'],
      'screen_density': dim['screen_density'],
      'dark_mode': darkMode(),
      'font_scale': fontScale(),
      'orientation': orientation(),
      'network_type': await networkType(),
      'timezone': timezone,
      'battery_level': await batteryLevel(),
      'battery_charging': await batteryCharging(),
      'session_sequence': sessionSequence(),
      'days_since_install': await daysSinceInstall(),
    };
  }

  static String? _resolveLocale() {
    try {
      final l = PlatformDispatcher.instance.locale;
      final country = l.countryCode == null ? '' : '_${l.countryCode}';
      return '${l.languageCode}$country';
    } catch (_) {
      return null;
    }
  }

  static Future<T?> _safe<T>(Future<T> Function() body) async {
    try {
      return await body();
    } catch (e) {
      DijjiLog.d('device probe failed: $e');
      return null;
    }
  }
}
