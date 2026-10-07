import 'dart:async';

import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';

import 'app_settings.dart';
import 'connection_service.dart';
import 'device_quirks.dart';
import 'l10n.dart';
import 'proximity.dart';
import 'push_service.dart';

/// 1:1 통화 전용 화면(회의방과 별개 UI).
/// - 음성통화: 상대 아바타 + 이름 + 통화시간, 하단에 음소거/종료.
/// - 영상통화: 상대 영상 크게 + 내 영상 작은 PiP, 하단에 음소거/카메라/종료.
class CallScreen extends StatefulWidget {
  final ConnectionDetails details;
  final String roomName;
  final String displayName;
  final String peerName;
  final bool video;

  const CallScreen({
    super.key,
    required this.details,
    required this.roomName,
    required this.displayName,
    required this.peerName,
    required this.video,
  });

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  final Room _room = Room(
    roomOptions: const RoomOptions(
      adaptiveStream: true,
      dynacast: true,
      defaultVideoPublishOptions: VideoPublishOptions(
        simulcast: true,
        videoCodec: 'h264',
      ),
      defaultAudioPublishOptions:
          AudioPublishOptions(dtx: true, red: true),
    ),
  );
  late final EventsListener<RoomEvent> _listener = _room.createListener();

  bool _connecting = true;
  String? _error;
  bool _micOn = true;
  late bool _camOn = widget.video;
  // 영상통화는 스피커 기본 on, 음성통화는 이어피스(스피커 off) 기본.
  late bool _speakerOn = widget.video;
  bool _frontCamera = true;
  // 카메라가 2개 이상(전/후면)인가. 카메라가 성공적으로 켜진 뒤에만 안전하게 판정한다.
  // 1개뿐이면 전환 버튼은 의미가 없어(같은 카메라 재초기화로 잠깐 깜빡일 뿐) 숨긴다.
  bool _multiCamera = false;
  bool _peerWasHere = false;
  bool _leaving = false;

