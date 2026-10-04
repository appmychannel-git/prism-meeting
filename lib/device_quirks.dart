import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

/// 기기별 보정(quirks). 앱 시작 시 [load]로 1회 판정해 캐시.
///
/// 일부 저가 TV/디스플레이는 카메라 HAL/펌웨어가 `SENSOR_ORIENTATION`(센서
/// 장착 방향)을 180° 틀리게 보고해, 카메라 영상이 **상하 반전**된다. 이 반전은
/// 송출(상대방 화면)에도 그대로 나가며, flutter_webrtc엔 "송출 카메라 회전" API가
/// 없다. 그래서 보내는 기기가 참가자 attribute `camFlip=180`을 알리고, 뷰어(앱·웹)가
/// 그 참가자의 카메라 타일을 180° 회전해 바로잡는다. (근본 해결은 제조사 펌웨어 수정.)
class DeviceQuirks {
  DeviceQuirks._();

  static const MethodChannel _ch = MethodChannel('app/fullscreen');

  static bool _loaded = false;
  static bool _cameraFlip180 = false;

  /// 이 기기의 카메라가 상하(180°) 반전되는가.
  static bool get cameraFlip180 => _cameraFlip180;

  /// 참가자 attribute 키/값(송출 기기가 알리고, 뷰어가 읽어 회전).
  static const String flipAttrKey = 'camFlip';
  static const String flipAttrValue = '180';

  /// 센서 방향을 180° 틀리게 보고하는 기기 목록(manufacturer+model 매칭).
  /// 새 기기가 나오면 여기에만 추가하면 된다(전 기기 영향 없음).
  static const List<Map<String, String>> _flipDevices = [
    {'manufacturer': 'WQi', 'model': 'Gm81'}, // 27" 스탠드형(보드 tb8781p1_64)
  ];

  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      final info = await _ch.invokeMethod<dynamic>('getDeviceInfo');
      if (info is Map) {
        final man = ((info['manufacturer'] as String?) ?? '').trim();
        final mod = ((info['model'] as String?) ?? '').trim();
        _cameraFlip180 = _flipDevices.any(
          (d) => d['manufacturer'] == man && d['model'] == mod,
        );
      }
    } catch (_) {}
  }
}
