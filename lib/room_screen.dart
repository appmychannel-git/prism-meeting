import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
// ChatMessage 는 우리 chat_panel.dart 의 것을 사용 (LiveKit 동명 클래스는 숨김)
import 'package:livekit_client/livekit_client.dart' hide ChatMessage;
import 'package:wakelock_plus/wakelock_plus.dart';

import 'chat_panel.dart';
import 'config.dart';
import 'connection_service.dart';

/// 참가자 + 그 사람의 비디오 트랙(없을 수 있음) + 마이크/발언 상태 묶음.
class _Tile {
  final Participant participant;
  final VideoTrack? video;
  final bool micOn;
  final bool speaking;
  _Tile(this.participant, this.video,
      {this.micOn = false, this.speaking = false});
}

class RoomScreen extends StatefulWidget {
  final ConnectionDetails details;
  final String roomName;
  final String displayName;
  final String? pin; // 비공개 방이면 초대 링크에 포함
  final bool isHost; // 방을 만든 사람(방장) → 나가면 방 종료

  const RoomScreen({
    super.key,
    required this.details,
    required this.roomName,
    required this.displayName,
    this.pin,
    this.isHost = false,
  });

  @override
  State<RoomScreen> createState() => _RoomScreenState();
}

class _RoomScreenState extends State<RoomScreen> {
  final Room _room = Room(
    roomOptions: const RoomOptions(
      // 아래 3개가 Zoom과 같은 원리의 다자간 최적화 핵심:
      adaptiveStream: true, // 화면에 안 보이는/작은 영상은 저화질로 자동 조절
      dynacast: true, // 아무도 안 보는 화질 레이어는 송신 중단(대역폭 절약)
      defaultVideoPublishOptions: VideoPublishOptions(
        simulcast: true, // 고/중/저 화질 동시 송신 → 수신자별 최적 화질 선택
        // 코덱을 H.264로 고정. VP8은 저가 안드로이드TV/박스(예: MediaTek)의
        // 하드웨어 디코더가 지원 안 해 영상이 안 나오거나 프리즈되는 경우가 있다.
        // H.264는 하드웨어 디코더 지원이 가장 넓다.
        videoCodec: 'h264',
      ),
    ),
  );

  late final EventsListener<RoomEvent> _listener = _room.createListener();
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  Timer? _rebuildTimer;

  bool _micOn = true;
  bool _camOn = true;
  bool _connecting = true;
  bool _reconnecting = false; // 네트워크 재연결 중
  String? _error;

  // ---- 채팅 상태 ----
  static const String _chatTopic = 'chat';
  final List<ChatMessage> _messages = [];
  int _unread = 0;
  bool _chatOpen = false;

  // ---- 발표자 뷰 상태 ----
  bool _speakerView = false; // false=갤러리, true=발표자 뷰
  int _page = 0; // 갤러리 페이지(참가자 많을 때)
  String? _pinnedIdentity; // 사용자가 고정한 참가자
  String? _spotlightIdentity; // 최근 발언자(자동 스포트라이트)

  // 저사양/디코더 고장 기기(예: D23)용: 영상 수신을 꺼서 디코딩 부하를 없앤다.
  // false면 원격 영상을 구독 해제하고 아바타만 표시 → 프리즈 방지.
  bool _receiveVideo = true;

  @override
  void initState() {
    super.initState();
    // 회의 중에는 화면이 꺼지지 않게 유지 (입장 화면에서는 적용 안 됨 → 정상 화면보호기)
    WakelockPlus.enable();
    _room.addListener(_onRoomChange);
    _setupListeners();
    _connect();
  }

  @override
  void dispose() {
    WakelockPlus.disable(); // 회의 나가면 화면 유지 해제
    _rebuildTimer?.cancel();
    _room.removeListener(_onRoomChange);
    _listener.dispose();
    _room.dispose();
    super.dispose();
  }

