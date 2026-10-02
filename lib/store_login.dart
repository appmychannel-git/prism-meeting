import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

/// 마켓앱 로그인 세션 한 줄(ContentProvider에서 읽어온 값).
///
/// 저장하지 않는다 — 매 기동/변경마다 provider에서 다시 읽는다(§2-4).
class StoreLoginInfo {
  final String sessionToken; // 기기 토큰 ds_… — "이게 곧 누구인가"
  final String deviceId;
  final String userId;
  final bool registered; // 계정 단위: 등록된 TV 시리얼이 하나라도 있는가
  final String downloadPolicy; // "login" / "registered"

  const StoreLoginInfo({
    required this.sessionToken,
    required this.deviceId,
    required this.userId,
    required this.registered,
    required this.downloadPolicy,
  });

  /// 로그인 상태 여부. sessionToken이 비면 마켓앱이 로그아웃 상태다.
  bool get isValid => sessionToken.isNotEmpty;

  static StoreLoginInfo fromMap(Map<dynamic, dynamic> m) => StoreLoginInfo(
        sessionToken: (m['sessionToken'] as String?) ?? '',
        deviceId: (m['deviceId'] as String?) ?? '',
        userId: (m['userId'] as String?) ?? '',
        registered: (m['registered'] as bool?) ?? false,
        downloadPolicy: (m['downloadPolicy'] as String?) ?? 'login',
      );

  /// 로그/디버그용 — 토큰은 앞 6자만(유출 방지, §2-4).
  @override
  String toString() {
    final t = sessionToken.isEmpty
        ? '(none)'
        : '${sessionToken.substring(0, sessionToken.length.clamp(0, 6))}…';
    return 'StoreLoginInfo(token=$t, user=$userId, registered=$registered, '
        'policy=$downloadPolicy)';
  }
}

/// 마켓앱 로그인 연동(안드로이드TV). 네이티브 MethodChannel(app/store_login) 래퍼.
///
/// 안드로이드가 아니면(웹/iOS 등) [read]는 항상 null을 돌려준다 → 모바일 경로 취급.
class StoreLogin {
  StoreLogin._();

  static const MethodChannel _ch = MethodChannel('app/store_login');

  static bool get _supported => !kIsWeb && Platform.isAndroid;

  /// 마켓 provider에서 로그인 세션을 읽는다.
  /// null = 마켓앱 없음(또는 서명키 불일치) → 모바일 경로.
  static Future<StoreLoginInfo?> read() async {
    if (!_supported) return null;
    try {
      final res = await _ch.invokeMethod<dynamic>('read');
      if (res is Map) return StoreLoginInfo.fromMap(res);
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 토큰이 서버에서 유효한지 확인(GET /api/tv/session).
  /// 200=로그인, 401=끊김, -1=네트워크오류(판단 유보).
  static Future<int> verify(String token) async {
    if (!_supported) return 200;
    try {
      final code = await _ch.invokeMethod<int>('verify', {'token': token});
      return code ?? -1;
    } catch (_) {
      return -1;
    }
  }

  /// 마켓 로그인 화면을 연다(viewplus://login?return=<내 패키지>).
  /// 로그인이 끝나면 호출한 앱으로 자동 복귀한다.
  static Future<bool> openStoreLogin() async {
    if (!_supported) return false;
    try {
      return (await _ch.invokeMethod<bool>('openStoreLogin')) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 마켓앱 로그아웃/로그인 변경을 감지한다(ContentObserver).
  /// 변경 시 [onChanged]가 호출된다.
  static Future<void> observe(void Function() onChanged) async {
    if (!_supported) return;
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'onSessionChanged') onChanged();
    });
    try {
      await _ch.invokeMethod('startObserve');
    } catch (_) {}
  }

  static Future<void> stopObserve() async {
    if (!_supported) return;
    try {
      await _ch.invokeMethod('stopObserve');
    } catch (_) {}
  }
}
