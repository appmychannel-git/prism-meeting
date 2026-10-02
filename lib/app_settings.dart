import 'package:shared_preferences/shared_preferences.dart';

import 'config.dart';

/// 사용자 설정(로컬 저장). 앱 시작 시 [load] 로 읽어 캐시.
class AppSettings {
  static const _kRequireAccept = 'require_accept';
  static const _kStartCamera = 'start_camera_on_join';

  /// 수락형 친구요청: on이면 "내 친구가 아닌 사람"의 전화를 자동 거절.
  /// 기본 off(아무나 내 QR/코드로 전화 가능).
  static bool _requireAccept = false;
  static bool get requireAccept => _requireAccept;

  /// 입장 시 카메라 자동 켜기. 기본값은 빌드 플래그([AppConfig.startCamera]).
  /// 카메라가 고장났거나(도킹캠 제거 등) USB캠만 있는 기기(예: 27" 스탠드TV)는
  /// 자동 켜기가 네이티브 카메라 open에서 멈춰(ANR) 앱이 굳으므로, 그런 기기에선
  /// 이 설정을 꺼 두면 입장이 멈추지 않는다(입장 후 필요 시 수동 켜기).
  static bool _startCameraOnJoin = AppConfig.startCamera;
  static bool get startCameraOnJoin => _startCameraOnJoin;

  static Future<void> load() async {
    final sp = await SharedPreferences.getInstance();
    _requireAccept = sp.getBool(_kRequireAccept) ?? false;
    _startCameraOnJoin = sp.getBool(_kStartCamera) ?? AppConfig.startCamera;
  }

  static Future<void> setRequireAccept(bool v) async {
    _requireAccept = v;
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_kRequireAccept, v);
  }

  static Future<void> setStartCameraOnJoin(bool v) async {
    _startCameraOnJoin = v;
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_kStartCamera, v);
  }
}
