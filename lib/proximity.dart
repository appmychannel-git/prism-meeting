import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/services.dart';

/// 근접센서 화면 끄기(음성통화 시 귀에 대면 화면 off). 네이티브 wake lock 사용.
class ProximityLock {
  static const _ch = MethodChannel('app/fullscreen');
  static bool _held = false;

  static bool get _android =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<void> acquire() async {
    if (!_android || _held) return;
    try {
      await _ch.invokeMethod('acquireProximityLock');
      _held = true;
    } catch (_) {}
  }

  static Future<void> release() async {
    if (!_android || !_held) return;
    _held = false;
    try {
      await _ch.invokeMethod('releaseProximityLock');
    } catch (_) {}
  }
}
