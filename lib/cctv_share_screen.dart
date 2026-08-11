import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';
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
      // 방송 중 인지: 상시 알림 + 시작 진동(원격으로 켜져도 알아채도록).
      showCctvLiveNotification(0);
      try {
        if (await Vibration.hasVibrator()) Vibration.vibrate(duration: 300);
      } catch (_) {}
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
              : Stack(
                  fit: StackFit.expand, // Stack 이 화면 전체를 차지하도록
                  children: [
                    // 송출 영상 전체화면
                    Positioned.fill(
                      child: _localCam() != null
                          ? VideoTrackRenderer(_localCam()!,
                              fit: VideoViewFit.cover,
                              mirrorMode: VideoViewMirrorMode.off)
                          : Container(
                              color: const Color(0xFF1A1F27),
                              child: const Center(
                                child: Icon(Icons.videocam_off,
                                    color: Colors.white38, size: 48),
                              ),
                            ),
                    ),
                    // 상단 오버레이: 뒤로 · LIVE·시청자 · QR/비번 버튼 (상단 고정)
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
                        data: _roomId,
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
