import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:http/http.dart' as http;

import 'config.dart';
import 'friends.dart';

/// CCTV 원격 켜기(/cctv-wake) 결과.
enum CctvWakeResult { sent, notFound, offline, error }

/// 이 기기의 CCTV를 추가한 시청자(호스트의 "친구목록"에 표시).
class CctvViewer {
  final String uuid;
  final String name;
  final bool blocked;
  final String lastSeen;
  const CctvViewer({
    required this.uuid,
    required this.name,
    this.blocked = false,
    this.lastSeen = '',
  });
  factory CctvViewer.fromJson(Map j) => CctvViewer(
        uuid: (j['uuid'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        blocked: j['blocked'] == true,
        lastSeen: (j['lastSeen'] ?? '').toString(),
      );
}

/// 상대 기기의 현재 상태(온라인/통화중/이름).
class DeviceStatus {
  final String name;
  final bool inCall;
  final int lastSeenMs;
  const DeviceStatus({
    required this.name,
    required this.inCall,
    required this.lastSeenMs,
  });

  /// 최근 90초 내 heartbeat 가 있으면 온라인으로 본다.
  bool get online =>
      lastSeenMs > 0 &&
      DateTime.now().millisecondsSinceEpoch - lastSeenMs < 90000;

  /// 통화 중 표시(온라인이면서 inCall). 오프라인이면 stale 로 보고 통화중 아님.
  bool get busy => online && inCall;
}

/// 서버(Firestore) 기반 친구 디렉터리.
///  - codes/{code}   : 짧은 코드 → uuid (TV/태블릿 등 스캔 어려운 기기용 수동 등록)
///  - devices/{uuid} : 기기 문서에 code 필드 저장(내 코드 표시용)
///  - edges/{from__to}: "from 이 to 를 친구추가함" → to 의 '친구 추천'(나를 추가한 사람) 근거
class DirectoryService {
  static FirebaseFirestore get _db => FirebaseFirestore.instance;

  // 헷갈리는 문자(0,O,1,I,L) 제외한 코드 알파벳.
  static const _alphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';

  static String _genCode([int len = 6]) {
    // Firestore 문서ID 충돌은 트랜잭션으로 거르므로 여기선 의사난수로 충분.
    final now = DateTime.now().microsecondsSinceEpoch;
    var seed = now;
    final sb = StringBuffer();
    for (var i = 0; i < len; i++) {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      sb.write(_alphabet[seed % _alphabet.length]);
    }
    return sb.toString();
  }

  /// 내 기기의 짧은 코드(없으면 생성·예약). 실패 시 ''.
  static Future<String> ensureCode(String uuid) async {
    try {
      final devRef = _db.collection('devices').doc(uuid);
      final dev = await devRef.get();
      final existing = (dev.data()?['code'] ?? '').toString();
      if (existing.isNotEmpty) return existing;

      for (var i = 0; i < 8; i++) {
        final code = _genCode();
        final codeRef = _db.collection('codes').doc(code);
        final ok = await _db.runTransaction<bool>((tx) async {
          final c = await tx.get(codeRef);
          if (c.exists) return false; // 충돌 → 다른 코드로 재시도
          tx.set(codeRef, {'uuid': uuid});
          tx.set(devRef, {'code': code}, SetOptions(merge: true));
          return true;
        });
        if (ok) return code;
      }
    } catch (_) {}
    return '';
  }

  /// 상대 기기 상태(온라인/통화중/이름) 조회.
  static Future<DeviceStatus?> status(String uuid) async {
    if (uuid.isEmpty) return null;
    try {
      final d = await _db.collection('devices').doc(uuid).get();
      if (!d.exists) return null;
      final m = d.data()!;
      final ls = m['lastSeen'];
      final ms = ls is Timestamp ? ls.millisecondsSinceEpoch : 0;
      return DeviceStatus(
        name: (m['name'] ?? '').toString(),
        inCall: m['inCall'] == true,
        lastSeenMs: ms,
      );
    } catch (_) {
      return null;
    }
  }

  /// 코드로 상대 찾기(수동 등록). 없으면 null.
  static Future<Friend?> lookupCode(String code) async {
    final c = code.trim().toUpperCase();
    if (c.isEmpty) return null;
    try {
      final doc = await _db.collection('codes').doc(c).get();
      final uuid = (doc.data()?['uuid'] ?? '').toString();
      if (uuid.isEmpty) return null;
      final dev = await _db.collection('devices').doc(uuid).get();
      final name = (dev.data()?['name'] ?? '').toString();
      return Friend(uuid: uuid, name: name);
    } catch (_) {
      return null;
    }
  }

  /// "내가 상대를 친구추가함"을 기록 → 상대의 '친구 추천'에 내가 뜬다.
  /// [toName]도 저장해 두면, 재설치 후 내 친구목록을 서버에서 복구할 수 있다.
  static Future<void> addEdge({
    required String from,
    required String to,
    required String fromName,
    String toName = '',
  }) async {
    if (from.isEmpty || to.isEmpty || from == to) return;
    try {
      await _db.collection('edges').doc('${from}__$to').set({
        'from': from,
        'to': to,
        'fromName': fromName,
        'toName': toName,
        'createdAt': FieldValue.serverTimestamp(),
      });
    } catch (_) {}
  }

  /// 친구 삭제 시 서버 관계도 제거(안 그러면 복구 로직이 다시 되살림).
  static Future<void> removeEdge({
    required String from,
    required String to,
  }) async {
    if (from.isEmpty || to.isEmpty) return;
    try {
      await _db.collection('edges').doc('${from}__$to').delete();
    } catch (_) {}
  }

  /// 내가 추가한 친구들(재설치 후 로컬 친구목록 복구용).
  /// from == 나 인 edge 들 → 상대(to)와 저장해둔 이름(toName).
  static Future<List<Friend>> myFriends(String myUuid) async {
    try {
      final q =
          await _db.collection('edges').where('from', isEqualTo: myUuid).get();
      final out = <Friend>[];
      for (final d in q.docs) {
        final m = d.data();
        final uid = (m['to'] ?? '').toString();
        if (uid.isEmpty) continue;
        out.add(Friend(uuid: uid, name: (m['toName'] ?? '').toString()));
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  // ── CCTV 원격 켜기 ──

  /// 이 기기를 "원격 켜기 가능한 CCTV 카메라"로 등록(code → 내 uuid).
  static Future<void> registerCctvCamera({
    required String code,
    required String uuid,
    required String name,
  }) async {
    if (code.isEmpty || uuid.isEmpty) return;
    try {
      await _db.collection('cctvCameras').doc(code).set({
        'uuid': uuid,
        'name': name,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (_) {}
  }

  static Future<void> unregisterCctvCamera(String code) async {
    if (code.isEmpty) return;
    try {
      // uuid 만 제거(원격 켜기 비활성) — 이름은 남겨 둬 시청자 목록 표시에 쓰이게 한다.
      await _db.collection('cctvCameras').doc(code).set({
        'uuid': FieldValue.delete(),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (_) {}
  }

  // 토큰서버의 다른 경로 URL(/token → /<path>).
  static String _endpoint(String path) =>
      AppConfig.tokenServerUrl.replaceFirst(RegExp(r'/token/?$'), '/$path');

  /// 이 기기(코드)의 이름을 디렉터리에 게시(서버 Admin 경유 — 클라는 Firestore 규칙상
  /// cctvCameras 직접 쓰기 제약). 다른 기기가 코드로 추가할 때 이름을 조회할 수 있다.
  static Future<void> setCctvName(String code, String name) async {
    if (code.isEmpty || name.trim().isEmpty) return;
    try {
      await http
          .post(
            Uri.parse(_endpoint('cctv-pins')),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'code': code, 'name': name.trim()}),
          )
          .timeout(const Duration(seconds: 6));
    } catch (_) {}
  }

  /// 코드로 등록된 CCTV 기기의 이름 조회(서버 Admin 경유 — 클라는 Firestore 직접
  /// 못 읽음). QR에 이름이 없을 때(수동 코드 추가) 시청자 목록 표시용 best-effort.
  static Future<String> getCctvCameraName(String code) async {
    if (code.isEmpty) return '';
    try {
      final resp = await http
          .get(Uri.parse('${_endpoint('cctv-name')}?code=$code'))
          .timeout(const Duration(seconds: 6));
      if (resp.statusCode == 200) {
        final j = jsonDecode(resp.body);
        if (j is Map && j['name'] != null) return j['name'].toString();
      }
    } catch (_) {}
    return '';
  }

  /// 시청자가 CCTV를 추가/시청할 때 자신을 호스트의 "친구목록"에 등록(서버 경유).
  static Future<void> registerCctvViewer(
      String code, String uuid, String name) async {
    if (code.isEmpty || uuid.isEmpty) return;
    try {
      await http
          .post(
            Uri.parse(_endpoint('cctv-viewer')),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'code': code, 'uuid': uuid, 'name': name}),
          )
          .timeout(const Duration(seconds: 6));
    } catch (_) {}
  }

  /// 이 기기(code)의 CCTV를 추가한 시청자 목록 조회(호스트용).
  static Future<List<CctvViewer>> listCctvViewers(String code) async {
    if (code.isEmpty) return [];
    try {
      final resp = await http
          .get(Uri.parse('${_endpoint('cctv-viewers')}?code=$code'))
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode == 200) {
        final j = jsonDecode(resp.body);
        final arr = (j is Map ? j['viewers'] : null);
        if (arr is List) {
          return arr
              .whereType<Map>()
              .map((m) => CctvViewer.fromJson(m))
              .where((v) => v.uuid.isNotEmpty)
              .toList();
        }
      }
    } catch (_) {}
    return [];
  }

  /// 시청자 차단/해제(서버가 Firestore에 기록 + 차단 시 즉시 퇴장 시도).
  static Future<bool> setCctvViewerBlocked(
      String code, String uuid, bool blocked) async {
    if (code.isEmpty || uuid.isEmpty) return false;
    try {
      final resp = await http
          .post(
            Uri.parse(_endpoint('cctv-block')),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'code': code, 'uuid': uuid, 'blocked': blocked}),
          )
          .timeout(const Duration(seconds: 8));
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// 시청자가 CCTV 기기를 원격으로 깨운다(토큰서버 /cctv-wake → FCM).
  /// 반환값으로 결과를 알려준다(시청자 화면이 "방없음" 안내를 바로 띄우기 위함):
  ///  - [CctvWakeResult.sent]         깨우기 신호 전송됨(기기가 곧 송출 시작 기대)
  ///  - [CctvWakeResult.notFound]     등록된 CCTV가 없음(코드 만료/삭제) → 방없음
  ///  - [CctvWakeResult.offline]      기기 오프라인(토큰 없음)
  ///  - [CctvWakeResult.error]        네트워크/서버 오류(판단 불가 → 재시도 여지)
  static Future<CctvWakeResult> requestCctvWake(String code,
      {String? pin, String? uuid}) async {
    final url =
        AppConfig.tokenServerUrl.replaceFirst(RegExp(r'/token/?$'), '/cctv-wake');
    try {
      final payload = <String, String>{'code': code};
      // 서버가 깨우기 전에 차단/비번을 검사하도록 함께 보낸다(불필요한 송출 켜짐 방지).
      if (pin != null && pin.isNotEmpty) payload['pin'] = pin;
      if (uuid != null && uuid.isNotEmpty) payload['uuid'] = uuid;
      final resp = await http
          .post(
            Uri.parse(url),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode == 200) return CctvWakeResult.sent;
      // 차단/비번 불일치(403): 깨우지 않음 → 시청자는 "방없음"으로 안내.
      if (resp.statusCode == 403) return CctvWakeResult.notFound;
      if (resp.statusCode == 404) {
        // 서버 메시지로 "기기 없음(코드 만료/삭제)"과 "오프라인"을 구분.
        var msg = '';
        try {
          final j = jsonDecode(resp.body);
          if (j is Map && j['error'] != null) msg = j['error'].toString();
        } catch (_) {}
        return msg.contains('오프라인')
            ? CctvWakeResult.offline
            : CctvWakeResult.notFound;
      }
      return CctvWakeResult.error;
    } catch (_) {
      return CctvWakeResult.error;
    }
  }

  /// CCTV 공유 비번(그룹) 집합을 서버 방 메타데이터에 **즉시** 반영한다(방 삭제 없이).
  /// 송출 중이거나 방이 아직 잔존(EMPTY_SEC)할 때 그룹 토글/삭제/비번변경이 바로 적용돼,
  /// 비활성/삭제된 비번으로는 새 시청자가 들어오지 못한다. 방이 없으면 서버가 무시(noop).
  /// 실패해도 예외 없음(다음 송출 때 카메라가 어차피 자기 비번을 재지정).
  /// 서버는 (1) 방이 있으면 메타데이터 비번 즉시 갱신, (2) Firestore cctvCameras 에
  /// 비번(+이름)을 저장해 카메라가 꺼져 있어도 원격 깨우기 때 비번 대조에 쓴다.
  static Future<void> updateCctvPins(String code, List<String> pins,
      {String? name}) async {
    if (code.isEmpty) return;
    try {
      final payload = <String, dynamic>{'code': code, 'pins': pins};
      if (name != null && name.trim().isNotEmpty) payload['name'] = name.trim();
      await http
          .post(
            Uri.parse(_endpoint('cctv-pins')),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 8));
    } catch (_) {}
  }

  /// 나를 친구추가한 사람들(단일 equality 쿼리 → 복합색인 불필요).
  static Future<List<Friend>> whoAddedMe(String myUuid) async {
    try {
      final q =
          await _db.collection('edges').where('to', isEqualTo: myUuid).get();
      final out = <Friend>[];
      for (final d in q.docs) {
        final m = d.data();
        final uid = (m['from'] ?? '').toString();
        if (uid.isEmpty) continue;
        out.add(Friend(uuid: uid, name: (m['fromName'] ?? '').toString()));
      }
      return out;
    } catch (_) {
      return [];
    }
  }
}
