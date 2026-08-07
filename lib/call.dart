import 'package:flutter/material.dart';

import 'config.dart';
import 'connection_service.dart';
import 'friends.dart';
import 'l10n.dart';
import 'room_screen.dart';

/// 친구에게 1:1 전화(DM 방)로 연결한다.
/// 방 이름은 두 UUID를 정렬해 만들어 양쪽이 같은 방으로 들어간다.
///
/// Phase 1: 상대에게 "벨"이 울리진 않는다(둘 다 걸거나 상대가 목록에서 들어와야 만남).
/// Phase 2(FCM)에서 발신 시 상대에게 푸시 수신벨 → 수락 시 자동 입장으로 확장.
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

  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const Center(child: CircularProgressIndicator()),
  );

  ConnectionDetails? details;
  String? err;
  try {
    // 이미 방이 있으면 참여, 없으면 생성(먼저 건 사람이 만든다).
    try {
      details = await _fetch(room, name, myUuid, create: false);
    } catch (_) {
      details = await _fetch(room, name, myUuid, create: true);
    }
  } catch (e) {
    err = e.toString().replaceFirst('Exception: ', '');
  }

  if (!context.mounted) return;
  Navigator.of(context).pop(); // 로딩 닫기
  if (details == null) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(err ?? 'error')));
    return;
  }
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => RoomScreen(
        details: details!,
        roomName: room,
        displayName: name,
        startVideo: video,
      ),
    ),
  );
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
