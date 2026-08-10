import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// 기기 고유 식별자(UUID) + 프로필 이름을 영구 저장한다.
///
/// 회원(로그인) 없이 이 값으로 사용자를 식별한다(친구·통화용).
/// - 안드로이드: 최초 실행 시 **ANDROID_ID** 기반 값 사용 → 앱을 삭제·재설치해도
///   동일(공장초기화 시에만 변경). 친구·신원이 재설치에도 유지된다.
/// - 그 외(iOS/PC/웹) 또는 ANDROID_ID 획득 실패: 랜덤 UUIDv4로 대체.
/// - 한번 정해진 값은 SharedPreferences 에 캐시(업데이트 시 그대로 유지).
class DeviceId {
  static const _kUuid = 'device_uuid';
  static const _kName = 'profile_name';
  static const _native = MethodChannel('app/fullscreen');
  static String? _cachedUuid;

  /// 이 기기의 영구 식별값. 없으면 안정적 값(ANDROID_ID)으로 생성해 저장.
  static Future<String> uuid() async {
    if (_cachedUuid != null) return _cachedUuid!;
    final sp = await SharedPreferences.getInstance();
    var id = sp.getString(_kUuid);
    if (id == null || id.isEmpty) {
      id = await _stableId();
      await sp.setString(_kUuid, id);
    }
    _cachedUuid = id;
    return id;
  }

  /// 재설치에도 유지되는 안정 식별값. 안드로이드=ANDROID_ID, 실패 시 랜덤.
  ///
  /// ⚠️ ANDROID_ID는 (앱 서명키+기기) 기준이라, 같은 키로 서명한 여러 브랜드 앱
  /// (프리즘/글로벌전자/뷰플러스/마이채널)을 한 폰에 깔면 값이 동일하다.
  /// → 패키지명(브랜드)을 덧붙여 브랜드별로 신원을 분리한다(친구망도 분리).
  /// 패키지명·ANDROID_ID 둘 다 재설치에도 불변이라 "재설치 유지"는 그대로.
  static Future<String> _stableId() async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      try {
        final aid = await _native.invokeMethod<String>('getAndroidId');
        // 9774d56d682e549c: 일부 구형기기의 알려진 불량 ANDROID_ID → 제외.
        if (aid != null &&
            aid.isNotEmpty &&
            aid != '9774d56d682e549c') {
          final brand = await _brandKey();
          return brand.isEmpty ? 'a$aid' : 'a${aid}_$brand';
        }
      } catch (_) {}
    }
    return const Uuid().v4();
  }

  /// 브랜드 구분자(패키지명에서 안전한 문자만). 예: kr.co.mychannel.meeting.prism
  /// → krcomychannelmeetingprism. 브랜드마다 applicationId가 달라 값이 갈린다.
  static Future<String> _brandKey() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return info.packageName.replaceAll(RegExp('[^a-zA-Z0-9]'), '');
    } catch (_) {
      return '';
    }
  }

  /// 프로필 표시 이름(친구에게 보일 이름). 없으면 빈 문자열.
  static Future<String> name() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getString(_kName) ?? '';
  }

  static Future<void> setName(String name) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kName, name.trim());
  }
}
