import 'dart:async';

import 'package:flutter/material.dart';

import 'call.dart';
import 'call_signaling.dart';
import 'device_id.dart';
import 'l10n.dart';

/// 수신 통화 화면 — 상대가 나에게 전화를 걸었을 때 표시.
/// 수락 → DM 방 입장, 거절 → 상태 갱신 후 닫기.
/// 발신자가 취소하면(상태 canceled) 자동으로 닫힌다.
class IncomingCallScreen extends StatefulWidget {
  final String callId;
  final String fromName;
  final String room;
  final bool video;

  const IncomingCallScreen({
    super.key,
    required this.callId,
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

  @override
  void initState() {
    super.initState();
    // 발신자가 취소/종료하면 자동으로 닫기.
    _sub = CallSignaling.watch(widget.callId).listen((c) {
      if (!mounted || _answering) return;
      if (c == null) return;
      if (c.status == CallStatus.canceled ||
          c.status == CallStatus.ended ||
          c.status == CallStatus.declined) {
        _close(L.t('call_canceled_by_caller'));
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _close([String? msg]) {
    if (_closed || !mounted) return;
    _closed = true;
    Navigator.of(context).pop();
    if (msg != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  Future<void> _accept() async {
    setState(() => _answering = true);
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
    await CallSignaling.setStatus(widget.callId, CallStatus.declined);
    _close();
  }

  @override
  Widget build(BuildContext context) {
    final who = widget.fromName.isNotEmpty ? widget.fromName : L.t('unnamed');
    return Scaffold(
      backgroundColor: const Color(0xFF0E1116),
      body: SafeArea(
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
