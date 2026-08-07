import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import 'call_signaling.dart';
import 'config.dart';
import 'connection_service.dart';
import 'friends.dart';
import 'l10n.dart';
import 'outgoing_call_screen.dart';
import 'room_screen.dart';

/// 친구에게 1:1 전화를 건다.
/// 방 이름은 두 UUID를 정렬해 만들어 양쪽이 같은 방으로 들어간다.
///
/// Phase 2 흐름:
///  1) Firestore `calls/{callId}` 문서 생성(ringing)
///  2) 토큰 서버 /call → 상대 기기로 FCM 벨 전송
///  3) 발신 화면([OutgoingCallScreen])에서 수락 대기 → 수락 시 방 입장
Future<void> startDmCall(
  BuildContext context, {
  required String myUuid,
  required String myName,
  required Friend friend,
  required bool video,
}) async {
  final ids = [myUuid, friend.uuid]..sort();
  final room = 'dm-${ids.join('-')}';
  final name = myName.isNotEmpty ? myName : L.t('guest');
  final callId = const Uuid().v4();
  final startedAtMs = DateTime.now().millisecondsSinceEpoch;

  try {
    await CallSignaling.createCall(
      callId: callId,
      fromUuid: myUuid,
      fromName: name,
      toUuid: friend.uuid,
      room: room,
      video: video,
      startedAtMs: startedAtMs,
    );
  } catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${L.t('call_failed')}: $e')),
    );
    return;
  }

  // 벨 전송(실패해도 발신 화면은 진행 — 상대가 포그라운드면 Firestore로 울림).
  CallSignaling.sendPush(
    callId: callId,
    fromUuid: myUuid,
    fromName: name,
    toUuid: friend.uuid,
    room: room,
    video: video,
  );

  if (!context.mounted) return;
  Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => OutgoingCallScreen(
      callId: callId,
      room: room,
      myUuid: myUuid,
      myName: name,
      friend: friend,
      video: video,
    ),
  ));
}

/// DM 방 입장(발신자 수락 확인 후 / 수신자 수락 시 공통).
/// 방이 없으면 만들고(먼저 들어온 쪽이 생성), 있으면 참여한다.
/// [replace] true 면 현재 화면(발신/수신)을 방 화면으로 교체.
Future<void> joinDmRoom(
  BuildContext context, {
  required String room,
  required String name,
  required String uuid,
  required bool video,
  bool replace = true,
}) async {
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const Center(child: CircularProgressIndicator()),
  );

  ConnectionDetails? details;
  String? err;
  try {
    try {
      details = await _fetch(room, name, uuid, create: false);
    } catch (_) {
      details = await _fetch(room, name, uuid, create: true);
    }
  } catch (e) {
    err = e.toString().replaceFirst('Exception: ', '');
  }

  if (!context.mounted) return;
  Navigator.of(context).pop(); // 로딩 닫기
  if (details == null) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(err ?? L.t('call_failed'))));
    return;
  }

  final route = MaterialPageRoute<void>(
    builder: (_) => RoomScreen(
      details: details!,
      roomName: room,
      displayName: name,
      startVideo: video,
    ),
  );
  if (replace) {
    Navigator.of(context).pushReplacement(route);
  } else {
    Navigator.of(context).push(route);
  }
}

Future<ConnectionDetails> _fetch(
  String room,
  String name,
  String uuid, {
  required bool create,
}) {
  return ConnectionService.fetchFromServer(
    tokenServerUrl: AppConfig.tokenServerUrl,
    roomName: room,
    participantName: name,
    identity: uuid,
    pin: '',
    create: create,
  );
}
