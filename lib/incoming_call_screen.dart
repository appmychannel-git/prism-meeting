import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:vibration/vibration.dart';

import 'call.dart';
import 'call_log.dart';
import 'call_signaling.dart';
import 'device_id.dart';
import 'l10n.dart';
import 'push_service.dart';

/// 수신 통화 화면 — 상대가 나에게 전화를 걸었을 때 표시.
/// 수락 → DM 방 입장, 거절 → 상태 갱신 후 닫기.
/// 발신자가 취소하면(상태 canceled) 자동으로 닫힌다.
class IncomingCallScreen extends StatefulWidget {
  final String callId;
  final String fromUuid;
  final String fromName;
  final String room;
  final bool video;

  const IncomingCallScreen({
    super.key,
    required this.callId,
    required this.fromUuid,
    required this.fromName,
    required this.room,
    required this.video,
  });

  @override
  State<IncomingCallScreen> createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends State<IncomingCallScreen> {
  StreamSubscription? _sub;
  bool _answering = false;
  bool _closed = false;
  final AudioPlayer _ringtone = AudioPlayer();

  Future<void> _startRing() async {
    try {
      await _ringtone.setReleaseMode(ReleaseMode.loop); // 계속 반복
      // 알람 스트림으로 라우팅 → 미디어 음량과 무관하게 크게(앱 꺼졌을 때 알림과 동일 크기).
      await _ringtone.setAudioContext(AudioContext(
        android: const AudioContextAndroid(
          isSpeakerphoneOn: false,
          contentType: AndroidContentType.sonification,
          usageType: AndroidUsageType.alarm,
          audioFocus: AndroidAudioFocus.gainTransientMayDuck,
        ),
      ));
      await _ringtone.setVolume(1.0);
      await _ringtone.play(AssetSource('sounds/ring_classic.wav'), volume: 1.0);
    } catch (_) {}
    // 진동도 함께 반복(대기 0.8s, 진동 0.6s 패턴 루프).
    try {
      if (await Vibration.hasVibrator()) {
        Vibration.vibrate(pattern: const [0, 600, 800], repeat: 0);
      }
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    // 풀스크린 알림으로 진입한 경우, 그 알림은 제거(화면이 대신 표시).
    cancelIncomingCallNotification();
    // 수신 벨을 계속(반복) 울린다.
    _startRing();
    // 발신자가 취소/종료(문서 삭제 포함)하면 = 부재중.
    _sub = CallSignaling.watch(widget.callId).listen((c) {
      if (!mounted || _answering || _closed) return;
      final callerEnded = c == null ||
          c.status == CallStatus.canceled ||
          c.status == CallStatus.ended;
      if (callerEnded) {
        _onMissed();
        _close(L.t('call_canceled_by_caller'));
      } else if (c.status == CallStatus.declined) {
        _close(); // 내가(또는 다른기기서) 거절 처리됨
      }
    });
  }

  void _stopRing() {
    try {
      _ringtone.stop();
    } catch (_) {}
    try {
      Vibration.cancel();
    } catch (_) {}
  }

  @override
  void dispose() {
    _stopRing();
    _ringtone.dispose();
    _sub?.cancel();
    super.dispose();
  }

  void _close([String? msg]) {
    if (_closed || !mounted) return;
    _closed = true;
    _stopRing();
    Navigator.of(context).pop();
    if (msg != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  void _onMissed() {
    // 부재중 기록 + 알림(1회).
    CallLog.add(CallLogEntry(
      peerUuid: widget.fromUuid,
      peerName: widget.fromName,
      type: CallType.missed,
      video: widget.video,
      ts: DateTime.now().millisecondsSinceEpoch,
    ));
    PushService.instance.showMissedCall(widget.fromName);
  }

  Future<void> _accept() async {
    _stopRing();
    setState(() => _answering = true);
    // 받은 전화 기록.
    CallLog.add(CallLogEntry(
      peerUuid: widget.fromUuid,
      peerName: widget.fromName,
      type: CallType.incoming,
      video: widget.video,
      ts: DateTime.now().millisecondsSinceEpoch,
    ));
    await CallSignaling.setStatus(widget.callId, CallStatus.accepted);
    final uuid = await DeviceId.uuid();
    final nm = await DeviceId.name();
    if (!mounted) return;
    await joinDmRoom(
      context,
      room: widget.room,
      name: nm.isNotEmpty ? nm : L.t('guest'),
      uuid: uuid,
      video: widget.video,
      peerName: widget.fromName, // 상대(발신자) 이름
      replace: true, // 수신 화면을 통화 화면으로 교체
    );
  }

  Future<void> _decline() async {
    _stopRing();
    await CallSignaling.setStatus(widget.callId, CallStatus.declined);
    _close();
  }

  @override
  Widget build(BuildContext context) {
    final who = widget.fromName.isNotEmpty ? widget.fromName : L.t('unnamed');
    return Scaffold(
      backgroundColor: const Color(0xFF0E1116),
      body: SafeArea(
        child: SizedBox(
          width: double.infinity, // 폭을 꽉 채워 자식들을 가운데로.
          child: Column(
          children: [
            const Spacer(),
            Icon(
              widget.video ? Icons.videocam : Icons.call,
              size: 56,
              color: Colors.white70,
            ),
            const SizedBox(height: 16),
            Text(
              who,
              style: const TextStyle(
                  fontSize: 26, fontWeight: FontWeight.bold, color: Colors.white),
            ),
            const SizedBox(height: 8),
            Text(
              widget.video ? L.t('incoming_video') : L.t('incoming_voice'),
              style: const TextStyle(fontSize: 15, color: Colors.white54),
            ),
            const Spacer(),
            if (_answering)
              const Padding(
                padding: EdgeInsets.only(bottom: 40),
                child: CircularProgressIndicator(),
              )
            else
              Padding(
                padding: const EdgeInsets.only(bottom: 48, left: 32, right: 32),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _CircleAction(
                      color: Colors.red,
                      icon: Icons.call_end,
                      label: L.t('call_decline'),
                      onTap: _decline,
                    ),
                    _CircleAction(
                      color: Colors.green,
                      icon: widget.video ? Icons.videocam : Icons.call,
                      label: L.t('call_accept'),
                      onTap: _accept,
                    ),
                  ],
                ),
              ),
          ],
          ),
        ),
      ),
    );
  }
}

class _CircleAction extends StatelessWidget {
  final Color color;
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _CircleAction({
    required this.color,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: color,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Icon(icon, color: Colors.white, size: 32),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Text(label, style: const TextStyle(color: Colors.white70)),
      ],
    );
  }
}
