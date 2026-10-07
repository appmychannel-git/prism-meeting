import 'dart:async';

import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'config.dart';
import 'connection_service.dart';
import 'device_quirks.dart';
import 'directory.dart';
import 'l10n.dart';

/// CCTV 시청 화면 — 카메라 방을 구독만(영상만 봄).
/// 5분마다 "계속 시청하시겠습니까?" 확인 → 무응답 시 자동 종료(비용 절감).
class CctvViewScreen extends StatefulWidget {
  final String roomId;
  final String pin;
  const CctvViewScreen({super.key, required this.roomId, required this.pin});

  @override
  State<CctvViewScreen> createState() => _CctvViewScreenState();
}

class _CctvViewScreenState extends State<CctvViewScreen> {
  late final Room _room;
  late final EventsListener<RoomEvent> _listener;
  bool _roomReady = false;
  bool _connecting = true;
  String? _error;
  bool _leaving = false;
  Timer? _continueTimer;

  // ── 연결 대기 타임아웃 ──
  // 방에는 붙었지만 호스트(카메라)가 일정 시간 영상을 안 보내면 "연결할 수 없음" 안내.
  // (호스트가 꺼져 있거나, 코드가 만료/재생성돼 아무도 송출하지 않는 경우)
  Timer? _waitTimer;
  bool _timedOut = false;
  static const int _waitTimeoutSec = 15;