  void _onRoomChange() {
    // 이벤트 폭주(오디오 레벨/트랙 갱신 등)를 ~200ms 단위로 묶어 rebuild.
    // 저사양 기기(소프트웨어 디코딩 중인 D23 등)에서 잦은 rebuild가 메인 스레드를
    // 막아 ANR/프리즈가 나는 것을 완화한다.
    if (!mounted) return;
    if (_rebuildTimer?.isActive ?? false) return;
    _rebuildTimer = Timer(const Duration(milliseconds: 200), () {
      if (mounted) setState(() {});
    });
  }

  void _setupListeners() {
    _listener
      ..on<RoomDisconnectedEvent>((e) {
        // 방장(host)이 회의를 종료해 튕긴 경우 안내 (본인이 나간 게 아닐 때만)
        final endedByHost =
            !widget.isHost && e.reason == DisconnectReason.roomDeleted;
        _exitToJoin(notice: endedByHost ? '호스트가 회의를 종료했습니다.' : null);
      })
      ..on<RoomReconnectingEvent>((_) {
        if (mounted) setState(() => _reconnecting = true);
      })
      ..on<RoomReconnectedEvent>((_) {
        if (mounted) setState(() => _reconnecting = false);
      })
      ..on<ParticipantConnectedEvent>((_) => _onRoomChange())
      ..on<ParticipantDisconnectedEvent>((_) => _onRoomChange())
      ..on<TrackSubscribedEvent>((_) => _onRoomChange())
      ..on<TrackUnsubscribedEvent>((_) => _onRoomChange())
      ..on<TrackPublishedEvent>((_) {
        // 저사양 모드 중 새 참가자가 영상을 올리면 즉시 구독 해제
        if (!_receiveVideo) _applyVideoSubscription();
        _onRoomChange();
      })
      ..on<TrackMutedEvent>((_) => _onRoomChange())
      ..on<TrackUnmutedEvent>((_) => _onRoomChange())
      ..on<ActiveSpeakersChangedEvent>((_) {
        final speakers = _room.activeSpeakers;
        if (speakers.isNotEmpty) _spotlightIdentity = speakers.first.identity;
        _onRoomChange();
      })
      ..on<DataReceivedEvent>(_onDataReceived);
  }

  // 다른 참가자가 보낸 채팅 수신 (LiveKit 데이터 채널)
  void _onDataReceived(DataReceivedEvent e) {
    if (e.topic != _chatTopic) return;
    try {
      final m = jsonDecode(utf8.decode(e.data)) as Map<String, dynamic>;
      final sender =
          (m['sender'] ?? e.participant?.identity ?? '상대').toString();
      final text = (m['text'] ?? '').toString();
      if (text.isEmpty) return;
      _addMessage(ChatMessage(sender: sender, text: text, mine: false));
    } catch (_) {
      // 형식이 안 맞는 데이터는 무시
    }
  }

  void _addMessage(ChatMessage m) {
    if (!mounted) return;
    setState(() {
      _messages.add(m);
      if (!m.mine && !_chatOpen) _unread++;
    });
  }

  // 채팅 전송 (같은 방 모든 참가자에게)
  Future<void> _sendChat(String text) async {
    final payload = utf8.encode(jsonEncode({
      'sender': widget.displayName,
      'text': text,
    }));
    // 내 화면에는 즉시 표시 (publishData는 발신자에게 되돌아오지 않음)
    _addMessage(ChatMessage(sender: widget.displayName, text: text, mine: true));
    try {
      await _room.localParticipant?.publishData(
        payload,
        reliable: true,
        topic: _chatTopic,
      );
    } catch (_) {
      // 전송 실패는 조용히 무시 (프로토타입)
    }
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

    // 방 접속 성공 → 즉시 회의 화면 표시.
    if (mounted) setState(() => _connecting = false);

    // 카메라/마이크는 실패하거나 오래 걸려도 회의 진입을 막지 않는다.
    // (카메라 없는/고장난 기기 = TV·미디어박스에서 흔함. 그 경우 아바타로 참여)
    _enableLocalDevices();
  }

