import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/services.dart';

/// Android 14+ 전체화면(풀스크린) 통화 알림 권한 헬퍼(네이티브 MethodChannel).
/// 이 권한이 없으면 수신 통화가 잠금화면 위로 뜨지 않고 헤드업 배너로만 표시된다.
class FullScreenPerm {
  static const _ch = MethodChannel('app/fullscreen');

  static bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// 풀스크린 통화 알림을 쓸 수 있는가(14 미만/비안드로이드는 true).
  static Future<bool> canUse() async {
    if (!_isAndroid) return true;
    try {
      return (await _ch.invokeMethod<bool>('canUseFullScreenIntent')) ?? true;
    } catch (_) {
      return true;
    }
  }

  /// "전체 화면 알림 허용" 설정 화면 열기.
  static Future<void> openSettings() async {
    if (!_isAndroid) return;
    try {
      await _ch.invokeMethod('openFullScreenSettings');
    } catch (_) {}
  }
}
