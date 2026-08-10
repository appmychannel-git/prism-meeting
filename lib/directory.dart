import 'package:cloud_firestore/cloud_firestore.dart';

import 'friends.dart';

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