  Future<void> _enableLocalDevices() async {
    final lp = _room.localParticipant;
    if (lp == null) return;
    try {
      await lp.setCameraEnabled(true).timeout(const Duration(seconds: 8));
    } catch (_) {
      if (mounted) setState(() => _camOn = false);
    }
    try {
      await lp.setMicrophoneEnabled(true).timeout(const Duration(seconds: 8));
    } catch (_) {
      if (mounted) setState(() => _micOn = false);
    }
  }

  // ---- 참가자 타일 목록 구성 (로컬을 맨 앞에) ----
  List<_Tile> _buildTiles() {
    final tiles = <_Tile>[];

    VideoTrack? firstVideo(Iterable<TrackPublication> pubs) {
      if (!_receiveVideo) return null; // 저사양 모드: 영상 대신 아바타
      for (final pub in pubs) {
        // 카메라가 꺼지면(음소거) 마지막 프레임이 멈추거나 검게 남는다.
        // 이 경우 영상 대신 아바타를 보이도록 여기서 제외한다.
        if (pub.muted) continue;
        final t = pub.track;
        if (t is VideoTrack) return t;
      }
      return null;
    }

    // 오디오 트랙이 하나라도 켜져(음소거 아님) 있으면 마이크 ON.
    bool micOn(Participant p) {
      for (final pub in p.audioTrackPublications) {
        if (!pub.muted) return true;
      }
      return false;
    }

    _Tile toTile(Participant p) => _Tile(
          p,
          firstVideo(p.videoTrackPublications),
          micOn: micOn(p),
          speaking: p.isSpeaking,
        );

    final lp = _room.localParticipant;
    if (lp != null) tiles.add(toTile(lp));
    for (final p in _room.remoteParticipants.values) {
      tiles.add(toTile(p));
    }
    return tiles;
  }

  Future<void> _toggleMic() async {
    final next = !_micOn;
    setState(() => _micOn = next); // 낙관적 갱신 (버튼 즉시 반응)
    try {
      await _room.localParticipant
          ?.setMicrophoneEnabled(next)
          .timeout(const Duration(seconds: 8));
    } catch (_) {
      if (mounted) setState(() => _micOn = !next); // 실패 시 되돌림
    }
  }

  Future<void> _toggleCam() async {
    final next = !_camOn;
    setState(() => _camOn = next);
    try {
      await _room.localParticipant
          ?.setCameraEnabled(next)
          .timeout(const Duration(seconds: 8));
    } catch (_) {
      if (mounted) setState(() => _camOn = !next);
    }
  }

  bool _leaving = false;

