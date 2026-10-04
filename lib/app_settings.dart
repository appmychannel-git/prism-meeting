import 'package:shared_preferences/shared_preferences.dart';

import 'config.dart';
import 'device_quirks.dart';

/// 사용자 설정(로컬 저장). 앱 시작 시 [load] 로 읽어 캐시.
class AppSettings {
  static const _kRequireAccept = 'require_accept';
  static const _kStartCamera = 'start_camera_on_join';
  static const _kCameraFlip180 = 'camera_flip_180';

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

  /// 내 카메라를 180° 상하 반전해서 내보낼지(참가자 attribute camFlip=180).
  /// 기본값은 기기 자동 판정([DeviceQuirks.cameraFlip180]). 사용자가 토글하면
  /// 그 값이 우선한다 → 목록에 없는 반전 기기를 켜거나, 같은 모델이지만 정상인
  /// 개체를 끌 수 있다. "카메라가 거꾸로 나올 때만" 켠다(정상 기기가 켜면 거꾸로 송출됨).
  /// 켜면 내 화면과 모든 뷰어가 내 타일을 180° 회전해 본다.
  static bool _cameraFlip180 = false;
  static bool get cameraFlip180 => _cameraFlip180;

  static Future<void> load() async {
    final sp = await SharedPreferences.getInstance();
    _requireAccept = sp.getBool(_kRequireAccept) ?? false;
    _startCameraOnJoin = sp.getBool(_kStartCamera) ?? AppConfig.startCamera;
    // 저장값 없으면 기기 자동 판정값을 기본으로.
    _cameraFlip180 = sp.getBool(_kCameraFlip180) ?? DeviceQuirks.cameraFlip180;
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

  static Future<void> setCameraFlip180(bool v) async {
    _cameraFlip180 = v;
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_kCameraFlip180, v);
  }
}
