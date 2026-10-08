import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show FilteringTextInputFormatter, MethodChannel, MissingPluginException;
import 'package:livekit_client/livekit_client.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:vibration/vibration.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'app_settings.dart';
import 'cctv_store.dart';
import 'config.dart';
import 'confirm_dialog.dart';
import 'connection_service.dart';
import 'device_id.dart';
import 'device_quirks.dart';
import 'directory.dart';
import 'l10n.dart';
import 'push_service.dart';

/// CCTV 공유(카메라) 화면 — 이 기기 카메라를 송출한다.
/// 이 화면을 켜둔 동안만 송출(나가면 종료). QR(코드)+비밀번호로 시청자가 접속.
class CctvShareScreen extends StatefulWidget {
  const CctvShareScreen({super.key, this.promptPassword = true});

  /// 수동으로 "이 기기를 CCTV로 공유"를 눌러 열렸을 땐 true → 송출 전 비밀번호
  /// 입력/설정 창을 띄운다. 원격 켜기(FCM)로 열렸을 땐 false → 저장된 비번으로 바로 송출.
  final bool promptPassword;

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
  String _name = ''; // 이 기기 이름(QR에 담아 시청자 목록에 표시)
  String _roomId = ''; // 실제 방 이름 cctv-<code>
  String _pin = ''; // 대표 비번(e2ee 키/표시용) = 활성 그룹 중 첫 번째
  List<String> _pins = []; // 활성 그룹들의 비번 집합(서버로 전송)
  bool _connecting = true;
  String? _error;
  bool _camError = false; // 카메라 사용 불가(송출 불가) — '다시 시도' 버튼 표시용
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
    // 이 기기의 고정 코드 + 활성 그룹(코드)들의 비번 집합.
    final (code, _) = await CctvStore.myShareCredentials();
    _code = code;
    _name = await DeviceId.name();
    _roomId = 'cctv-$code';
    _pins = await CctvStore.enabledSharePins();
    // 활성 코드가 없으면: 수동 공유면 첫 코드 추가를 유도, 그래도 없으면 닫는다.
    if (_pins.isEmpty) {
      if (widget.promptPassword) {
        await _promptAddFirstCode();
        _pins = await CctvStore.enabledSharePins();
      }
      if (_pins.isEmpty) {
        if (mounted) Navigator.of(context).maybePop();
        return;
      }
    }
    // 이름·비번을 디렉터리에 게시(코드 추가 시 이름 표시 + 원격 깨우기 비번 대조용).
    DirectoryService.updateCctvPins(code, _pins, name: _name);
    _pin = _pins.first; // e2ee 키/표시용 대표 비번
    // E2EE(옵션): 대표 비번을 공유키로.
    final e2ee = (AppConfig.e2ee && _pin.isNotEmpty)
        ? await E2EEOptions.sharedKey('$_roomId:$_pin')
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