  /// 회의 화면을 닫고 입장 화면으로 돌아간다.
  /// disconnect 시 _leave 와 RoomDisconnectedEvent 양쪽에서 불릴 수 있으므로
  /// 가드로 딱 한 번만 pop 되게 한다. (두 번 pop 되면 입장 화면까지 닫혀 앱 종료됨)
  void _exitToJoin({String? notice}) {
    if (_leaving) return;
    _leaving = true;
    if (!mounted) return;
    if (notice != null) {
      // 안내 다이얼로그 → 확인 시 입장 화면으로
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Text('회의 종료'),
          content: Text(notice),
          actions: [
            FilledButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('확인')),
          ],
        ),
      ).whenComplete(() {
        if (mounted) Navigator.of(context).maybePop();
      });
    } else {
      Navigator.of(context).maybePop();
    }
  }

  // 나가기 버튼: 방장이면 종료 확인, 아니면 바로 나감
  Future<void> _onLeavePressed() async {
    if (widget.isHost) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('회의 종료'),
          content: const Text('회의를 종료하면 모든 참가자가 나가게 됩니다. 종료할까요?'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('취소')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('종료')),
          ],
        ),
      );
      if (ok != true) return;
    }
    await _leave();
  }

  Future<void> _leave() async {
    // 방장이면 서버에 방 삭제 요청(전원 퇴장)
    if (widget.isHost) {
      await ConnectionService.endRoom(
        tokenServerUrl: AppConfig.tokenServerUrl,
        roomName: widget.roomName,
        identity: AppConfig.deviceIdentity,
      );
    }
    await _room.disconnect();
    _exitToJoin();
  }

  // 초대 링크를 클립보드에 복사 (참여자에게 전달 → 클릭하면 이 방으로 입장)
  Future<void> _copyInviteLink() async {
    final link = AppConfig.inviteLink(widget.roomName, pin: widget.pin);
    await Clipboard.setData(ClipboardData(text: link));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('초대 링크 복사됨 (방: ${widget.roomName})')),
      );
    }
  }

  // 저사양 모드 토글: 원격 영상 구독을 켜고/끈다.
  Future<void> _toggleReceiveVideo() async {
    setState(() => _receiveVideo = !_receiveVideo);
    await _applyVideoSubscription();
  }

  Future<void> _applyVideoSubscription() async {
    for (final p in _room.remoteParticipants.values) {
      for (final pub in p.videoTrackPublications) {
        try {
          if (_receiveVideo) {
            await pub.subscribe();
          } else {
            await pub.unsubscribe();
          }
        } catch (_) {}
      }
    }
  }

  /// 발표자 뷰: 메인(고정한 사람 > 최근 발언자 > 첫 번째)을 크게 + 하단 썸네일.
  Widget _buildSpeakerView(List<_Tile> tiles) {
    if (tiles.isEmpty) {
      return const Center(child: Text('참가자를 기다리는 중...'));
    }
    _Tile? byId(String? id) {
      if (id == null) return null;
      for (final t in tiles) {
        if (t.participant.identity == id) return t;
      }
      return null;
    }

    final main =
        byId(_pinnedIdentity) ?? byId(_spotlightIdentity) ?? tiles.first;
    final others = tiles
        .where((t) => t.participant.identity != main.participant.identity)
        .toList();

    return Column(
      children: [
        Expanded(
          child: InkWell(
            // 리모컨/탭으로 고정 해제 (포커스 가능)
            onTap: () {
              if (_pinnedIdentity != null) {
                setState(() => _pinnedIdentity = null);
              }
            },
            borderRadius: BorderRadius.circular(12),
            child: Stack(
              children: [
                Positioned.fill(child: _ParticipantTile(tile: main)),
                if (_pinnedIdentity != null)
                  Positioned(
                    right: 8,
                    top: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.push_pin, size: 14, color: Colors.white),
                          SizedBox(width: 4),
                          Text('고정됨 · 탭하여 해제',
                              style: TextStyle(
                                  fontSize: 12, color: Colors.white)),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (others.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: SizedBox(
              height: 96,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: others.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (_, i) {
                  final t = others[i];
                  return InkWell(
                    // 리모컨/탭으로 이 사람 크게 고정 (포커스 가능)
                    onTap: () => setState(
                        () => _pinnedIdentity = t.participant.identity),
                    borderRadius: BorderRadius.circular(12),
                    focusColor: Colors.white24,
                    child: AspectRatio(
                      aspectRatio: 16 / 10,
                      child: _ParticipantTile(tile: t),
                    ),
                  );
                },
              ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final isTv = size.width >= AppConfig.tvBreakpointWidth;

    if (_connecting) {
      return const Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('회의에 접속하는 중...'),
            ],
          ),
        ),
      );
    }

    if (_error != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline,
                    size: 48, color: Color(0xFFFF8A80)),
                const SizedBox(height: 12),
                Text(_error!, textAlign: TextAlign.center),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: const Text('돌아가기'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final allTiles = _buildTiles();
    // 갤러리 페이지네이션: 한 페이지에 maxVisibleTiles(6)명씩 → 저사양 기기 렌더 부하 고정.
    final perPage = AppConfig.maxVisibleTiles;
    final pageCount = (allTiles.length / perPage).ceil().clamp(1, 9999);
    if (_page >= pageCount) _page = pageCount - 1; // 인원 줄면 페이지 보정
    if (_page < 0) _page = 0;
    final pageTiles =
        allTiles.skip(_page * perPage).take(perPage).toList();

    return Scaffold(
      key: _scaffoldKey,
      onEndDrawerChanged: (open) {
        setState(() {
          _chatOpen = open;
          if (open) _unread = 0;
        });
      },
      endDrawer: Drawer(
        width: isTv ? 420 : 320,
        child: ChatPanel(messages: _messages, onSend: _sendChat),
      ),
      appBar: AppBar(
        title: Text('${widget.roomName}  ·  ${allTiles.length}명'),
        actions: [
          IconButton(
            tooltip: '초대 링크 복사',
            onPressed: _copyInviteLink,
            icon: const Icon(Icons.link),
          ),
          IconButton(
            tooltip: _receiveVideo ? '영상 수신 끄기(저사양 기기용)' : '영상 수신 켜기',
            onPressed: _toggleReceiveVideo,
            icon: Icon(_receiveVideo ? Icons.visibility : Icons.visibility_off),
          ),
          IconButton(
            tooltip: _speakerView ? '갤러리 뷰' : '발표자 뷰',
            onPressed: () => setState(() => _speakerView = !_speakerView),
            icon: Icon(_speakerView ? Icons.grid_view : Icons.view_sidebar),
          ),
          IconButton(
            tooltip: '채팅',
            onPressed: () => _scaffoldKey.currentState?.openEndDrawer(),
            icon: Badge.count(
              count: _unread,
              isLabelVisible: _unread > 0,
              child: const Icon(Icons.chat_bubble_outline),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // 네트워크 재연결 중 배너 (자동 복구 시도 중임을 표시)
          if (_reconnecting)
            Container(
              width: double.infinity,
              color: const Color(0xFFB45309),
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  ),
                  SizedBox(width: 10),
                  Text('네트워크 재연결 중...',
                      style: TextStyle(color: Colors.white, fontSize: 13)),
                ],
              ),
            ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: _speakerView
                  ? _buildSpeakerView(allTiles) // 발표자 뷰: 전체 중 발언자를 메인에
                  : _VideoGrid(tiles: pageTiles, isTv: isTv),
            ),
          ),
          // 갤러리 페이지 이동 (참가자가 한 페이지보다 많을 때)
          if (!_speakerView && pageCount > 1)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    tooltip: '이전',
                    onPressed:
                        _page > 0 ? () => setState(() => _page--) : null,
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Text('${_page + 1} / $pageCount',
                      style: const TextStyle(fontSize: 14)),
                  IconButton(
                    tooltip: '다음',
                    onPressed: _page < pageCount - 1
                        ? () => setState(() => _page++)
                        : null,
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
            ),
          _ControlBar(
            micOn: _micOn,
            camOn: _camOn,
            isHost: widget.isHost,
            onMic: _toggleMic,
            onCam: _toggleCam,
            onLeave: _onLeavePressed,
          ),
        ],
      ),
    );
  }
}

/// Zoom 갤러리처럼 "스크롤 없이 화면에 꽉 채우는" 그리드.
/// 참가자 수 + 화면 방향(가로/세로)에 맞춰 행·열을 계산해 모든 타일이 보이게 한다.
/// (TV는 D-pad로 스크롤이 어려우므로 스크롤 대신 꽉 채우는 방식이 필수)
class _VideoGrid extends StatelessWidget {
  final List<_Tile> tiles;
  final bool isTv;
  const _VideoGrid({required this.tiles, required this.isTv});

  /// 화면 방향을 고려한 열 개수.
  int _columns(int n, bool portrait) {
    if (n <= 1) return 1;
    if (portrait) {
      // 세로(폰): 2명은 위아래로, 그 이상은 2열
      if (n <= 2) return 1;
      return 2;
    } else {
      // 가로(TV/데스크탑): 넓게 펼침
      if (n <= 2) return 2;
      if (n <= 4) return 2;
      if (n <= 6) return 3;
      if (n <= 9) return 3;
      return 4;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (tiles.isEmpty) {
      return const Center(child: Text('참가자를 기다리는 중...'));
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final portrait = constraints.maxHeight > constraints.maxWidth;
        final n = tiles.length;
        final cols = _columns(n, portrait);
        final rows = (n / cols).ceil();
        return Column(
          children: List.generate(rows, (r) {
            return Expanded(
              child: Row(
                children: List.generate(cols, (c) {
                  final i = r * cols + c;
                  if (i >= n) {
                    // 마지막 줄 빈 칸: 나머지 타일 크기를 일정하게 유지
                    return const Expanded(child: SizedBox());
                  }
                  return Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: _ParticipantTile(tile: tiles[i]),
                    ),
                  );
                }),
              ),
            );
          }),
        );
      },
    );
  }
}

