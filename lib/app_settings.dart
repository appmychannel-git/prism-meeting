import 'package:shared_preferences/shared_preferences.dart';

/// 사용자 설정(로컬 저장). 앱 시작 시 [load] 로 읽어 캐시.
class AppSettings {
  static const _kRequireAccept = 'require_accept';

  /// 수락형 친구요청: on이면 "내 친구가 아닌 사람"의 전화를 자동 거절.
  /// 기본 off(아무나 내 QR/코드로 전화 가능).
  static bool _requireAccept = false;
  static bool get requireAccept => _requireAccept;

  static Future<void> load() async {
    final sp = await SharedPreferences.getInstance();
    _requireAccept = sp.getBool(_kRequireAccept) ?? false;
  }

  static Future<void> setRequireAccept(bool v) async {
    _requireAccept = v;
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_kRequireAccept, v);
  }
}
