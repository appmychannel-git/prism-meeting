import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'config.dart';

/// 저장된 CCTV(시청 목록) 한 건.
class CctvEntry {
  final String code; // cctv- 제외한 코드
  final String pin;
  final String name;
  final String note; // 사용자 메모(목록 둘째 줄). 비면 코드를 대신 표시.
  const CctvEntry({
    required this.code,
    required this.pin,
    required this.name,
    this.note = '',
  });

  Map<String, dynamic> toJson() =>
      {'code': code, 'pin': pin, 'name': name, 'note': note};
  factory CctvEntry.fromJson(Map<String, dynamic> j) => CctvEntry(
        code: (j['code'] ?? '').toString(),
        pin: (j['pin'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        note: (j['note'] ?? '').toString(),
      );

  CctvEntry copyWith({String? name, String? note, String? pin}) => CctvEntry(
        code: code,
        pin: pin ?? this.pin,
        name: name ?? this.name,
        note: note ?? this.note,
      );

  String get roomId => 'cctv-$code';
}

/// 공유(송출) 접속 그룹 — 같은 기기 코드(방)에 대해 그룹별로 다른 비번을 둔다.
/// 그룹마다 QR(기기코드+그 비번)을 발급해 특정 그룹만 활성/비활성/삭제할 수 있다.
class CctvShareGroup {
  final String id;
  final String name;
  final String pin;
  final bool enabled;
  const CctvShareGroup({
    required this.id,
    required this.name,
    required this.pin,
    this.enabled = true,
  });

  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'pin': pin, 'enabled': enabled};
  factory CctvShareGroup.fromJson(Map<String, dynamic> j) => CctvShareGroup(
        id: (j['id'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        pin: (j['pin'] ?? '').toString(),
        enabled: j['enabled'] != false, // 기본 활성
      );

  CctvShareGroup copyWith({String? name, String? pin, bool? enabled}) =>
      CctvShareGroup(
        id: id,
        name: name ?? this.name,
        pin: pin ?? this.pin,
        enabled: enabled ?? this.enabled,
      );
}

/// CCTV 로컬 저장: ① 내 공유 기기의 고정 코드 + 접속 그룹(비번들) ② 시청 목록.
class CctvStore {
  static const _kMyCode = 'cctv_my_code';
  static const _kMyPin = 'cctv_my_pin';
  static const _kSaved = 'cctv_saved';
  static const _kIsCamera = 'cctv_is_camera';
  static const _kShareGroups = 'cctv_share_groups';

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

  /// 이 기기를 CCTV로 공유할 때 쓰는 **고정 코드** + **사용자가 설정한 비번**.
  /// 코드는 최초 1회 생성 후 유지. 비번은 송출 화면에서 사용자가 직접 설정하며,
  /// 아직 설정 전이면 빈 문자열(''). (과거 자동 생성된 비번이 있으면 그대로 반환)
  static Future<(String code, String pin)> myShareCredentials() async {
    final sp = await SharedPreferences.getInstance();
    var code = sp.getString(_kMyCode);
    if (code == null || code.isEmpty) {
      code = AppConfig.generateRoomCode();
      await sp.setString(_kMyCode, code);
    }
    final pin = sp.getString(_kMyPin) ?? '';
    return (code, pin);
  }

  /// 공유 비밀번호 설정/변경(과거 단일 비번 호환용). 신규 UI는 그룹을 쓴다.
  static Future<void> setMyPin(String pin) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kMyPin, pin);
  }

  /// 이 기기 공유 코드 재발급(새 코드로 교체). 그룹(비번)은 유지 → QR만 새 코드로
  /// 재생성된다. 기존 코드/QR은 모두 무효가 되므로 시청자는 새 QR로 다시 등록해야 한다.
  static Future<String> reissueMyCode() async {
    final sp = await SharedPreferences.getInstance();
    final code = AppConfig.generateRoomCode();
    await sp.setString(_kMyCode, code);
    return code;
  }

  // ── 공유(송출) 접속 그룹 ──
  static String _newGroupId() =>
      DateTime.now().microsecondsSinceEpoch.toString();

  /// 접속 그룹 목록. 저장된 게 없고 과거 단일 비번만 있으면 "기본" 그룹으로 이관.
  static Future<List<CctvShareGroup>> shareGroups() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_kShareGroups);
    if (raw != null && raw.isNotEmpty) {
      try {
        final arr = jsonDecode(raw) as List;
        return arr
            .map((e) => CctvShareGroup.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (_) {}
    }
    // 마이그레이션: 과거 단일 비번(setMyPin)이 있으면 "기본" 그룹 1개로.
    final oldPin = sp.getString(_kMyPin) ?? '';
    if (oldPin.isNotEmpty) {
      final g = CctvShareGroup(id: _newGroupId(), name: '기본', pin: oldPin);
      await _saveGroups([g]);
      return [g];
    }
    return [];
  }

  static Future<void> _saveGroups(List<CctvShareGroup> gs) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(
        _kShareGroups, jsonEncode(gs.map((g) => g.toJson()).toList()));
  }

  static Future<void> addShareGroup(String name, String pin) async {
    final gs = await shareGroups();
    gs.add(CctvShareGroup(id: _newGroupId(), name: name, pin: pin));
    await _saveGroups(gs);
  }

  static Future<void> updateShareGroup(String id,
      {String? name, String? pin, bool? enabled}) async {
    final gs = await shareGroups();
    final i = gs.indexWhere((g) => g.id == id);
    if (i < 0) return;
    gs[i] = gs[i].copyWith(name: name, pin: pin, enabled: enabled);
    await _saveGroups(gs);
  }

  static Future<void> removeShareGroup(String id) async {
    final gs = await shareGroups();
    gs.removeWhere((g) => g.id == id);
    await _saveGroups(gs);
  }

  /// 현재 "활성" 그룹들의 비번(송출 시 서버로 보낼 유효 비번 집합).
  /// 첫(기본) 그룹은 비활성/삭제가 불가하므로 항상 포함한다.
  static Future<List<String>> enabledSharePins() async {
    final gs = await shareGroups();
    final pins = <String>[];
    for (var i = 0; i < gs.length; i++) {
      final g = gs[i];
      if (g.pin.isEmpty) continue;
      if (i == 0 || g.enabled) pins.add(g.pin); // 기본(첫) 그룹은 항상 포함
    }
    return pins;
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
