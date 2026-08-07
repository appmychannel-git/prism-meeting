import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

import 'config.dart';

/// 친구 한 명(회원 없음 → 기기 UUID로 식별).
class Friend {
  final String uuid;
  final String name;
  const Friend({required this.uuid, required this.name});
  Map<String, dynamic> toJson() => {'uuid': uuid, 'name': name};
  factory Friend.fromJson(Map<String, dynamic> j) => Friend(
        uuid: (j['uuid'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
      );
}

/// 친구 목록 로컬 저장(SharedPreferences). Phase 2에서 서버 동기화 추가 예정.
class FriendStore {
  static const _key = 'friends';

  static Future<List<Friend>> list() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final arr = jsonDecode(raw) as List;
      return arr
          .map((e) => Friend.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> _save(List<Friend> fs) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_key, jsonEncode(fs.map((f) => f.toJson()).toList()));
  }

  static Future<bool> isFriend(String uuid) async =>
      (await list()).any((f) => f.uuid == uuid);

  static Future<void> add(Friend f) async {
    final fs = await list();
    final i = fs.indexWhere((x) => x.uuid == f.uuid);
    if (i >= 0) {
      fs[i] = f; // 이름 갱신
    } else {
      fs.add(f);
    }
    await _save(fs);
  }

  static Future<void> remove(String uuid) async {
    final fs = await list();
    fs.removeWhere((f) => f.uuid == uuid);
    await _save(fs);
  }
}

/// 내 ID QR 페이로드. 초대 링크처럼 URL 형태로 만들어 두면 나중에
/// (Phase 2) 외부 카메라로 스캔 시 딥링크로 앱 열기까지 확장 가능.
class IdPayload {
  static String encode(String uuid, String name) {
    final q = Uri(queryParameters: {
      'uid': uuid,
      if (name.isNotEmpty) 'name': name,
    }).query;
    return '${AppConfig.inviteBaseUrl}?$q';
  }

  /// 스캔 문자열에서 친구 정보 추출(uid 필수). 형식 안 맞으면 null.
  static Friend? parse(String scanned) {
    try {
      final u = Uri.parse(scanned.trim());
      final uid = u.queryParameters['uid'];
      if (uid != null && uid.isNotEmpty) {
        return Friend(uuid: uid, name: u.queryParameters['name'] ?? '');
      }
    } catch (_) {}
    return null;
  }
}
