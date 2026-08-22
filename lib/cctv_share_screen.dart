import 'dart:async';

import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:vibration/vibration.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'cctv_store.dart';
import 'config.dart';
import 'connection_service.dart';
import 'l10n.dart';
import 'push_service.dart';

/// CCTV 공유(카메라) 화면 — 이 기기 카메라를 송출한다.
/// 이 화면을 켜둔 동안만 송출(나가면 종료). QR(코드)+비밀번호로 시청자가 접속.
class CctvShareScreen extends StatefulWidget {
  const CctvShareScreen({super.key});

  /// 원격 켜기 중복 실행 방지용(송출 화면이 떠 있는지).
  static bool active = false;

  @override
  State<CctvShareScreen> createState() => _CctvShareScreenState();
}

class _CctvShareScreenState extends State<CctvShareScreen> {
  late final Room _room;
  late final EventsListener<RoomEvent> _listener;
  bool _roomReady = false;

  String _code = ''; // 표시/입력용 코드(cctv- 제외). 이 기기 고정값.
  String _roomId = ''; // 실제 방 이름 cctv-<code>
  String _pin = '';
  bool _connecting = true;
  String? _error;
  int _viewers = 0;

  // 송출 절전: 일정 시간 미조작 시 미리보기 끄고 화면 어둡게(송출은 유지).
  bool _dimmed = false;
  Timer? _idleTimer;
  static const _idleSeconds = 30;

  void _onInteract() {
    if (_dimmed) _wake();
    _resetIdleTimer();
  }