class _ParticipantTile extends StatelessWidget {
  final _Tile tile;
  const _ParticipantTile({required this.tile});

  @override
  Widget build(BuildContext context) {
    final p = tile.participant;
    final name = p.name.isNotEmpty ? p.name : (p.identity);
    final isLocal = p is LocalParticipant;
    final hasVideo = tile.video != null;

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        // 말하는 사람은 초록 테두리로 강조
        border: tile.speaking
            ? Border.all(color: const Color(0xFF4ADE80), width: 3)
            : null,
      ),
      child: ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Container(
        color: const Color(0xFF1A1F27),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (hasVideo)
              VideoTrackRenderer(
                tile.video!,
                // 거울 반전 끔: 내 미리보기와 상대가 받는 영상을 동일한
                // 실제 방향으로 통일 (기본값 auto는 내 화면만 좌우 반전됨)
                mirrorMode: VideoViewMirrorMode.off,
              )
            else
              Center(
                child: CircleAvatar(
                  radius: 32,
                  backgroundColor: const Color(0xFF2E3742),
                  child: Text(
                    name.isNotEmpty ? name.characters.first.toUpperCase() : '?',
                    style: const TextStyle(fontSize: 28),
                  ),
                ),
              ),
            Positioned(
              left: 8,
              bottom: 8,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 마이크 on/off 아이콘 (꺼짐이면 빨간 mic_off)
                    Icon(
                      tile.micOn ? Icons.mic : Icons.mic_off,
                      size: 14,
                      color: tile.micOn
                          ? Colors.white
                          : const Color(0xFFFF6B6B),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      isLocal ? '$name (나)' : name,
                      style:
                          const TextStyle(fontSize: 13, color: Colors.white),
                    ),
                  ],
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

/// 하단 컨트롤 바. 큰 버튼 + 포커스 가능 → 안드로이드TV 리모컨(D-pad) 대응.
class _ControlBar extends StatelessWidget {
  final bool micOn;
  final bool camOn;
  final bool isHost;
  final VoidCallback onMic;
  final VoidCallback onCam;
  final VoidCallback onLeave;

  const _ControlBar({
    required this.micOn,
    required this.camOn,
    required this.isHost,
    required this.onMic,
    required this.onCam,
    required this.onLeave,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _RoundButton(
              icon: micOn ? Icons.mic : Icons.mic_off,
              label: micOn ? '음소거' : '해제',
              active: micOn,
              autofocus: true, // 회의 진입 시 리모컨 시작 포커스
              onTap: onMic,
            ),
            const SizedBox(width: 20),
            _RoundButton(
              icon: camOn ? Icons.videocam : Icons.videocam_off,
              label: camOn ? '카메라 끄기' : '카메라 켜기',
              active: camOn,
              onTap: onCam,
            ),
            const SizedBox(width: 20),
            _RoundButton(
              icon: Icons.call_end,
              label: isHost ? '회의 종료' : '나가기',
              active: true,
              danger: true,
              onTap: onLeave,
            ),
          ],
        ),
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final bool danger;
  final bool autofocus;
  final VoidCallback onTap;

  const _RoundButton({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
    this.danger = false,
    this.autofocus = false,
  });

  @override
  Widget build(BuildContext context) {
    final bg = danger
        ? const Color(0xFFE5484D)
        : (active ? const Color(0xFF2E3742) : const Color(0xFF3A2E2E));
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: bg,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            autofocus: autofocus,
            // 리모컨(D-pad) 포커스가 잘 보이도록 강한 하이라이트
            focusColor: Colors.white.withValues(alpha: 0.45),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Icon(icon, size: 28, color: Colors.white),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(label, style: const TextStyle(fontSize: 12)),
      ],
    );
  }
}
