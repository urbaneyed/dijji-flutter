import 'package:flutter/foundation.dart';

class DijjiLog {
  static bool debugEnabled = false;

  static void d(String msg) {
    if (debugEnabled && kDebugMode) {
      // ignore: avoid_print
      print('[dijji] $msg');
    }
  }

  static void w(String msg) {
    // ignore: avoid_print
    if (kDebugMode) print('[dijji] WARN: $msg');
  }

  static void e(String msg) {
    // ignore: avoid_print
    if (kDebugMode) print('[dijji] ERROR: $msg');
  }
}
