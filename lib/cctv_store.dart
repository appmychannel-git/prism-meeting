import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import 'config.dart';

/// 저장된 CCTV(시청 목록) 한 건.
class CctvEntry {
  final String code; // cctv- 제외한 코드
  final String pin;
  final String name;
  const CctvEntry({required this.code, required this.pin, required this.name});

  Map<String, dynamic> toJson() => {'code': code, 'pin': pin, 'name': name};
  factory CctvEntry.fromJson(Map<String, dynamic> j) => CctvEntry(
        code: (j['code'] ?? '').toString(),
        pin: (j['pin'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
      );

  String get roomId => 'cctv-$code';
}

/// CCTV 로컬 저장: ① 내 공유 기기의 고정 코드/비번 ② 시청 목록.
class CctvStore {
  static const _kMyCode = 'cctv_my_code';
  static const _kMyPin = 'cctv_my_pin';
  static const _kSaved = 'cctv_saved';
  static const _kIsCamera = 'cctv_is_camera';

  /// 이 기기가 "대기 중 원격 켜기 가능한 CCTV 카메라"로 등록됐는지.
  static Future<bool> isCamera() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getBool(_kIsCamera) ?? false;
  }

  static Future<void> setIsCamera(bool v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_kIsCamera, v);
  }

  // ── 원격 켜기 대기 플래그 ──
  // 백그라운드 FCM 핸들러(다른 isolate)가 기록 → 앱이 앞으로 오면(resume/시작)
  // 이 플래그를 보고 송출 화면으로 이동한다(onMessage 가 백그라운드에선 안 오므로).
  static const _kWakePending = 'cctv_wake_pending_ms';

  static Future<void> setPendingWake() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setInt(_kWakePending, DateTime.now().millisecondsSinceEpoch);
  }

  /// 최근(60초 내) 대기 플래그가 있으면 true 반환하고 즉시 소거.
  static Future<bool> consumePendingWake() async {
    final sp = await SharedPreferences.getInstance();
    await sp.reload(); // 백그라운드 isolate 가 쓴 값 반영
    final ms = sp.getInt(_kWakePending) ?? 0;
    if (ms == 0) return false;
    await sp.remove(_kWakePending);
    return DateTime.now().millisecondsSinceEpoch - ms < 60000;
  }

  /// 이 기기를 CCTV로 공유할 때 쓰는 **고정** 코드/비번(최초 1회 생성 후 유지).
  static Future<(String code, String pin)> myShareCredentials() async {
    final sp = await SharedPreferences.getInstance();
    var code = sp.getString(_kMyCode);
    var pin = sp.getString(_kMyPin);
    if (code == null || code.isEmpty) {
      code = AppConfig.generateRoomCode();
      // 보안 강화: 6자리(1,000,000가지). 4자리는 무차별 대입에 취약.
      pin = (100000 + Random().nextInt(900000)).toString();
      await sp.setString(_kMyCode, code);
      await sp.setString(_kMyPin, pin);
    }
    return (code, pin ?? '');
  }

  // ── 시청 목록 ──
  static Future<List<CctvEntry>> list() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_kSaved);
    if (raw == null || raw.isEmpty) return [];
    try {
      final arr = jsonDecode(raw) as List;
      return arr
          .map((e) => CctvEntry.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> _save(List<CctvEntry> items) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(
        _kSaved, jsonEncode(items.map((e) => e.toJson()).toList()));
  }

  /// 시청 목록에 추가/갱신(코드 기준). 다음부턴 목록에서 원터치 시청.
  static Future<void> add(CctvEntry e) async {
    final items = await list();
    final i = items.indexWhere((x) => x.code == e.code);
    if (i >= 0) {
      items[i] = e;
    } else {
      items.add(e);
    }
    await _save(items);
  }

  static Future<void> remove(String code) async {
    final items = await list();
    items.removeWhere((x) => x.code == code);
    await _save(items);
  }
}
