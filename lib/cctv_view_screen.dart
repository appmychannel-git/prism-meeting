import 'dart:async';

import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'config.dart';
import 'connection_service.dart';
import 'device_id.dart';
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
  bool _leaving = false; // 사용자가 직접 닫는 중(정상 종료)
  bool _popped = false; // pop 중복 방지
  bool _connected = false; // 방 접속 성공 여부
  // 시청자 identity — 기기별 고정값. 재시도/재진입 때 같은 identity 로 접속해야
  // LiveKit 이 이전 세션을 즉시 교체해 유령 참가자(시청자 2명 표시)가 안 생긴다.
  String _identity = 'viewer';
  String _uuid = ''; // 기기 uuid(원격 깨우기 차단/비번 검사에 전달)
  bool _sawVideo = false; // 호스트 영상을 한 번이라도 받았는지
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
    // 기기별 고정 identity(재시도/재진입 시 이전 세션 교체 → 유령 참가자 방지).
    try {
      _uuid = await DeviceId.uuid();
      _identity = 'viewer-$_uuid';
    } catch (_) {}
    // E2EE(옵션): 비밀번호를 공유키로 사용(회의/CCTV 당사자만 복호화).
    final e2ee = (AppConfig.e2ee && widget.pin.isNotEmpty)
        ? await E2EEOptions.sharedKey('${widget.roomId}:${widget.pin}')
        : null;
    _room = Room(roomOptions: RoomOptions(e2eeOptions: e2ee));
    _listener = _room.createListener()
      ..on<RoomDisconnectedEvent>((_) => _onDisconnected())
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
      _sawVideo = true;
    }
    if (mounted) setState(() {});
  }

  // 방에서 끊겼을 때: 사용자가 닫은 게 아니고 영상도 못 받았으면
  // "조용히 튕김" 대신 방없음(삭제/사용중지/비번변경)으로 안내한다.
  void _onDisconnected() {
    if (_leaving) {
      _end();
      return;
    }
    if (!_sawVideo) {
      _showNotFound();
      return;
    }
    _end(); // 영상까지 봤다면 호스트가 송출을 끝낸 것 → 정상 종료
  }

  // 방없음 안내(삭제/비활성/비번변경/코드만료 공통).
  void _showNotFound() {
    if (!mounted || _leaving) return;
    _continueTimer?.cancel();
    _waitTimer?.cancel();
    setState(() {
      _connecting = false;
      _timedOut = false;
      _error = L.t('cctv_not_found');
    });
  }

  // 방 연결 후 호스트 영상 대기 타이머 시작(이미 오면 즉시 해제됨).
  void _startWaitTimer() {
    _waitTimer?.cancel();
    _timedOut = false;
    _waitTimer = Timer(const Duration(seconds: _waitTimeoutSec), () {
      if (mounted && _remoteCam() == null) setState(() => _timedOut = true);
    });
  }

  // "연결할 수 없음"에서 재시도.
  //  - 아직 방에 못 들어갔으면 전체 접속 흐름을 처음부터 다시(깨우기 포함).
  //  - 이미 들어가 있으면(영상만 안 옴) 호스트를 다시 깨우고 대기 타이머만 재시작.
  void _retry() {
    setState(() => _timedOut = false);
    if (!_connected) {
      setState(() => _connecting = true);
      _connect();
    } else {
      DirectoryService.requestCctvWake(_code(), pin: widget.pin, uuid: _uuid);
      _startWaitTimer();
    }
  }

  // widget.roomId(cctv-<code>)에서 코드만.
  String _code() => widget.roomId.startsWith('cctv-')
      ? widget.roomId.substring(5)
      : widget.roomId;

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

  // 접속 흐름:
  //  1) create:false 로 먼저 시도(방을 새로 만들지 않음) → 방없음/비번무효를 구분.
  //     - 성공            → 시청 시작
  //     - 403(비번 무효)  → 방없음 안내(삭제/비활성/비번변경 공통)
  //     - 404(방 없음)    → 호스트가 꺼져 있을 수 있음 → 깨우고 방 생기면 재시도(폴링)
  //  이렇게 하면 예전처럼 시청자가 빈 방을 만들어 두었다가 카메라 재생성에 조용히
  //  튕기는 문제가 사라지고, 왜 못 보는지 명확히 안내된다.
  Future<void> _connect() async {
    final err = await _attemptJoin();
    if (!mounted) return;
    if (err == null) {
      _onConnected();
      return;
    }
    if (err.statusCode == 403 || err.statusCode == 429) {
      // 비번 무효(그룹 삭제/비활성/비번변경) 또는 잠금 → 방없음/서버 메시지 안내.
      setState(() {
        _connecting = false;
        _error = err.statusCode == 429 ? err.message : L.t('cctv_not_found');
      });
      return;
    }
    // 404 등: 호스트가 아직 송출 전일 수 있음 → 깨우고 방이 생길 때까지 대기.
    // 비번·기기ID를 함께 보내 서버가 차단/비번을 먼저 검사(틀리면 안 깨움 → 방없음).
    final wake = await DirectoryService.requestCctvWake(_code(),
        pin: widget.pin, uuid: _uuid);
    if (!mounted) return;
    if (wake == CctvWakeResult.notFound) {
      // 등록된 CCTV가 없음(코드 만료/삭제) → 방없음 즉시 안내.
      setState(() {
        _connecting = false;
        _error = L.t('cctv_not_found');
      });
      return;
    }
    _pollForHost();
  }

  // 방이 생길 때까지(카메라가 송출 시작) 짧게 폴링하며 접속 시도.
  Future<void> _pollForHost() async {
    final deadline =
        DateTime.now().add(const Duration(seconds: _waitTimeoutSec));
    while (mounted && !_connected && DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(seconds: 2));
      if (!mounted || _connected) return;
      final err = await _attemptJoin();
      if (!mounted) return;
      if (err == null) {
        _onConnected();
        return;
      }
      if (err.statusCode == 403 || err.statusCode == 429) {
        setState(() {
          _connecting = false;
          _error = err.statusCode == 429 ? err.message : L.t('cctv_not_found');
        });
        return;
      }
      // 404 → 아직 카메라가 방을 안 만듦 → 계속 대기.
    }
    // 제한시간 내 호스트 응답 없음 → "연결할 수 없음"(재시도/닫기).
    if (mounted && !_connected) {
      setState(() {
        _connecting = false;
        _timedOut = true;
      });
    }
  }

  // 토큰 발급(create:false) + 방 접속 1회 시도.
  // 성공 시 null, 실패 시 RoomJoinException(상태코드 포함) 반환.
  Future<RoomJoinException?> _attemptJoin() async {
    try {
      final d = await ConnectionService.fetchFromServer(
        tokenServerUrl: AppConfig.tokenServerUrl,
        roomName: widget.roomId,
        participantName: 'Viewer',
        identity: _identity, // 기기별 고정(유령 참가자 방지)
        pin: widget.pin,
        create: false, // 방을 새로 만들지 않음(방없음/비번무효 구분 위해)
      );
      await _room.connect(d.serverUrl, d.token,
          connectOptions: const ConnectOptions(autoSubscribe: true));
      return null;
    } on RoomJoinException catch (e) {
      return e;
    } catch (e) {
      return RoomJoinException(0, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  void _onConnected() {
    _connected = true;
    if (mounted) {
      setState(() {
        _connecting = false;
        _timedOut = false;
      });
    }
    _startWaitTimer();
    _scheduleContinuePrompt();
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
    _leaving = true; // 정상 종료 의도 표시(연결 끊김을 "방없음"으로 오인하지 않도록)
    try {
      await _room.disconnect();
    } catch (_) {}
    _end();
  }

  void _end() {
    if (_popped || !mounted) return;
    _leaving = true;
    _popped = true;
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
