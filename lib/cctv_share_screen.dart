import 'dart:math';

import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'config.dart';
import 'connection_service.dart';
import 'l10n.dart';

/// CCTV 공유(카메라) 화면 — 이 기기 카메라를 송출한다.
/// 이 화면을 켜둔 동안만 송출(나가면 종료). QR(코드)+비밀번호로 시청자가 접속.
class CctvShareScreen extends StatefulWidget {
  const CctvShareScreen({super.key});
  @override
  State<CctvShareScreen> createState() => _CctvShareScreenState();
}

class _CctvShareScreenState extends State<CctvShareScreen> {
  final Room _room = Room(
    roomOptions: const RoomOptions(
      adaptiveStream: true,
      dynacast: true,
      defaultVideoPublishOptions:
          VideoPublishOptions(simulcast: true, videoCodec: 'h264'),
    ),
  );
  late final EventsListener<RoomEvent> _listener = _room.createListener();

  late final String _code; // 표시/입력용 코드(cctv- 제외)
  late final String _roomId; // 실제 방 이름 cctv-<code>
  late final String _pin;
  bool _connecting = true;
  String? _error;
  int _viewers = 0;

  @override
  void initState() {
    super.initState();
    _code = AppConfig.generateRoomCode();
    _roomId = 'cctv-$_code';
    _pin = (1000 + Random().nextInt(9000)).toString(); // 4자리
    WakelockPlus.enable();
    _listener
      ..on<ParticipantConnectedEvent>((_) => _updateViewers())
      ..on<ParticipantDisconnectedEvent>((_) => _updateViewers());
    _connect();
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    _listener.dispose();
    _room.dispose();
    super.dispose();
  }

  void _updateViewers() {
    if (mounted) setState(() => _viewers = _room.remoteParticipants.length);
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
      appBar: AppBar(title: Text(L.t('cctv_share'))),
      body: _connecting
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_error!, textAlign: TextAlign.center),
                  ),
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // 내 카메라 미리보기
                      AspectRatio(
                        aspectRatio: 16 / 9,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Container(
                            color: const Color(0xFF1A1F27),
                            child: _localCam() != null
                                ? VideoTrackRenderer(_localCam()!,
                                    fit: VideoViewFit.cover)
                                : const Center(
                                    child: Icon(Icons.videocam_off,
                                        color: Colors.white38, size: 40)),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        L.t('cctv_viewers', {'n': '$_viewers'}),
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white54),
                      ),
                      const SizedBox(height: 16),
                      // QR + 코드 + 비밀번호
                      Center(
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: SizedBox(
                            width: 190,
                            height: 190,
                            child: PrettyQrView.data(
                              data: _roomId,
                              decoration: const PrettyQrDecoration(
                                shape: PrettyQrSmoothSymbol(
                                    color: Color(0xFF000000)),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      _kv(L.t('cctv_code'), _code),
                      const SizedBox(height: 8),
                      _kv(L.t('cctv_password'), _pin),
                      const SizedBox(height: 16),
                      Text(
                        L.t('cctv_share_hint'),
                        textAlign: TextAlign.center,
                        style:
                            const TextStyle(fontSize: 13, color: Colors.white70),
                      ),
                    ],
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
