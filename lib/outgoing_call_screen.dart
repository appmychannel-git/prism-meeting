import 'dart:async';

import 'package:flutter/material.dart';

import 'call.dart';
import 'call_signaling.dart';
import 'friends.dart';
import 'l10n.dart';

/// 발신 통화 화면 — 상대 응답을 기다린다.
/// 수락 → 방 입장 / 거절·응답없음 → 닫기. 취소 버튼으로 발신 중단.
class OutgoingCallScreen extends StatefulWidget {
  final String callId;
  final String room;
  final String myUuid;
  final String myName;
  final Friend friend;
  final bool video;

  const OutgoingCallScreen({
    super.key,
    required this.callId,
    required this.room,
    required this.myUuid,
    required this.myName,
    required this.friend,
    required this.video,
  });

  @override
  State<OutgoingCallScreen> createState() => _OutgoingCallScreenState();
}

class _OutgoingCallScreenState extends State<OutgoingCallScreen> {
  StreamSubscription? _sub;
  Timer? _timeout;
  bool _joining = false;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _sub = CallSignaling.watch(widget.callId).listen(_onChange);
    // 응답 없음: 45초 후 자동 취소.
    _timeout = Timer(const Duration(seconds: 45), () {
      if (!mounted || _done) return;
      CallSignaling.setStatus(widget.callId, CallStatus.canceled);
      _close(L.t('call_no_answer'));
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _timeout?.cancel();
    super.dispose();
  }

  Future<void> _onChange(CallDoc? c) async {
    if (!mounted || _done || c == null) return;
    switch (c.status) {
      case CallStatus.accepted:
        _done = true;
        setState(() => _joining = true);
        _timeout?.cancel();
        await joinDmRoom(
          context,
          room: widget.room,
          name: widget.myName,
          uuid: widget.myUuid,
          video: widget.video,
          peerName: widget.friend.name, // 상대(수신자) 이름
          replace: true, // 발신 화면을 통화 화면으로 교체
        );
        break;
      case CallStatus.declined:
        _close(L.t('call_declined'));
        break;
      case CallStatus.canceled:
      case CallStatus.ended:
        _close();
        break;
    }
  }

  void _close([String? msg]) {
    if (_done || !mounted) return;
    _done = true;
    Navigator.of(context).pop();
    if (msg != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  Future<void> _cancel() async {
    if (_done) return;
    _done = true;
    await CallSignaling.setStatus(widget.callId, CallStatus.canceled);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final who =
        widget.friend.name.isNotEmpty ? widget.friend.name : L.t('unnamed');
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _cancel();
      },
      child: Scaffold(
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
                    fontSize: 26,
                    fontWeight: FontWeight.bold,
                    color: Colors.white),
              ),
              const SizedBox(height: 8),
              Text(
                _joining ? L.t('call_connecting') : L.t('call_calling'),
                style: const TextStyle(fontSize: 15, color: Colors.white54),
              ),
              const SizedBox(height: 24),
              if (_joining) const CircularProgressIndicator(),
              const Spacer(),
              if (!_joining)
                Padding(
                  padding: const EdgeInsets.only(bottom: 48),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Material(
                        color: Colors.red,
                        shape: const CircleBorder(),
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: _cancel,
                          child: const Padding(
                            padding: EdgeInsets.all(20),
                            child: Icon(Icons.call_end,
                                color: Colors.white, size: 32),
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(L.t('call_cancel'),
                          style: const TextStyle(color: Colors.white70)),
                    ],
                  ),
                ),
            ],
            ),
          ),
        ),
      ),
    );
  }
}