  // 시청 확인 주기(분).
  static const int _continueMinutes = 5;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    _init();
  }

  Future<void> _init() async {
    // E2EE(옵션): 비밀번호를 공유키로 사용(회의/CCTV 당사자만 복호화).
    final e2ee = (AppConfig.e2ee && widget.pin.isNotEmpty)
        ? await E2EEOptions.sharedKey('${widget.roomId}:${widget.pin}')
        : null;
    _room = Room(roomOptions: RoomOptions(e2eeOptions: e2ee));
    _listener = _room.createListener()
      ..on<RoomDisconnectedEvent>((_) => _end())
      ..on<TrackSubscribedEvent>((_) => _refresh())
      ..on<TrackUnsubscribedEvent>((_) => _refresh())
      ..on<ParticipantConnectedEvent>((_) => _refresh())
      ..on<ParticipantDisconnectedEvent>((_) => _refresh())
      ..on<ParticipantAttributesChanged>((_) => _refresh()); // 카메라반전 플래그
    _roomReady = true;
    await _connect();
  }

  @override
  void dispose() {
    _continueTimer?.cancel();
    _waitTimer?.cancel();
    WakelockPlus.disable();
    if (_roomReady) {
      _listener.dispose();
      _room.dispose();
    }
    super.dispose();
  }

  void _refresh() {
    // 호스트 영상이 들어오면 대기 타임아웃 해제.
    if (_remoteCam() != null) {
      _waitTimer?.cancel();
      _timedOut = false;
    }
    if (mounted) setState(() {});
  }

  // 방 연결 후 호스트 영상 대기 타이머 시작(이미 오면 즉시 해제됨).
  void _startWaitTimer() {
    _waitTimer?.cancel();
    _timedOut = false;
    _waitTimer = Timer(const Duration(seconds: _waitTimeoutSec), () {
      if (mounted && _remoteCam() == null) setState(() => _timedOut = true);
    });
  }

  // "연결할 수 없음"에서 재시도 — 호스트를 다시 깨우고 대기 타이머 재시작.
  void _retry() {
    final code = widget.roomId.startsWith('cctv-')
        ? widget.roomId.substring(5)
        : widget.roomId;
    DirectoryService.requestCctvWake(code);
    setState(() => _timedOut = false);
    _startWaitTimer();
  }

  // 호스트가 응답 없을 때(꺼짐/코드 만료) 표시하는 안내 + 재시도/닫기.
  Widget _unreachableView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.videocam_off_outlined,
                size: 44, color: Color(0xFFFF8A80)),
            const SizedBox(height: 12),
            Text(
              L.t('cctv_unreachable'),
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                FilledButton.icon(
                  onPressed: _retry,
                  icon: const Icon(Icons.refresh),
                  label: Text(L.t('retry')),
                ),
                const SizedBox(width: 12),
                TextButton(
                  onPressed: _end,
                  child: Text(L.t('close')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _connect() async {
    try {
      final d = await ConnectionService.fetchFromServer(
        tokenServerUrl: AppConfig.tokenServerUrl,
        roomName: widget.roomId,
        participantName: 'Viewer',
        identity: 'viewer-${DateTime.now().millisecondsSinceEpoch}',
        pin: widget.pin,
        // 원격 켜기 중이면 카메라가 아직 방을 안 만들었을 수 있어, 시청자가 방을
        // 먼저 만들어 두고 기다린다(cctv- 방은 create 중복 허용). 카메라가 깨어나
        // 같은 방에 들어와 송출하면 화면에 뜬다.
        create: true,
      );
      await _room.connect(d.serverUrl, d.token,
          connectOptions: const ConnectOptions(autoSubscribe: true));
      if (mounted) setState(() => _connecting = false);
      _startWaitTimer();
      _scheduleContinuePrompt();
    } catch (e) {
      if (mounted) {
        setState(() {
          _connecting = false;
          _error = e.toString().replaceFirst('Exception: ', '');
        });
      }
    }
  }

  VideoTrack? _remoteCam() {
    for (final p in _room.remoteParticipants.values) {
      for (final pub in p.videoTrackPublications) {
        if (pub.source == TrackSource.camera && !pub.muted) {
          final t = pub.track;
          if (t is VideoTrack) return t;
        }
      }
    }
    return null;
  }

  /// 송출 중인 카메라의 참가자가 "상하반전 기기"(attribute camFlip=180)인가.
  /// 맞으면 시청 화면을 180° 회전해 바로잡는다.
  bool _remoteCamFlipped() {
    for (final p in _room.remoteParticipants.values) {
      for (final pub in p.videoTrackPublications) {
        if (pub.source == TrackSource.camera && !pub.muted) {
          return p.attributes[DeviceQuirks.flipAttrKey] ==
              DeviceQuirks.flipAttrValue;
        }
      }
    }
    return false;
  }

  void _scheduleContinuePrompt() {
    _continueTimer?.cancel();
    _continueTimer =
        Timer(const Duration(minutes: _continueMinutes), _askContinue);
  }

  Future<void> _askContinue() async {
    if (!mounted || _leaving) return;
    Timer? auto;
    final keep = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        // 30초 무응답 시 자동 종료(비용 절감).
        auto = Timer(const Duration(seconds: 30), () {
          if (Navigator.of(ctx).canPop()) Navigator.of(ctx).pop(false);
        });
        return AlertDialog(
          title: Text(L.t('cctv_continue_title')),
          content: Text(L.t('cctv_continue_msg')),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(L.t('cctv_stop')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(L.t('cctv_continue')),
            ),
          ],
        );
      },
    );
    auto?.cancel();
    if (keep == true) {
      _scheduleContinuePrompt();
    } else {
      _hangup();
    }
  }

  Future<void> _hangup() async {
    try {
      await _room.disconnect();
    } catch (_) {}
    _end();
  }

  void _end() {
    if (_leaving || !mounted) return;
    _leaving = true;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    if (!_roomReady) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator()),
      );
    }
    final cam = _remoteCam();
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _hangup();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.error_outline,
                            size: 44, color: Color(0xFFFF8A80)),
                        const SizedBox(height: 12),
                        Text(_error!, textAlign: TextAlign.center),
                        const SizedBox(height: 20),
                        FilledButton(
                          onPressed: _end,
                          child: Text(L.t('back')),
                        ),
                      ],
                    ),
                  ),
                )
              : Stack(
                  children: [
                    Positioned.fill(
                      child: cam != null
                          ? (_remoteCamFlipped()
                              ? RotatedBox(
                                  quarterTurns: 2,
                                  child: VideoTrackRenderer(cam,
                                      fit: VideoViewFit.contain))
                              : VideoTrackRenderer(cam,
                                  fit: VideoViewFit.contain))
                          : _timedOut
                              ? _unreachableView()
                              : Center(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const CircularProgressIndicator(),
                                      const SizedBox(height: 16),
                                      Text(
                                        _connecting
                                            ? L.t('call_connecting')
                                            : L.t('cctv_waiting'),
                                        style: const TextStyle(
                                            color: Colors.white70),
                                      ),
                                    ],
                                  ),
                                ),
                    ),
                    Positioned(
                      right: 12,
                      top: 12,
                      child: Material(
                        color: const Color(0xFFE5484D),
                        shape: const CircleBorder(),
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: _hangup,
                          child: const Padding(
                            padding: EdgeInsets.all(12),
                            child: Icon(Icons.close, color: Colors.white),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
