import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'config.dart';
import 'logger.dart';

/// Thin HTTP wrapper for /t/app/* endpoints. Mirrors Android's `Api.kt` and
/// iOS's `Api.swift`; same headers, same body shapes, same silent-on-failure
/// philosophy. The caller owns retry — successful flush returns true,
/// failure returns false and the queue keeps the events.
class Transport {
  Transport(this._config);

  final DijjiConfig _config;
  final http.Client _client = http.Client();

  Map<String, String> _headers() => {
        'Content-Type': 'application/json; charset=utf-8',
        'X-Dijji-Sdk-Platform': _platform,
        'X-Dijji-Sdk-Version': '$dijjiSdkVariant-$dijjiSdkVersion',
        'User-Agent': 'Dijji-Flutter-SDK/$dijjiSdkVersion',
      };

  /// Resolved at construction so tests can override via subclassing without
  /// importing dart:io directly.
  String get _platform => _resolvedPlatform ?? 'android';

  String? _resolvedPlatform;
  void overridePlatformForTest(String p) => _resolvedPlatform = p;
  void setRuntimePlatform(String p) => _resolvedPlatform = p;

  Future<bool> postCollect({
    required String visitorId,
    String? userId,
    String? sessionId,
    String? appId,
    String? appVersion,
    required Map<String, Object?> context,
    required Map<String, Object?>? superProperties,
    required List<Map<String, Object?>> events,
  }) async {
    if (events.isEmpty) return true;
    return _post('/t/app/collect', {
      'site': _config.siteKey,
      'visitor_id': visitorId,
      if (userId != null) 'user_id': userId,
      if (sessionId != null) 'session_id': sessionId,
      if (appId != null) 'app_id': appId,
      if (appVersion != null) 'app_version': appVersion,
      'context': context,
      if (superProperties != null && superProperties.isNotEmpty)
        'super_properties': superProperties,
      'events': events,
    });
  }

  Future<bool> postSession({
    required String sessionId,
    required String visitorId,
    String? userId,
    String? appId,
    String? appVersion,
    int? startedAt,
    int? endedAt,
    int durationSeconds = 0,
    int screensCount = 0,
    int eventsCount = 0,
    bool crashed = false,
    bool fromPush = false,
    String? deepLink,
  }) async {
    return _post('/t/app/session', {
      'site': _config.siteKey,
      'session_id': sessionId,
      'visitor_id': visitorId,
      if (userId != null) 'user_id': userId,
      if (appId != null) 'app_id': appId,
      if (appVersion != null) 'app_version': appVersion,
      if (startedAt != null) 'started_at': startedAt,
      if (endedAt != null) 'ended_at': endedAt,
      'duration_seconds': durationSeconds,
      'screens_count': screensCount,
      'events_count': eventsCount,
      'crashed': crashed,
      'from_push': fromPush,
      if (deepLink != null) 'deep_link': deepLink,
    });
  }

  /// /t/app/install — Play Install Referrer payload. Mirrors the Android
  /// SDK's `postInstall` shape exactly: `install_referrer` is the raw URL
  /// query string Google Play returns; the server parses UTM keys out of
  /// it. Click + install timestamps are seconds-since-epoch; null when
  /// Play didn't return them.
  Future<bool> postInstall({
    required String siteKey,
    required String visitorId,
    required String installReferrer,
    int? clickTs,
    int? installTs,
    String? appId,
    String? appVersion,
    String? osVersion,
    String? deviceModel,
  }) async {
    return _post('/t/app/install', {
      'site': siteKey,
      'visitor_id': visitorId,
      'install_referrer': installReferrer,
      if (clickTs != null) 'click_ts': clickTs,
      if (installTs != null) 'install_ts': installTs,
      if (appId != null) 'app_id': appId,
      if (appVersion != null) 'app_version': appVersion,
      if (osVersion != null) 'os_version': osVersion,
      if (deviceModel != null) 'device_model': deviceModel,
    });
  }

  Future<bool> postToken({
    required String token,
    required String visitorId,
    String? userId,
    String? appId,
    String? appVersion,
  }) async {
    if (token.isEmpty) return false;
    return _post('/t/app/token', {
      'site': _config.siteKey,
      'visitor_id': visitorId,
      if (userId != null) 'user_id': userId,
      if (appId != null) 'app_id': appId,
      if (appVersion != null) 'app_version': appVersion,
      'token': token,
    });
  }

  Future<bool> postCrash({
    required String visitorId,
    String? userId,
    String? sessionId,
    String? appId,
    String? appVersion,
    String? osVersion,
    String? deviceModel,
    required String crashType,
    String? reason,
    required String stackTrace,
    List<Map<String, Object?>>? breadcrumbs,
    Map<String, Object?>? state,
  }) async {
    return _post('/t/app/crash', {
      'site': _config.siteKey,
      'visitor_id': visitorId,
      if (userId != null) 'user_id': userId,
      if (sessionId != null) 'session_id': sessionId,
      if (appId != null) 'app_id': appId,
      if (appVersion != null) 'app_version': appVersion,
      if (osVersion != null) 'os_version': osVersion,
      if (deviceModel != null) 'device_model': deviceModel,
      'crash_type': crashType,
      if (reason != null) 'reason': reason,
      'stack_trace': stackTrace,
      if (breadcrumbs != null) 'breadcrumbs': breadcrumbs,
      if (state != null) 'state': state,
      'ts': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    });
  }

  Future<List<Map<String, Object?>>> getInbox({
    required String visitorId,
  }) async {
    final uri = Uri.parse(
      '${_config.sanitizedEndpoint}/t/app/inbox?site=${Uri.encodeQueryComponent(_config.siteKey)}'
      '&visitor=${Uri.encodeQueryComponent(visitorId)}',
    );
    try {
      final resp = await _client.get(uri, headers: _headers()).timeout(
            const Duration(seconds: 10),
          );
      if (resp.statusCode != 200) return const [];
      final body = jsonDecode(resp.body);
      if (body is! Map) return const [];
      final messages = body['messages'];
      if (messages is! List) return const [];
      return messages
          .whereType<Map>()
          .map<Map<String, Object?>>(Map<String, Object?>.from)
          .toList();
    } on TimeoutException {
      return const [];
    } catch (e) {
      DijjiLog.d('inbox fetch failed: $e');
      return const [];
    }
  }

  Future<bool> _post(String path, Map<String, Object?> body) async {
    final uri = Uri.parse('${_config.sanitizedEndpoint}$path');
    try {
      final resp = await _client
          .post(uri, headers: _headers(), body: jsonEncode(body))
          .timeout(const Duration(seconds: 15));
      final ok = resp.statusCode >= 200 && resp.statusCode < 300;
      if (!ok) DijjiLog.d('POST $path -> ${resp.statusCode}');
      return ok;
    } on TimeoutException {
      DijjiLog.d('POST $path timed out');
      return false;
    } catch (e) {
      DijjiLog.d('POST $path errored: $e');
      return false;
    }
  }

  void close() => _client.close();
}