  void _resetIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = Timer(const Duration(seconds: _idleSeconds), _dim);
  }

  Future<void> _dim() async {
    if (!mounted || _dimmed) return;
    setState(() => _dimmed = true); // 미리보기 렌더 중단(GPU 절감)
    try {
      await ScreenBrightness().setApplicationScreenBrightness(0.0); // 최소 밝기
    } catch (_) {}
  }

  Future<void> _wake() async {
    if (!mounted || !_dimmed) return;
    setState(() => _dimmed = false);
    try {
      await ScreenBrightness().resetApplicationScreenBrightness(); // 밝기 복원
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    CctvShareScreen.active = true;
    cancelCctvWakeNotification(); // 원격 켜기 알림이 있었다면 정리
    WakelockPlus.enable();
    _init();
  }

  Future<void> _init() async {
    // 이 기기의 고정 코드/비번(최초 1회 생성 후 유지) → 매번 같은 코드로 공유.
    final (code, pin) = await CctvStore.myShareCredentials();
    _code = code;
    _roomId = 'cctv-$code';
    _pin = pin;
    // E2EE(옵션): 비밀번호를 공유키로.
    final e2ee = (AppConfig.e2ee && pin.isNotEmpty)
        ? await E2EEOptions.sharedKey('$_roomId:$pin')
        : null;
    _room = Room(
      roomOptions: RoomOptions(
        adaptiveStream: true,
        dynacast: true,
        defaultVideoPublishOptions:
            const VideoPublishOptions(simulcast: true, videoCodec: 'h264'),
        e2eeOptions: e2ee,
      ),
    );
    _listener = _room.createListener()
      ..on<ParticipantConnectedEvent>((_) => _updateViewers())
      ..on<ParticipantDisconnectedEvent>((_) => _updateViewers());
    _roomReady = true;
    await _connect();
  }

  @override
  void dispose() {
    CctvShareScreen.active = false;
    _idleTimer?.cancel();
    try {
      ScreenBrightness().resetApplicationScreenBrightness(); // 밝기 원복
    } catch (_) {}
    cancelCctvLiveNotification(); // 송출 종료 → 상시 알림 제거
    WakelockPlus.disable();
    if (_roomReady) {
      _listener.dispose();
      _room.dispose();
    }
    super.dispose();
  }

  void _updateViewers() {
    if (mounted) setState(() => _viewers = _room.remoteParticipants.length);
    showCctvLiveNotification(_room.remoteParticipants.length); // 알림 갱신
  }

  Future<void> _connect() async {
    try {
      final d = await ConnectionService.fetchFromServer(
        tokenServerUrl: AppConfig.tokenServerUrl,
        roomName: _roomId,
        participantName: 'CCTV',
        identity: 'cam-${DateTime.now().millisecondsSinceEpoch}',
        pin: _pin,
        create: true,
      );
      await _room.connect(d.serverUrl, d.token,
          connectOptions: const ConnectOptions(autoSubscribe: false));
      // 카메라만 송출(마이크는 끔).
      await _room.localParticipant?.setCameraEnabled(true);
      if (mounted) setState(() => _connecting = false);
      // 접속 시점에 이미 방에 있던 시청자 수 반영(원격 켜기로 시청자가 먼저 들어온 경우).
      _updateViewers();
      // 방송 중 인지: 상시 알림 + 시작 진동(원격으로 켜져도 알아채도록).
      showCctvLiveNotification(0);
      try {
        if (await Vibration.hasVibrator()) Vibration.vibrate(duration: 300);
      } catch (_) {}
      _resetIdleTimer(); // 절전 카운트다운 시작
    } catch (e) {
      if (mounted) {
        setState(() {
          _connecting = false;
          _error = e.toString().replaceFirst('Exception: ', '');
        });
      }
    }
  }

  VideoTrack? _localCam() {
    final lp = _room.localParticipant;
    if (lp == null) return null;
    for (final pub in lp.videoTrackPublications) {
      if (pub.source == TrackSource.camera && !pub.muted) {
        final t = pub.track;
        if (t is VideoTrack) return t;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: _connecting
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_error!, textAlign: TextAlign.center),
                  ),
                )
              : Listener(
                  behavior: HitTestBehavior.translucent,
                  onPointerDown: (_) => _onInteract(), // 조작 시 절전 해제/연장
                  child: Stack(
                  fit: StackFit.expand, // Stack 이 화면 전체를 차지하도록
                  children: [
                    // 송출 영상 전체화면 (절전 중엔 미리보기 렌더 안 함 = GPU 절감)
                    Positioned.fill(
                      child: _dimmed
                          ? _dimView()
                          : (_localCam() != null
                              ? VideoTrackRenderer(_localCam()!,
                                  fit: VideoViewFit.cover,
                                  mirrorMode: VideoViewMirrorMode.off)
                              : Container(
                                  color: const Color(0xFF1A1F27),
                                  child: const Center(
                                    child: Icon(Icons.videocam_off,
                                        color: Colors.white38, size: 48),
                                  ),
                                )),
                    ),
                    // 상단 오버레이: 뒤로 · LIVE·시청자 · QR/비번 버튼 (절전 중엔 숨김)
                    if (!_dimmed)
                      Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: SafeArea(
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: Row(
                          children: [
                            _overlayBtn(Icons.arrow_back,
                                () => Navigator.of(context).maybePop()),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 6),
                              decoration: BoxDecoration(
                                color: const Color(0xFFE5484D),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.fiber_manual_record,
                                      size: 12, color: Colors.white),
                                  const SizedBox(width: 6),
                                  Text(
                                    '${L.t('cctv_live_badge')} · ${L.t('cctv_viewers', {'n': '$_viewers'})}',
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold),
                                  ),
                                ],
                              ),
                            ),
                            const Spacer(),
                            // 우측 상단: QR·비밀번호 보기
                            _overlayBtn(Icons.qr_code_2, _showShareInfo),
                          ],
                        ),
                      ),
                      ),
                    ),
                  ],
                ),
                ),
    );
  }

  // 절전 화면: 검은 배경 + 안내(미리보기 안 그림 → GPU/화면 부담↓, 송출은 유지).
  Widget _dimView() {
    return Container(
      color: Colors.black,
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.fiber_manual_record,
              size: 16, color: Color(0xFFE5484D)),
          const SizedBox(height: 10),
          Text(L.t('cctv_dim_hint'),
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white38, fontSize: 13)),
        ],
      ),
    );
  }

  // 반투명 원형 오버레이 버튼.
  Widget _overlayBtn(IconData icon, VoidCallback onTap) {
    return Material(
      color: Colors.black.withValues(alpha: 0.45),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(icon, color: Colors.white, size: 24),
        ),
      ),
    );
  }

  // QR + 코드 + 비밀번호를 하단 시트로 표시(버튼 누를 때만 노출).
  void _showShareInfo() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF0E1116),
      showDragHandle: true,
      isScrollControlled: true, // 내용이 길면 화면 높이만큼 확장
      builder: (_) => SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Center(
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: SizedBox(
                      width: 170,
                      height: 170,
                      child: PrettyQrView.data(
                        // 딥링크: 찍으면 앱이 열려 시청화면으로(핀은 앱에서 별도 입력).
                        data: AppConfig.cctvLink(_code),
                        decoration: const PrettyQrDecoration(
                          shape: PrettyQrSmoothSymbol(color: Color(0xFF000000)),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                _kv(L.t('cctv_code'), _code),
                const SizedBox(height: 10),
                _kv(L.t('cctv_password'), _pin),
                const SizedBox(height: 16),
                Text(
                  L.t('cctv_share_hint'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 13, color: Colors.white70),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _kv(String k, String v) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text('$k  ', style: const TextStyle(color: Colors.white54)),
        SelectableText(
          v,
          style: const TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.bold,
            letterSpacing: 3,
            color: Colors.white,
          ),
        ),
      ],
    );
  }
}