  // 활성 코드가 하나도 없을 때(첫 사용) 첫 코드(이름+비번)를 바로 추가하도록 유도.
  Future<void> _promptAddFirstCode() async {
    final nameCtrl = TextEditingController();
    final pinCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text(L.t('cctv_add_code')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${L.t('cctv_code')}: $_code',
                style: const TextStyle(fontSize: 12, color: Colors.white54)),
            const SizedBox(height: 10),
            TextField(
              controller: nameCtrl,
              maxLength: 20,
              decoration: InputDecoration(
                labelText: L.t('cctv_code_name'),
                hintText: L.t('cctv_code_name_hint'),
                border: const OutlineInputBorder(),
                counterText: '',
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: pinCtrl,
              keyboardType: TextInputType.number,
              maxLength: 6,
              obscureText: true,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                labelText: L.t('cctv_password'),
                hintText: L.t('cctv_pw_hint6'),
                border: const OutlineInputBorder(),
                counterText: '',
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(L.t('cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(L.t('cctv_start'))),
        ],
      ),
    );
    final name = nameCtrl.text.trim();
    final pin = pinCtrl.text.trim();
    nameCtrl.dispose();
    pinCtrl.dispose();
    // 비밀번호는 숫자 6자리 고정.
    if (ok == true && RegExp(r'^\d{6}$').hasMatch(pin)) {
      await CctvStore.addShareGroup(
          name.isNotEmpty ? name : L.t('cctv_code_default'), pin);
    }
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
        pins: _pins, // 활성 그룹들의 비번 집합(서버가 meta.pins 로 저장)
        create: true,
      );
      await _room.connect(d.serverUrl, d.token,
          connectOptions: const ConnectOptions(autoSubscribe: false));
      // 카메라만 송출(마이크는 끔). phantom-camera 기기에서 setCameraEnabled 가
      // 메인스레드를 블록해 멈추는 문제 방지 — 실패/멈춤이면 송출 중단 안내.
      if (!await _enableCamera()) {
        _failCamera();
        return;
      }
      // 카메라가 상하(180°) 반전되는 기기는 플래그를 알려 시청자가 회전해 바로잡게 한다.
      // (기기 자동 판정 + 설정 토글 오버라이드 = AppSettings.cameraFlip180)
      if (AppSettings.cameraFlip180) {
        try {
          await _room.localParticipant?.setAttributes(
            {DeviceQuirks.flipAttrKey: DeviceQuirks.flipAttrValue},
          );
        } catch (_) {}
      }
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

  // 카메라 켜기. 느린 USB 카메라도 켜지도록 timeout 을 넉넉히(40초) 준다.
  // (8초는 USB캠 초기화를 조기에 끊어 '카메라 없음'을 잘못 띄웠다.)
  // phantom-camera(카메라 없는데 feature 보고) 기기는 setCameraEnabled 가 네이티브
  // 메인스레드를 블록해 timeout 으로도 못 끊으므로, 켜기 전 CCTV 전용 플래그를 디스크에
  // 남겨(멈춘 채 강제종료돼도 다음 실행이 감지) 직전 멈춤 흔적이면 자동 시도를 건너뛴다
  // (연속 멈춤 방지 → '다시 시도'로만 재도전). 미팅 설정은 건드리지 않는다(앱 간 영향 차단).
  // 성공 true / 실패(타임아웃·오류·멈춤 이력) false.
  static const int _camTimeoutSec = 20;
  static const MethodChannel _nativeCh = MethodChannel('app/fullscreen');

  Future<bool> _enableCamera() async {
    // ⓪ 카메라 권한 확보 — 사전검사(probe)가 실제로 카메라를 열어보려면 권한이 필요하다.
    //    권한 없이 probe 하면 'unknown' 이 나와 사전검사가 무력화된다(=멈춤 재발).
    try {
      final st = await Permission.camera.request();
      if (!st.isGranted) return false; // 권한 없으면 송출 불가
    } catch (_) {}
    // ① 네이티브 사전검사(백그라운드 스레드로 카메라를 열어봄 — 메인스레드 비차단).
    //    'ok' 가 아니면(none/blocked/timeout/unknown) 또는 네이티브가 무응답(Dart 타임아웃)
    //    이면 setCameraEnabled 를 아예 호출하지 않아 멈춤 없이 "카메라 없음" 안내로 간다.
    //    (채널 미구현 구버전만 예외 — 아래 폴백 경로로)
    try {
      final probe = await _nativeCh
          .invokeMethod<String>('probeCamera', {'timeoutMs': 6000}).timeout(
        const Duration(seconds: 8),
      );
      if (probe != 'ok') return false;
    } on MissingPluginException {
      // 네이티브 메서드 없는 구버전 → 사전검사 생략하고 아래 기존 경로로.
    } catch (_) {
      // Dart 타임아웃(네이티브 무응답 = 카메라 못 엶) 등 → 송출 불가 안내.
      return false;
    }
    // ② 폴백 보호: 직전 멈춤 흔적이면 자동 시도 생략(연속 멈춤 방지, '다시 시도'로만).
    if (AppSettings.cctvCamAttemptPending) {
      await AppSettings.setCctvCamAttemptPending(false);
      return false;
    }
    await AppSettings.setCctvCamAttemptPending(true);
    var ok = true;
    try {
      await _room.localParticipant
          ?.setCameraEnabled(true)
          .timeout(const Duration(seconds: _camTimeoutSec));
    } catch (_) {
      ok = false;
    }
    await AppSettings.setCctvCamAttemptPending(false);
    return ok;
  }

  void _failCamera() {
    if (mounted) {
      setState(() {
        _connecting = false;
        _error = L.t('cctv_no_camera');
        _camError = true;
      });
    }
  }

  // 카메라 '다시 시도' — 멈춤 이력을 지우고 카메라를 재시도(사용자가 명시적으로 선택).
  // (여기서 또 멈추는 기기면 카메라가 실제로 없는 것 — 사용자 판단으로 재도전)
  Future<void> _retryCamera() async {
    await AppSettings.setCctvCamAttemptPending(false);
    if (!mounted) return;
    setState(() {
      _error = null;
      _camError = false;
      _connecting = true;
    });
    final ok = await _enableCamera();
    if (!ok) {
      _failCamera();
      return;
    }
    if (mounted) setState(() => _connecting = false);
    _updateViewers();
    showCctvLiveNotification(_room.remoteParticipants.length);
    _resetIdleTimer();
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

  // 뒤로가기 전 확인(송출이 중단됨을 알림). 확인하면 화면을 닫는다.
  // PopScope(canPop:false) 아래선 maybePop 이 다시 막히므로 pop()을 직접 호출한다.
  Future<void> _confirmExit() async {
    final nav = Navigator.of(context);
    // 연결 전/에러 상태면 바로 닫기.
    if (_connecting || _error != null) {
      nav.pop();
      return;
    }
    final ok = await confirmDialog(context, L.t('cctv_share_exit_confirm'),
        confirmLabel: L.t('cctv_share_exit_ok'));
    if (ok && mounted) nav.pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmExit();
      },
      child: Scaffold(
      backgroundColor: Colors.black,
      body: _connecting
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_camError)
                          const Icon(Icons.videocam_off_outlined,
                              size: 44, color: Color(0xFFFF8A80)),
                        if (_camError) const SizedBox(height: 12),
                        Text(_error!, textAlign: TextAlign.center),
                        const SizedBox(height: 20),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (_camError)
                              FilledButton.icon(
                                onPressed: _retryCamera,
                                icon: const Icon(Icons.refresh),
                                label: Text(L.t('retry')),
                              ),
                            if (_camError) const SizedBox(width: 12),
                            TextButton(
                              onPressed: () => Navigator.of(context).pop(),
                              child: Text(L.t('close')),
                            ),
                          ],
                        ),
                      ],
                    ),
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
                              ? (AppSettings.cameraFlip180
                                  ? RotatedBox(
                                      quarterTurns: 2,
                                      child: VideoTrackRenderer(_localCam()!,
                                          fit: VideoViewFit.cover,
                                          mirrorMode:
                                              VideoViewMirrorMode.off))
                                  : VideoTrackRenderer(_localCam()!,
                                      fit: VideoViewFit.cover,
                                      mirrorMode: VideoViewMirrorMode.off))
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
                            _overlayBtn(Icons.arrow_back, _confirmExit),
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

  // 송출 화면 QR 버튼: 기본(첫 활성) 코드의 QR만 보여준다.
  // (그룹별 QR 전체 관리는 홈의 'QR목록' 탭에서)
  Future<void> _showShareInfo() async {
    final groups = (await CctvStore.shareGroups())
        .where((g) => g.enabled && g.pin.isNotEmpty)
        .toList();
    if (!mounted || groups.isEmpty) return;
    final g = groups.first; // 기본 QR
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF0E1116),
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SingleChildScrollView(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
              20, 0, 20, MediaQuery.of(ctx).viewPadding.bottom + 56),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _groupQrCard(g),
              Text(
                L.t('cctv_share_hint'),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, color: Colors.white70),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // 그룹 하나의 QR 카드(이름 + 비번 내장 QR + 비번 텍스트).
  Widget _groupQrCard(CctvShareGroup g) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        children: [
          // 기기 이름(QR에 담겨 상대 목록에 표시됨).
          if (_name.isNotEmpty) ...[
            Text(_name,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 2),
          ],
          Text(g.name,
              style: const TextStyle(color: Colors.white70, fontSize: 14)),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
            ),
            child: SizedBox(
              width: 160,
              height: 160,
              child: PrettyQrView.data(
                data: AppConfig.cctvLink(_code, pin: g.pin, name: _name),
                decoration: const PrettyQrDecoration(
                  shape: PrettyQrSmoothSymbol(color: Color(0xFF000000)),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          _kv(L.t('cctv_password'), g.pin),
        ],
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