  Timer? _tick;
  DateTime? _connectedAt;
  Duration _elapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    _room.addListener(_onChange);
    _setupListeners();
    _connect();
  }

  // 음성통화 + 이어피스(스피커 off)일 때만 근접센서 화면끄기 적용.
  void _applyProximity() {
    if (!widget.video && !_speakerOn) {
      ProximityLock.acquire();
    } else {
      ProximityLock.release();
    }
  }

  @override
  void dispose() {
    ProximityLock.release(); // 근접 잠금 해제
    PushService.instance.setInCall(false); // 통화중 해제
    _tick?.cancel();
    _room.removeListener(_onChange);
    _listener.dispose();
    _room.dispose();
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  void _setupListeners() {
    _listener
      ..on<RoomDisconnectedEvent>((_) => _end())
      ..on<ParticipantConnectedEvent>((_) {
        _peerWasHere = true;
        _onChange();
      })
      ..on<ParticipantDisconnectedEvent>((_) {
        // 상대가 있었다가 나가면 통화 종료.
        if (_peerWasHere && _room.remoteParticipants.isEmpty) {
          _end(notice: L.t('call_ended'));
        } else {
          _onChange();
        }
      })
      ..on<TrackSubscribedEvent>((_) => _onChange())
      ..on<TrackUnsubscribedEvent>((_) => _onChange())
      ..on<TrackMutedEvent>((_) => _onChange())
      ..on<TrackUnmutedEvent>((_) => _onChange())
      ..on<ParticipantAttributesChanged>((_) => _onChange()); // 카메라반전 플래그
  }

  Future<void> _connect() async {
    try {
      await _room
          .connect(
            widget.details.serverUrl,
            widget.details.token,
            connectOptions: const ConnectOptions(autoSubscribe: true),
          )
          .timeout(const Duration(seconds: 20));
    } catch (e) {
      if (mounted) {
        setState(() {
          _connecting = false;
          _error = e.toString().replaceFirst('Exception: ', '');
        });
      }
      return;
    }
    if (mounted) setState(() => _connecting = false);
    PushService.instance.setInCall(true); // 통화중 표시(친구목록)
    _connectedAt = DateTime.now();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _connectedAt == null) return;
      setState(() => _elapsed = DateTime.now().difference(_connectedAt!));
    });
    if (_room.remoteParticipants.isNotEmpty) _peerWasHere = true;

    final lp = _room.localParticipant;
    try {
      await lp?.setMicrophoneEnabled(true).timeout(const Duration(seconds: 8));
    } catch (_) {
      if (mounted) setState(() => _micOn = false);
    }
    if (widget.video) {
      await _enableCameraOnConnect(lp);
    }
    // 카메라 상하반전 기기는 플래그를 알려 상대가 내 영상을 180° 회전해 보게 한다.
    if (AppSettings.cameraFlip180) {
      try {
        await lp?.setAttributes(
          {DeviceQuirks.flipAttrKey: DeviceQuirks.flipAttrValue},
        );
      } catch (_) {}
    }
    // 오디오 출력(스피커/이어피스) 초기화.
    try {
      await AudioManager.instance.setSpeakerOutputPreferred(_speakerOn);
    } catch (_) {}
    _applyProximity();
  }

  Future<void> _toggleSpeaker() async {
    final next = !_speakerOn;
    setState(() => _speakerOn = next);
    try {
      await AudioManager.instance.setSpeakerOutputPreferred(next);
    } catch (_) {
      if (mounted) setState(() => _speakerOn = !next);
    }
    _applyProximity();
  }

  Future<void> _flipCamera() async {
    LocalVideoTrack? cam;
    final lp = _room.localParticipant;
    if (lp != null) {
      for (final pub in lp.videoTrackPublications) {
        if (pub.source == TrackSource.camera) {
          final t = pub.track;
          if (t is LocalVideoTrack) cam = t;
          break;
        }
      }
    }
    if (cam == null) return;
    try {
      await cam.setCameraPosition(
          _frontCamera ? CameraPosition.back : CameraPosition.front);
      if (mounted) setState(() => _frontCamera = !_frontCamera);
    } catch (_) {}
  }

  // 카메라 없는/고장난 기기(일부 TV박스·스탠드TV)에서 카메라 서비스 호출
  // (videoInputs/setCameraEnabled)이 네이티브 메인스레드를 블록해 통화가 00:00 에
  // 굳고 결국 끊기던 문제 방지. 이런 "phantom camera" 기기는 카메라 feature 를 보고하고
  // 열거(videoInputs)조차 멈춰, Dart timeout 으로도 끊을 수 없다. 그래서 유일하게 안전한
  // 신호인 사용자 설정(AppSettings.startCameraOnJoin — 카메라 없는 기기는 OFF, 또는
  // 지난 멈춤 후 자동 OFF)으로 판단해, OFF면 카메라를 "아예 건드리지 않고" 영상 없이
  // (음성 송신 + 상대 영상 수신) 통화한다. room_screen 과 동일한 원리.
  Future<void> _enableCameraOnConnect(LocalParticipant? lp) async {
    if (lp == null) return;
    // 직전 카메라 시도가 멈춘 채 종료된 흔적이 있으면 → 이 기기 카메라는 못 쓰므로
    // 자동 켜기를 영구히 끄고(다음부턴 음성통화로 바로 진행) 재멈춤을 막는다.
    if (AppSettings.camAttemptPending) {
      await AppSettings.setCamAttemptPending(false);
      await AppSettings.setStartCameraOnJoin(false);
      if (mounted) setState(() => _camOn = false);
      return;
    }
    // 카메라 자동 켜기 OFF(카메라 없는/고장 기기) → 카메라 서비스를 호출하지 않는다.
    if (!AppSettings.startCameraOnJoin) {
      if (mounted) setState(() => _camOn = false);
      return;
    }
    await _tryEnableCamera(lp);
  }

  // 카메라 켜기 공통: open 이 메인스레드를 블록해 굳을 수 있으므로 "진행 중" 플래그를
  // 디스크에 남겨(멈춘 채 강제종료돼도 다음 실행이 감지), 켜기를 시도한다.
  Future<void> _tryEnableCamera(LocalParticipant? lp) async {
    if (lp == null) return;
    await AppSettings.setCamAttemptPending(true);
    try {
      await lp.setCameraEnabled(true).timeout(const Duration(seconds: 8));
      if (mounted) setState(() => _camOn = true);
      // 카메라가 열렸으니(카메라 서비스 응답) 이제 안전하게 개수를 센다.
      // 2개 이상일 때만 전/후면 전환 버튼을 보여준다(1개뿐이면 전환 무의미).
      await _detectMultiCamera();
    } catch (_) {
      if (mounted) setState(() => _camOn = false);
    }
    await AppSettings.setCamAttemptPending(false);
  }

  // 사용 가능한 카메라가 2개 이상인지 판정(카메라가 켜진 뒤에만 호출 — 열거가 안전).
  Future<void> _detectMultiCamera() async {
    try {
      final cams = await Hardware.instance
          .videoInputs()
          .timeout(const Duration(seconds: 5));
      // videoInputs()는 영상 입력 장치만 돌려준다. 2개 이상이면 전/후면 전환 가능.
      if (mounted) setState(() => _multiCamera = cams.length >= 2);
    } catch (_) {}
  }

  Future<void> _toggleMic() async {
    final next = !_micOn;
    setState(() => _micOn = next);
    try {
      await _room.localParticipant?.setMicrophoneEnabled(next);
    } catch (_) {
      if (mounted) setState(() => _micOn = !next);
    }
  }

  Future<void> _toggleCam() async {
    final next = !_camOn;
    if (next) {
      // 켜기(사용자 명시적): 직전 시도가 멈춘 흔적이 있으면 보호를 위해 켜지 않는다.
      if (AppSettings.camAttemptPending) {
        await AppSettings.setCamAttemptPending(false);
        if (mounted) setState(() => _camOn = false);
        return;
      }
      setState(() => _camOn = true);
      await _tryEnableCamera(_room.localParticipant);
      return;
    }
    // 끄기.
    setState(() => _camOn = false);
    try {
      await _room.localParticipant
          ?.setCameraEnabled(false)
          .timeout(const Duration(seconds: 8));
    } catch (_) {}
  }

  Future<void> _hangup() async {
    try {
      await _room.disconnect();
    } catch (_) {}
    _end();
  }

  void _end({String? notice}) {
    if (_leaving) return;
    _leaving = true;
    if (!mounted) return;
    Navigator.of(context).pop();
    if (notice != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(notice)));
    }
  }

  VideoTrack? _cameraTrackOf(Participant? p) {
    if (p == null) return null;
    for (final pub in p.videoTrackPublications) {
      if (pub.source != TrackSource.camera) continue;
      if (pub.muted) continue;
      final t = pub.track;
      if (t is VideoTrack) return t;
    }
    return null;
  }

  Participant? get _remote => _room.remoteParticipants.values.isNotEmpty
      ? _room.remoteParticipants.values.first
      : null;

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final h = d.inHours;
    return h > 0 ? '${h.toString().padLeft(2, '0')}:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final peer = widget.peerName.isNotEmpty ? widget.peerName : L.t('unnamed');
    final connected = _remote != null;
    final status = _connecting
        ? L.t('call_connecting')
        : (connected ? _fmt(_elapsed) : L.t('call_calling'));

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _hangup();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0E1116),
        body: SafeArea(
          child: _error != null
              ? _errorView()
              : Stack(
                  children: [
                    if (widget.video)
                      _videoLayout(peer, status)
                    else
                      _voiceLayout(peer, status),
                    _controls(),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _errorView() => Center(
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
                onPressed: () => _end(),
                child: Text(L.t('back')),
              ),
            ],
          ),
        ),
      );

  // 음성통화: 아바타 + 이름 + 상태(통화시간).
  Widget _voiceLayout(String peer, String status) {
    return Positioned.fill(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircleAvatar(
            radius: 54,
            backgroundColor: const Color(0xFF2E3742),
            child: Text(
              peer.characters.first.toUpperCase(),
              style: const TextStyle(fontSize: 44, color: Colors.white),
            ),
          ),
          const SizedBox(height: 20),
          Text(peer,
              style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: Colors.white)),
          const SizedBox(height: 8),
          Text(status,
              style: const TextStyle(fontSize: 15, color: Colors.white54)),
        ],
      ),
    );
  }

  // 영상통화: 상대 영상 크게(없으면 아바타), 내 영상 작은 PiP.
  Widget _videoLayout(String peer, String status) {
    final remoteVid = _cameraTrackOf(_remote);
    final localVid = _cameraTrackOf(_room.localParticipant);
    // 카메라 상하반전 기기(attribute camFlip=180)의 영상은 180° 회전해 바로잡는다.
    final remoteFlip = _remote?.attributes[DeviceQuirks.flipAttrKey] ==
        DeviceQuirks.flipAttrValue;
    final localFlip = _room.localParticipant?.attributes[
            DeviceQuirks.flipAttrKey] ==
        DeviceQuirks.flipAttrValue;
    return Positioned.fill(
      child: Stack(
        children: [
          // 상대 영상(큰 화면)
          Positioned.fill(
            child: remoteVid != null
                ? (remoteFlip
                    ? RotatedBox(
                        quarterTurns: 2,
                        child: VideoTrackRenderer(remoteVid,
                            fit: VideoViewFit.cover,
                            mirrorMode: VideoViewMirrorMode.off))
                    : VideoTrackRenderer(remoteVid,
                        fit: VideoViewFit.cover,
                        mirrorMode: VideoViewMirrorMode.off))
                : Container(
                    color: const Color(0xFF1A1F27),
                    child: Center(
                      child: CircleAvatar(
                        radius: 48,
                        backgroundColor: const Color(0xFF2E3742),
                        child: Text(peer.characters.first.toUpperCase(),
                            style: const TextStyle(
                                fontSize: 40, color: Colors.white)),
                      ),
                    ),
                  ),
          ),
          // 상단: 이름 + 상태
          Positioned(
            top: 12,
            left: 0,
            right: 0,
            child: Column(
              children: [
                Text(peer,
                    style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                        shadows: [Shadow(blurRadius: 6, color: Colors.black)])),
                Text(status,
                    style: const TextStyle(
                        fontSize: 13,
                        color: Colors.white70,
                        shadows: [Shadow(blurRadius: 6, color: Colors.black)])),
              ],
            ),
          ),
          // 내 영상(작은 PiP)
          Positioned(
            right: 12,
            top: 60,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: 108,
                height: 150,
                child: (localVid != null && _camOn)
                    ? (localFlip
                        ? RotatedBox(
                            quarterTurns: 2,
                            child: VideoTrackRenderer(localVid,
                                fit: VideoViewFit.cover,
                                mirrorMode: VideoViewMirrorMode.auto))
                        : VideoTrackRenderer(localVid,
                            fit: VideoViewFit.cover,
                            mirrorMode: VideoViewMirrorMode.auto))
                    : Container(
                        color: const Color(0xFF2E3742),
                        child: const Center(
                            child: Icon(Icons.videocam_off,
                                color: Colors.white54)),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _controls() {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 40,
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 22,
        runSpacing: 12,
        children: [
          _btn(
            icon: _micOn ? Icons.mic : Icons.mic_off,
            label: _micOn ? L.t('mic_mute') : L.t('mic_unmute'),
            bg: _micOn ? const Color(0xFF2E3742) : const Color(0xFF5A3A3A),
            onTap: _toggleMic,
          ),
          _btn(
            icon: _speakerOn ? Icons.volume_up : Icons.hearing,
            label: _speakerOn ? L.t('speaker') : L.t('earpiece'),
            bg: _speakerOn ? const Color(0xFF2E5AC0) : const Color(0xFF2E3742),
            onTap: _toggleSpeaker,
          ),
          if (widget.video) ...[
            _btn(
              icon: _camOn ? Icons.videocam : Icons.videocam_off,
              label: _camOn ? L.t('cam_off') : L.t('cam_on'),
              bg: _camOn ? const Color(0xFF2E3742) : const Color(0xFF5A3A3A),
              onTap: _toggleCam,
            ),
            // 전/후면 전환은 카메라가 켜져 있고 2개 이상일 때만(1개뿐이면 무의미).
            if (_camOn && _multiCamera)
              _btn(
                icon: Icons.cameraswitch,
                label: L.t('cam_flip'),
                bg: const Color(0xFF2E3742),
                onTap: _flipCamera,
              ),
          ],
          _btn(
            icon: Icons.call_end,
            label: L.t('call_hangup'),
            bg: const Color(0xFFE5484D),
            onTap: _hangup,
          ),
        ],
      ),
    );
  }

  Widget _btn({
    required IconData icon,
    required String label,
    required Color bg,
    required VoidCallback onTap,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: bg,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Icon(icon, color: Colors.white, size: 28),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.white70)),
      ],
    );
  }
}
