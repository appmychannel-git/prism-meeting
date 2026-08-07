import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// 기기 고유 식별자(UUID) + 프로필 이름을 영구 저장한다.
///
/// 회원(로그인) 없이 이 UUID로 사용자를 식별한다(친구·통화용).
/// - 최초 실행 시 UUIDv4 생성 → SharedPreferences에 영구 보관.
/// - PC/웹 포함 모든 플랫폼 동일(하드웨어 ID 대신 랜덤 UUID).
///   (Phase 2에서 서버 중복확인 후 등록 예정. UUIDv4라 충돌확률 ~0.)
class DeviceId {
  static const _kUuid = 'device_uuid';
  static const _kName = 'profile_name';
  static String? _cachedUuid;

  /// 이 기기의 영구 UUID. 없으면 생성해 저장.
  static Future<String> uuid() async {
    if (_cachedUuid != null) return _cachedUuid!;
    final sp = await SharedPreferences.getInstance();
    var id = sp.getString(_kUuid);
    if (id == null || id.isEmpty) {
      id = const Uuid().v4();
      await sp.setString(_kUuid, id);
    }
    _cachedUuid = id;
    return id;
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
