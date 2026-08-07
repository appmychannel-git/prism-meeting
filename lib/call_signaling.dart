import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:http/http.dart' as http;

import 'config.dart';

/// 통화 상태.
/// ringing  : 발신됨, 상대 응답 대기
/// accepted : 상대가 수락 → 양쪽 방 입장
/// declined : 상대가 거절
/// canceled : 발신자가 취소 / 응답없음(타임아웃)
/// ended    : 통화 종료
class CallStatus {
  static const ringing = 'ringing';
  static const accepted = 'accepted';
  static const declined = 'declined';
  static const canceled = 'canceled';
  static const ended = 'ended';
}

/// Firestore `calls/{callId}` 문서 모델.
class CallDoc {
  final String callId;
  final String fromUuid;
  final String fromName;
  final String toUuid;
  final String room;
  final bool video;
  final String status;
  final int startedAtMs;

  const CallDoc({
    required this.callId,
    required this.fromUuid,
    required this.fromName,
    required this.toUuid,
    required this.room,
    required this.video,
    required this.status,
    required this.startedAtMs,
  });

  static CallDoc? fromMap(Map<String, dynamic>? m) {
    if (m == null) return null;
    final id = (m['callId'] ?? '').toString();
    if (id.isEmpty) return null;
    return CallDoc(
      callId: id,
      fromUuid: (m['fromUuid'] ?? '').toString(),
      fromName: (m['fromName'] ?? '').toString(),
      toUuid: (m['toUuid'] ?? '').toString(),
      room: (m['room'] ?? '').toString(),
      video: m['video'] == true || m['video'] == 'true',
      status: (m['status'] ?? '').toString(),
      startedAtMs: (m['startedAtMs'] is int)
          ? m['startedAtMs'] as int
          : int.tryParse('${m['startedAtMs']}') ?? 0,
    );
  }
}

/// 통화 시그널링 — 통화 상태를 Firestore 로 주고받는다.
/// (실제 "벨"을 울리는 푸시 전송은 토큰 서버 /call 이 담당. [sendPush])
class CallSignaling {
  /// 통화 유효 시간(ms). 이 시간이 지난 ringing 문서는 무시(오래된 벨 재울림 방지).
  static const int ringTtlMs = 60000;

  static CollectionReference<Map<String, dynamic>> get _calls =>
      FirebaseFirestore.instance.collection('calls');

  /// 발신: 통화 문서 생성(상태 ringing).
  static Future<void> createCall({
    required String callId,
    required String fromUuid,
    required String fromName,
    required String toUuid,
    required String room,
    required bool video,
    required int startedAtMs,
  }) async {
    await _calls.doc(callId).set({
      'callId': callId,
      'fromUuid': fromUuid,
      'fromName': fromName,
      'toUuid': toUuid,
      'room': room,
      'video': video,
      'status': CallStatus.ringing,
      'startedAtMs': startedAtMs,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  /// 통화 문서 변화 구독(수락/거절/취소 감지).
  static Stream<CallDoc?> watch(String callId) =>
      _calls.doc(callId).snapshots().map((s) => CallDoc.fromMap(s.data()));

  /// 상태 변경(수락/거절/취소/종료).
  static Future<void> setStatus(String callId, String status) async {
    try {
      await _calls.doc(callId).update({'status': status});
    } catch (_) {
      // 문서가 없거나 권한 문제여도 로컬 흐름은 계속 진행.
    }
  }

  /// 나에게 온 수신 통화 스트림(앱이 떠 있을 때의 1차 벨 — 포그라운드/백그라운드 복귀).
  /// toUuid 단일 equality 쿼리라 복합 색인이 필요 없다. 상태·유효시간은 코드에서 필터.
  static Stream<CallDoc> incoming(String myUuid) {
    return _calls
        .where('toUuid', isEqualTo: myUuid)
        .snapshots()
        .expand((snap) sync* {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      for (final ch in snap.docChanges) {
        if (ch.type != DocumentChangeType.added &&
            ch.type != DocumentChangeType.modified) {
          continue;
        }
        final c = CallDoc.fromMap(ch.doc.data());
        if (c == null) continue;
        if (c.status != CallStatus.ringing) continue;
        if (c.startedAtMs > 0 && nowMs - c.startedAtMs > ringTtlMs) continue;
        yield c;
      }
    });
  }

  /// 토큰 서버 /call 호출 → 상대 기기로 FCM 푸시(벨) 전송.
  /// 실패해도 예외를 던지지 않는다(포그라운드 상대는 [incoming] 스트림으로도 울림).
  static Future<void> sendPush({
    required String callId,
    required String fromUuid,
    required String fromName,
    required String toUuid,
    required String room,
    required bool video,
  }) async {
    final callUrl =
        AppConfig.tokenServerUrl.replaceFirst(RegExp(r'/token/?$'), '/call');
    try {
      await http
          .post(
            Uri.parse(callUrl),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'callId': callId,
              'fromUuid': fromUuid,
              'fromName': fromName,
              'toUuid': toUuid,
              'room': room,
              'video': video,
            }),
          )
          .timeout(const Duration(seconds: 8));
    } catch (_) {
      // 무시(위 주석 참고).
    }
  }
}
