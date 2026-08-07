import 'package:cloud_firestore/cloud_firestore.dart';

import 'friends.dart';

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
  static Future<void> addEdge({
    required String from,
    required String to,
    required String fromName,
  }) async {
    if (from.isEmpty || to.isEmpty || from == to) return;
    try {
      await _db.collection('edges').doc('${from}__$to').set({
        'from': from,
        'to': to,
        'fromName': fromName,
        'createdAt': FieldValue.serverTimestamp(),
      });
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
