import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
// ChatMessage 는 우리 chat_panel.dart 의 것을 사용 (LiveKit 동명 클래스는 숨김)
import 'package:livekit_client/livekit_client.dart' hide ChatMessage;
// 안드로이드 화면 캡처 권한 요청(Helper.requestCapturePermission)만 사용.
import 'package:flutter_webrtc/flutter_webrtc.dart' show Helper;
// 안드로이드 화면공유 유지용 mediaProjection 포그라운드 서비스.
import 'package:flutter_background/flutter_background.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'caption_overlay.dart';
import 'stt_platform.dart';
import 'chat_panel.dart';
import 'config.dart';
import 'connection_service.dart';
import 'translation_service.dart';

/// 음성 자막 발언 방식.
/// - continuous: 자막 켜면 계속 인식·송출(발표/회의)
/// - pushToTalk: '말하기' 버튼을 탭할 때만 한 문장 인식·송출(상담/통역)
enum CaptionMode { continuous, pushToTalk }

/// 참가자 + 그 사람의 비디오 트랙(없을 수 있음) + 마이크/발언 상태 묶음.
/// 한 참가자가 카메라와 화면공유를 동시에 올리면 타일이 2개가 된다
/// (카메라 타일 + [isScreenShare]=true 인 화면 타일).
class _Tile {
  final Participant participant;
  final VideoTrack? video;
  final bool micOn;
  final bool speaking;
  final bool isScreenShare;
  _Tile(
    this.participant,
    this.video, {
    this.micOn = false,
    this.speaking = false,
    this.isScreenShare = false,
  });

  /// 핀/스포트라이트 매칭용 고유 id. 화면공유 타일은 카메라 타일과 identity가
  /// 같으므로 접미사로 구분한다.
  String get id =>
      isScreenShare ? '${participant.identity}#screen' : participant.identity;
}

class RoomScreen extends StatefulWidget {
  final ConnectionDetails details;
  final String roomName;
  final String displayName;
  final String? pin; // 비공개 방이면 초대 링크에 포함
  final bool isHost; // 방을 만든 사람(방장) → 나가면 방 종료
  // 링크로 바로 입장한 경우 true → 입장 직후 이름 설정 팝업을 띄운다.
  final bool promptNameOnEnter;

  const RoomScreen({
    super.key,
    required this.details,
    required this.roomName,
    required this.displayName,
    this.pin,
    this.isHost = false,
    this.promptNameOnEnter = false,
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
      // ---- 오디오 음질 설정(회의 음질 우선) ----
      // 코덱은 Opus 단일. 비트레이트를 기본 48k → 96k로 올려 음성/공유오디오(탭 소리)
      // 모두 여유 있게. DTX(침묵 시 전송중단)·RED(패킷손실 대비 중복전송)는 유지.
      defaultAudioPublishOptions: AudioPublishOptions(
        encoding: AudioEncoding.presetMusicHighQuality, // 96kbps
        dtx: true,
        red: true,
      ),
      // 마이크 캡처 처리(기본값과 동일하나 의도를 명시): 노이즈억제·에코제거·자동게인·
      // 음성분리 모두 ON. 회의에서 목소리를 또렷하게 유지한다.
      defaultAudioCaptureOptions: AudioCaptureOptions(
        noiseSuppression: true,
        echoCancellation: true,
        autoGainControl: true,
        voiceIsolation: true,
        typingNoiseDetection: true,
      ),
    ),
  );

  late final EventsListener<RoomEvent> _listener = _room.createListener();
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  Timer? _rebuildTimer;

  bool _micOn = true;
  bool _camOn = true;
  bool _screenSharing = false; // 내가 화면공유 송출 중인가
  bool _shareBusy = false; // 화면공유 토글 진행 중(중복 탭 방지)
  bool _bgServiceOn = false; // 안드로이드 mediaProjection FGS 활성화됨
  bool _connecting = true;
  bool _reconnecting = false; // 네트워크 재연결 중
  String? _error;

  // 표시 이름(입장 후 팝업으로 변경 가능). 채팅 발신자/타일 이름에 사용.
  late String _displayName = widget.displayName;

  // ---- 채팅 상태 ----
  static const String _chatTopic = 'chat';
  final List<ChatMessage> _messages = [];
  int _unread = 0;
  bool _chatOpen = false;
  // 받은 메시지를 번역할 대상(선호) 언어. ''=사용 안 함(기본). 언어 선택 시 자동 번역.
  String _targetLang = AppConfig.targetLanguage;

  // ---- 음성 자막 상태 ----
  static const String _captionTopic = 'caption';
  final PlatformStt _speech = PlatformStt(); // 웹=브라우저 STT, 모바일=speech_to_text
  bool _speechAvailable = false; // STT 초기화 성공(기기/브라우저 지원) 여부
  bool _captionsOn = false; // 자막 켬(내 발화 송출 + 오버레이 표시)
  // 내 언어: STT 인식 언어(내 발화) + 자막 번역 대상(내가 읽을 언어)로 동시 사용.
  late String _myLang = _defaultMyLang();
  final List<LiveCaption> _captionLog = []; // 확정된 자막 줄 누적(최근 N줄 표시)
  final Map<String, LiveCaption> _liveCaptions = {}; // identity -> 말하는 중(중간)
  DateTime? _lastInterimSentAt; // 중간 결과 송출 throttle
  CaptionMode _captionMode = CaptionMode.continuous; // 발언 방식
  bool _pttActive = false; // '눌러 말하기' 캡처 진행 중
  static const int _maxCaptionLines = 8; // 화면에 표시할 자막 줄 수(최대)

  // 발화 언어(2-letter) → STT 로케일 ID.
  static const Map<String, String> _sttLocales = {
    'ko': 'ko_KR', 'en': 'en_US', 'ru': 'ru_RU', 'kk': 'kk_KZ',
    'fr': 'fr_FR', 'ja': 'ja_JP', 'zh': 'zh_CN', 'es': 'es_ES',
    'de': 'de_DE', 'ar': 'ar_SA', 'rw': 'rw_RW',
  };

  String _defaultMyLang() {
    final code = WidgetsBinding.instance.platformDispatcher.locale.languageCode
        .toLowerCase();
    return AppConfig.supportedLanguages.containsKey(code) ? code : 'ko';
  }

  // ---- 발표자 뷰 상태 ----
  bool _speakerView = false; // false=갤러리, true=발표자 뷰
  int _page = 0; // 갤러리 페이지(참가자 많을 때)
  String? _pinnedTileId; // 사용자가 고정한 타일(_Tile.id: 카메라 또는 화면)
  String? _spotlightIdentity; // 최근 발언자(자동 스포트라이트, identity=카메라 타일 id)

  // 저사양/디코더 고장 기기(예: D23)용: 영상 수신을 꺼서 디코딩 부하를 없앤다.
  // false면 원격 영상을 구독 해제하고 아바타만 표시 → 프리즈 방지.
  bool _receiveVideo = true;

  // ---- 카메라 선택(USB 외장 웹캠 포함) ----
  // Camera2가 외장(USB) 카메라를 노출하는 기기에서, 목록 열거 후 선택/전환.
  // 내장 카메라 없는 TV는 USB 카메라를 자동으로 잡는다.
  List<MediaDevice> _cameras = [];
  String? _currentCameraId;
  StreamSubscription<List<MediaDevice>>? _deviceSub;

  @override
  void initState() {
    super.initState();
    // 회의 중에는 화면이 꺼지지 않게 유지 (입장 화면에서는 적용 안 됨 → 정상 화면보호기)
    WakelockPlus.enable();
    _room.addListener(_onRoomChange);
    _setupListeners();
    // USB 카메라 연결/해제(핫플러그) 시 카메라 목록 갱신
    _deviceSub = Hardware.instance.onDeviceChange.stream.listen((_) {
      _loadCameras();
    });
    _initSpeech();
    _connect();
  }

  @override
  void dispose() {
    WakelockPlus.disable(); // 회의 나가면 화면 유지 해제
    _stopBackgroundService(); // 화면공유 포그라운드 서비스 정리
    _deviceSub?.cancel();
    _rebuildTimer?.cancel();
    if (_speechAvailable) _speech.stop();
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
      ..on<LocalTrackPublishedEvent>((_) => _syncScreenShareState())
      ..on<LocalTrackUnpublishedEvent>((_) {
        // 브라우저 "공유 중지" 바나 안드로이드 알림에서 직접 끈 경우도 여기로 온다.
        _syncScreenShareState();
      })
      ..on<ParticipantNameUpdatedEvent>((_) => _onRoomChange()) // 이름 변경 반영
      ..on<ActiveSpeakersChangedEvent>((_) {
        final speakers = _room.activeSpeakers;
        if (speakers.isNotEmpty) _spotlightIdentity = speakers.first.identity;
        _onRoomChange();
      })
      ..on<DataReceivedEvent>(_onDataReceived);
  }

  // 다른 참가자가 보낸 채팅 수신 (LiveKit 데이터 채널)
  void _onDataReceived(DataReceivedEvent e) {
    if (e.topic == _captionTopic) {
      _onCaptionReceived(e);
      return;
    }
    if (e.topic != _chatTopic) return;
    try {
      final m = jsonDecode(utf8.decode(e.data)) as Map<String, dynamic>;
      final sender = (m['sender'] ?? e.participant?.identity ?? '상대')
          .toString();
      final text = (m['text'] ?? '').toString();
      if (text.isEmpty) return;
      final msg = ChatMessage(sender: sender, text: text, mine: false);
      _addMessage(msg);
      // 언어가 선택돼 있으면 받은 즉시 자동 번역(탭 불필요).
      if (_targetLang.isNotEmpty) _translateMessage(msg);
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
    final payload = utf8.encode(
      jsonEncode({'sender': _displayName, 'text': text}),
    );
    // 내 화면에는 즉시 표시 (publishData는 발신자에게 되돌아오지 않음)
    _addMessage(ChatMessage(sender: _displayName, text: text, mine: true));
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

  // 번역 대상 언어 변경(채팅 패널 드롭다운). AppConfig에도 반영.
  // 언어를 고르면 기존에 받은 메시지들도 그 언어로 자동 번역한다.
  void _changeTargetLang(String code) {
    setState(() {
      _targetLang = code;
      AppConfig.targetLanguage = code;
    });
    if (code.isEmpty) return; // '사용 안 함' → 표시만 숨김(재번역 안 함)
    for (final m in _messages) {
      if (!m.mine && m.translatedLang != code) _translateMessage(m);
    }
  }

  // 받은 메시지 한 건을 현재 대상 언어로 자동 번역.
  Future<void> _translateMessage(ChatMessage m) async {
    final target = _targetLang;
    if (target.isEmpty) return;
    if (m.translated != null && m.translatedLang == target) return; // 이미 됨
    setState(() {
      m.translating = true;
      m.translateError = null;
    });
    try {
      final r = await TranslationService.translate(m.text, target);
      if (!mounted) return;
      setState(() {
        m.translating = false;
        // 번역 도중 대상 언어가 또 바뀌었으면 최신 선택만 반영.
        if (_targetLang == target) {
          m.translated = r.translatedText;
          m.translatedLang = target;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        m.translating = false;
        m.translateError = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  // ---- 음성 자막 ----

  Future<void> _initSpeech() async {
    try {
      _speechAvailable = await _speech.initialize(
        onEnd: _onListenEnd,
        onError: (_) => _onListenEnd(),
      );
    } catch (_) {
      _speechAvailable = false;
    }
    if (mounted) setState(() {});
  }

  // 인식 종료 시: 연속 모드면 자막 켜진 동안 계속 재시작, 눌러 말하기면 1회로 끝.
  void _onListenEnd() {
    if (_captionMode == CaptionMode.continuous) {
      if (_captionsOn) _restartListening();
    } else if (mounted) {
      setState(() => _pttActive = false);
    }
  }

  Future<bool> _ensureSpeech() async {
    if (_speechAvailable) return true;
    await _initSpeech();
    if (!_speechAvailable) {
      _snack('이 기기/브라우저에서 음성 인식을 사용할 수 없습니다.');
      return false;
    }
    return true;
  }

  // 자막 보기 on/off. 연속 모드면 내 발화도 계속 송출 시작/중지.
  Future<void> _toggleCaptions() async {
    if (!_captionsOn) {
      if (!await _ensureSpeech()) return;
      setState(() => _captionsOn = true);
      if (_captionMode == CaptionMode.continuous) _startContinuous();
    } else {
      setState(() {
        _captionsOn = false;
        _pttActive = false;
      });
      await _speech.stop();
    }
  }

  void _startContinuous() {
    if (!_speechAvailable || _speech.isListening) return;
    _speech.listen(
      localeId: _sttLocales[_myLang] ?? 'en_US',
      onResult: _onSpeechResult,
    );
  }

  void _restartListening() {
    // 다음 틱에 재시작(콜백 중 재진입 방지) + 상태 재확인.
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted &&
          _captionsOn &&
          _captionMode == CaptionMode.continuous &&
          !_speech.isListening) {
        _startContinuous();
      }
    });
  }

  // 눌러 말하기: 탭하면 한 문장 캡처 시작(확정되면 자동 종료). 다시 탭하면 중지.
  Future<void> _pushToTalk() async {
    if (_pttActive) {
      await _speech.stop();
      if (mounted) setState(() => _pttActive = false);
      return;
    }
    if (!await _ensureSpeech()) return;
    setState(() => _pttActive = true);
    _speech.listen(
      localeId: _sttLocales[_myLang] ?? 'en_US',
      onResult: _onSpeechResult,
    );
  }

  void _onSpeechResult(String words, bool isFinal) {
    final text = words.trim();
    if (text.isEmpty) return;
    // 중간 결과는 ~400ms 간격으로만 송출(대역폭/비용 절약). 확정 결과는 항상 송출.
    final now = DateTime.now();
    if (!isFinal) {
      if (_lastInterimSentAt != null &&
          now.difference(_lastInterimSentAt!).inMilliseconds < 400) {
        return;
      }
      _lastInterimSentAt = now;
    }
    _broadcastCaption(text, isFinal);
    // 눌러 말하기: 한 문장 확정되면 캡처 종료.
    if (isFinal && _captionMode == CaptionMode.pushToTalk) {
      _speech.stop();
      if (mounted) setState(() => _pttActive = false);
    }
  }

  Future<void> _broadcastCaption(String text, bool isFinal) async {
    final myId = _room.localParticipant?.identity ?? AppConfig.deviceIdentity;
    // 내 자막도 화면에 표시(원문만).
    _ingestCaption(
      identity: myId,
      sender: _displayName,
      text: text,
      lang: _myLang,
      isFinal: isFinal,
      mine: true,
    );
    try {
      await _room.localParticipant?.publishData(
        utf8.encode(jsonEncode({
          'sender': _displayName,
          'text': text,
          'lang': _myLang,
          'final': isFinal,
        })),
        reliable: isFinal, // 확정 결과만 신뢰성 전송, 중간 결과는 유실 허용
        topic: _captionTopic,
      );
    } catch (_) {}
  }

  void _onCaptionReceived(DataReceivedEvent e) {
    // 자막을 끈 사람은 받은 자막을 처리/번역하지 않는다(불필요한 번역 과금 방지).
    if (!_captionsOn) return;
    try {
      final m = jsonDecode(utf8.decode(e.data)) as Map<String, dynamic>;
      final id = e.participant?.identity ?? (m['sender'] ?? '').toString();
      final text = (m['text'] ?? '').toString();
      if (text.isEmpty) return;
      _ingestCaption(
        identity: id,
        sender: (m['sender'] ?? e.participant?.identity ?? '상대').toString(),
        text: text,
        lang: (m['lang'] ?? '').toString(),
        isFinal: m['final'] == true,
        mine: false,
      );
    } catch (_) {}
  }

  // 자막 한 조각 반영: 중간결과=발화자별 '말하는 중' 라인, 확정결과=로그에 한 줄 추가.
  void _ingestCaption({
    required String identity,
    required String sender,
    required String text,
    required String lang,
    required bool isFinal,
    required bool mine,
  }) {
    if (!mounted) return;
    if (!isFinal) {
      final live = _liveCaptions[identity];
      if (live == null) {
        _liveCaptions[identity] = LiveCaption(
          identity: identity,
          sender: sender,
          text: text,
          lang: lang,
          isFinal: false,
          updatedAt: DateTime.now(),
          mine: mine,
        );
      } else {
        live.text = text;
        live.updatedAt = DateTime.now();
      }
      setState(() {});
      return;
    }
    // 확정: '말하는 중' 라인 제거하고 로그에 한 줄 추가.
    _liveCaptions.remove(identity);
    final line = LiveCaption(
      identity: identity,
      sender: sender,
      text: text,
      lang: lang,
      isFinal: true,
      updatedAt: DateTime.now(),
      mine: mine,
    );
    _captionLog.add(line);
    if (_captionLog.length > 50) {
      _captionLog.removeRange(0, _captionLog.length - 50);
    }
    setState(() {});
    // 남의 확정 자막을 내 언어로 자동 번역(발화 언어와 다를 때만).
    if (!mine && lang != _myLang) _translateCaption(line);
  }

  Future<void> _translateCaption(LiveCaption c) async {
    final target = _myLang;
    final src = c.text;
    if (c.translated != null && c.translatedLang == target) return;
    try {
      final r = await TranslationService.translate(src, target);
      if (!mounted) return;
      // 번역 도중 문장이 바뀌지 않았을 때만 반영.
      if (c.text == src) {
        setState(() {
          c.translated = r.translatedText;
          c.translatedLang = target;
        });
      }
    } catch (_) {
      // 자막 번역 실패는 조용히 무시(원문은 계속 표시).
    }
  }

  // 화면에 표시할 자막: 확정 로그 최근 줄 + '말하는 중' 라인, 합쳐서 최대 _maxCaptionLines.
  List<LiveCaption> _displayCaptions() {
    final live = _liveCaptions.values.toList()
      ..sort((a, b) => a.updatedAt.compareTo(b.updatedAt));
    final room = (_maxCaptionLines - live.length).clamp(0, _maxCaptionLines);
    final logPart = _captionLog.length > room
        ? _captionLog.sublist(_captionLog.length - room)
        : _captionLog;
    return [...logPart, ...live];
  }

  // 발언 방식 전환(연속 ↔ 눌러 말하기).
  void _setCaptionMode(CaptionMode mode) {
    if (_captionMode == mode) return;
    setState(() {
      _captionMode = mode;
      _pttActive = false;
    });
    if (mode == CaptionMode.pushToTalk) {
      _speech.stop(); // 연속 듣기 중지(이후엔 '말하기' 버튼으로)
    } else if (_captionsOn) {
      _startContinuous(); // 연속으로 전환 + 자막 켜져 있으면 바로 듣기
    }
  }

  // 자막 언어(내 언어) 선택 다이얼로그 — 더보기 메뉴에서 호출.
  Future<void> _showCaptionLangDialog() async {
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('자막 언어 (내 언어)'),
        children: [
          for (final e in AppConfig.supportedLanguages.entries)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, e.key),
              child: Row(
                children: [
                  Icon(
                    e.key == _myLang
                        ? Icons.check_circle
                        : Icons.circle_outlined,
                    size: 18,
                    color: e.key == _myLang ? const Color(0xFF4ADE80) : null,
                  ),
                  const SizedBox(width: 10),
                  Text(e.value),
                ],
              ),
            ),
        ],
      ),
    );
    if (picked != null) _changeMyLang(picked);
  }

  // 내 언어 변경(자막 언어 = STT 인식 언어 + 번역 대상).
  void _changeMyLang(String code) {
    if (!AppConfig.supportedLanguages.containsKey(code)) return;
    setState(() => _myLang = code);
    // 듣는 중이면 새 언어로 재시작(연속이면 onEnd에서 자동 재시작).
    if (_speech.isListening) _speech.stop();
    // 표시 중인 남의 확정 자막을 새 언어로 다시 번역.
    for (final c in _captionLog) {
      if (!c.mine && c.isFinal) _translateCaption(c);
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

    // 링크로 바로 입장한 경우: 입장 직후 이름 설정 팝업.
    if (widget.promptNameOnEnter) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showNameDialog(initial: true);
      });
    }

    // 카메라/마이크는 실패하거나 오래 걸려도 회의 진입을 막지 않는다.
    // (카메라 없는/고장난 기기 = TV·미디어박스에서 흔함. 그 경우 아바타로 참여)
    _enableLocalDevices();
  }

  // 표시 이름 설정/변경 팝업. 확인 시 LiveKit 참가자 이름도 갱신(다른 참가자에게 반영).
  Future<void> _showNameDialog({bool initial = false}) async {
    final ctrl = TextEditingController(text: initial ? '' : _displayName);
    final result = await showDialog<String>(
      context: context,
      barrierDismissible: !initial, // 최초 입장 팝업은 바깥 탭으로 안 닫히게
      builder: (ctx) => AlertDialog(
        title: Text(initial ? '이름 설정' : '이름 변경'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textInputAction: TextInputAction.done,
          maxLength: 20,
          onSubmitted: (v) => Navigator.pop(ctx, v),
          decoration: InputDecoration(
            labelText: '표시 이름',
            hintText: initial ? '회의에서 보일 이름 (예: 홍길동)' : null,
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(initial ? '건너뛰기' : '취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('확인'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    final name = (result ?? '').trim();
    if (name.isEmpty || name == _displayName) return;
    setState(() => _displayName = name);
    try {
      await _room.localParticipant?.setName(name);
    } catch (_) {}
  }

  Future<void> _enableLocalDevices() async {
    final lp = _room.localParticipant;
    if (lp == null) return;
    try {
      await lp.setCameraEnabled(true).timeout(const Duration(seconds: 8));
    } catch (_) {
      // 기본(내장) 카메라 실패 → 외장/사용 가능한 카메라로 재시도.
      // 내장 카메라 없는 TV에 USB 웹캠을 꽂은 경우 여기서 자동으로 잡힌다.
      final ok = await _tryEnableAnyCamera();
      if (!ok && mounted) setState(() => _camOn = false);
    }
    try {
      await lp.setMicrophoneEnabled(true).timeout(const Duration(seconds: 8));
    } catch (_) {
      if (mounted) setState(() => _micOn = false);
    }
    // 라벨이 채워진(권한 허용 후) 카메라 목록 로드
    await _loadCameras();
    // 처음 켜진(기본) 카메라의 deviceId를 파악해 선택 메뉴 체크 표시에 반영
    _syncCurrentCameraId();
  }

  // 현재 활성 카메라의 deviceId를 트랙 설정에서 읽어 _currentCameraId에 반영.
  // (기본 카메라는 facingMode로 켜져 deviceId를 우리가 지정하지 않으므로 여기서 회수)
  void _syncCurrentCameraId() {
    if (_currentCameraId != null) return;
    final lp = _room.localParticipant;
    if (lp == null) return;
    for (final pub in lp.videoTrackPublications) {
      if (pub.source != TrackSource.camera) continue;
      final t = pub.track;
      if (t is LocalVideoTrack) {
        try {
          final dev = t.mediaStreamTrack.getSettings()['deviceId'];
          if (dev != null && dev.toString().isNotEmpty) {
            if (mounted) setState(() => _currentCameraId = dev.toString());
          }
        } catch (_) {}
      }
      break;
    }
  }

  // 사용 가능한 카메라 목록을 불러온다(라벨은 권한 허용 후 채워짐).
  Future<void> _loadCameras() async {
    try {
      final cams = await Hardware.instance.videoInputs();
      if (!mounted) return;
      setState(() => _cameras = cams);
    } catch (_) {}
  }

  // 내장 카메라 기본 켜기가 실패했을 때, 열거된 카메라 중 하나(외장 우선)로 켠다.
  Future<bool> _tryEnableAnyCamera() async {
    final lp = _room.localParticipant;
    if (lp == null) return false;
    try {
      final cams = await Hardware.instance.videoInputs();
      if (cams.isEmpty) return false;
      final pick = _preferExternal(cams);
      await lp
          .setCameraEnabled(
            true,
            cameraCaptureOptions: CameraCaptureOptions(deviceId: pick.deviceId),
          )
          .timeout(const Duration(seconds: 8));
      if (mounted) {
        setState(() {
          _camOn = true;
          _currentCameraId = pick.deviceId;
        });
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  // 외장(USB) 카메라를 우선 고른다. 라벨에 external/usb 가 있으면 그것,
  // 없으면 첫 번째. (Camera2가 외장 카메라를 라벨로 구분해 준다)
  MediaDevice _preferExternal(List<MediaDevice> cams) {
    for (final c in cams) {
      final l = c.label.toLowerCase();
      if (l.contains('external') || l.contains('usb')) return c;
    }
    return cams.first;
  }

  // 선택한 카메라로 전환. 켜져 있으면 트랙 교체, 꺼져 있으면 그 기기로 켠다.
  Future<void> _switchCamera(MediaDevice d) async {
    final lp = _room.localParticipant;
    if (lp == null) return;
    LocalVideoTrack? camTrack;
    for (final pub in lp.videoTrackPublications) {
      if (pub.source == TrackSource.camera) {
        final t = pub.track;
        if (t is LocalVideoTrack) camTrack = t;
        break;
      }
    }
    try {
      if (camTrack != null) {
        await camTrack.switchCamera(d.deviceId);
      } else {
        await lp.setCameraEnabled(
          true,
          cameraCaptureOptions: CameraCaptureOptions(deviceId: d.deviceId),
        );
      }
      if (mounted) {
        setState(() {
          _camOn = true;
          _currentCameraId = d.deviceId;
        });
      }
    } catch (e) {
      _snack('카메라 전환 실패: $e');
    }
  }

  // 메뉴에 표시할 카메라 이름.
  // 주의: flutter_webrtc가 주는 라벨의 전/후면(facing) 값은 카메라가 여러 개인 폰
  // (갤럭시 등)에서 실제와 어긋나는 경우가 있다. 그래서 전면/후면으로 단정하지 않고
  // USB 외장만 키워드로 표시하고 나머지는 번호로 둔다(틀린 라벨 방지).
  String _cameraLabel(MediaDevice d, int index) {
    final lower = d.label.toLowerCase();
    if (lower.contains('external') || lower.contains('usb')) return 'USB 카메라';
    return '카메라 ${index + 1}';
  }

  // ---- 참가자 타일 목록 구성 (로컬을 맨 앞에) ----
  List<_Tile> _buildTiles() {
    final tiles = <_Tile>[];

    // 카메라 영상(화면공유 제외)만 고른다.
    VideoTrack? cameraVideo(Iterable<TrackPublication> pubs) {
      if (!_receiveVideo) return null; // 저사양 모드: 영상 대신 아바타
      for (final pub in pubs) {
        if (pub.source == TrackSource.screenShareVideo) continue; // 화면은 별도 타일
        // 카메라가 꺼지면(음소거) 마지막 프레임이 멈추거나 검게 남는다.
        // 이 경우 영상 대신 아바타를 보이도록 여기서 제외한다.
        if (pub.muted) continue;
        final t = pub.track;
        if (t is VideoTrack) return t;
      }
      return null;
    }

    // 활성화된 화면공유 트랙(있으면).
    VideoTrack? screenVideo(Iterable<TrackPublication> pubs) {
      if (!_receiveVideo) return null; // 저사양 모드: 화면도 아바타로 대체
      for (final pub in pubs) {
        if (pub.source != TrackSource.screenShareVideo) continue;
        if (pub.muted) continue;
        final t = pub.track;
        if (t is VideoTrack) return t;
      }
      return null;
    }

    // 마이크 트랙이 켜져(음소거 아님) 있으면 마이크 ON.
    // 화면공유 오디오(screenShareAudio)는 마이크가 아니므로 제외한다.
    bool micOn(Participant p) {
      for (final pub in p.audioTrackPublications) {
        if (pub.source == TrackSource.screenShareAudio) continue;
        if (!pub.muted) return true;
      }
      return false;
    }

    void addFor(Participant p) {
      // 카메라(또는 아바타) 타일
      tiles.add(
        _Tile(
          p,
          cameraVideo(p.videoTrackPublications),
          micOn: micOn(p),
          speaking: p.isSpeaking,
        ),
      );
      // 화면공유 타일(있을 때만) — 별도 타일로 크게 보여준다.
      final screen = screenVideo(p.videoTrackPublications);
      if (screen != null) {
        tiles.add(_Tile(p, screen, isScreenShare: true));
      }
    }

    final lp = _room.localParticipant;
    if (lp != null) addFor(lp);
    for (final p in _room.remoteParticipants.values) {
      addFor(p);
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

  // 실제 송출 상태를 화면 상태에 반영(publish/unpublish 이벤트, 시스템 중지 등).
  void _syncScreenShareState() {
    final on = _room.localParticipant?.isScreenShareEnabled() ?? false;
    if (mounted && on != _screenSharing) {
      setState(() => _screenSharing = on);
    } else {
      _screenSharing = on;
    }
    // 화면공유가 꺼졌으면 안드로이드 포그라운드 서비스도 정리.
    if (!on && _bgServiceOn) {
      _stopBackgroundService();
    }
  }

  /// 화면공유 시작/중지 토글.
  ///  - 웹/데스크탑: getDisplayMedia 로 창/화면 선택(추가 설정 불필요)
  ///  - 안드로이드: 캡처 권한 + mediaProjection 포그라운드 서비스 필요
  Future<void> _toggleScreenShare() async {
    final lp = _room.localParticipant;
    if (lp == null || _shareBusy) return;

    // 이미 공유 중이면 중지
    if (_screenSharing) {
      setState(() => _shareBusy = true);
      try {
        await lp.setScreenShareEnabled(false);
      } catch (_) {
      } finally {
        await _stopBackgroundService();
        if (mounted) setState(() => _shareBusy = false);
        _syncScreenShareState();
      }
      return;
    }

    // 모바일 웹은 getDisplayMedia 미지원 → 안내
    if (kIsWeb && lkPlatformIsWebMobile()) {
      _snack('모바일 브라우저에서는 화면공유를 지원하지 않습니다. PC 브라우저나 앱을 사용하세요.');
      return;
    }

    setState(() => _shareBusy = true);
    try {
      // 안드로이드: 알림 권한 선확정 → 캡처 권한 → 포그라운드 서비스 준비.
      // 알림 권한을 캡처 권한보다 먼저 받아, 첫 실행 시 여러 권한 다이얼로그가
      // 캡처 시작 흐름과 겹쳐 첫 시도가 실패하던 것을 방지한다.
      if (!kIsWeb && lkPlatformIs(PlatformType.android)) {
        await _ensureNotificationPermission();
        final granted = await Helper.requestCapturePermission();
        if (!granted) {
          _snack('화면 캡처 권한이 거부되었습니다.');
          return;
        }
        final ok = await _ensureBackgroundService();
        if (!ok) {
          _snack('화면공유용 백그라운드 실행을 시작할 수 없습니다.');
          return;
        }
      }

      // iOS는 다른 앱/전체 화면을 캡처하려면 ReplayKit Broadcast Extension을 통해야 한다
      // (BroadcastExtension 타깃 + App Group 설정 필요). 이 옵션이 켜져야 시스템
      // 방송 피커가 뜨고 확장을 거쳐 화면이 송출된다. 안드로이드/웹은 기존 경로 유지.
      final iosBroadcast = !kIsWeb && lkPlatformIs(PlatformType.iOS);
      // 화면 소리도 함께 전송. 웹은 브라우저의 "탭 오디오 공유"로 안정적으로 동작.
      // 안드로이드 내부오디오 캡처는 기기별로 실패해 공유 자체가 막힐 수 있어 실기기
      // 검증 전까지는 웹에서만 켠다.
      await lp.setScreenShareEnabled(
        true,
        captureScreenAudio: kIsWeb,
        screenShareCaptureOptions: iosBroadcast
            ? ScreenShareCaptureOptions(useiOSBroadcastExtension: true)
            : null,
      );
      _syncScreenShareState();
    } catch (e) {
      await _stopBackgroundService();
      _snack('화면공유를 시작할 수 없습니다: $e');
    } finally {
      if (mounted) setState(() => _shareBusy = false);
    }
  }

  // Android 13+: 포그라운드 서비스 알림용 알림 권한(best-effort).
  Future<void> _ensureNotificationPermission() async {
    if (kIsWeb || !lkPlatformIs(PlatformType.android)) return;
    try {
      await Permission.notification.request();
    } catch (_) {}
  }

  // 안드로이드 mediaProjection 유지용 포그라운드 서비스 시작(멱등).
  // 첫 실행 시 권한이 막 확정된 직후 초기화가 실패할 수 있어 1회 자동 재시도한다
  // (LiveKit 예제와 동일한 패턴). 재시도 때는 initialize 대신 hasPermissions 로 확인.
  Future<bool> _ensureBackgroundService([bool isRetry = false]) async {
    if (kIsWeb || !lkPlatformIs(PlatformType.android)) return true;
    try {
      const androidConfig = FlutterBackgroundAndroidConfig(
        notificationTitle: '화면 공유 중',
        notificationText: 'Prism Meeting 이 화면을 공유하고 있습니다.',
        notificationImportance: AndroidNotificationImportance.normal,
        notificationIcon: AndroidResource(
          name: 'ic_launcher',
          defType: 'mipmap',
        ),
      );
      var has = await FlutterBackground.hasPermissions;
      if (!isRetry) {
        has = await FlutterBackground.initialize(androidConfig: androidConfig);
      }
      if (!has) return false;
      if (!FlutterBackground.isBackgroundExecutionEnabled) {
        await FlutterBackground.enableBackgroundExecution();
      }
      _bgServiceOn = true;
      return true;
    } catch (_) {
      if (!isRetry) {
        // 1초 뒤 1회 재시도 (첫 실행 권한 확정 직후 레이스 완화)
        await Future<void>.delayed(const Duration(seconds: 1));
        return _ensureBackgroundService(true);
      }
      return false;
    }
  }

  Future<void> _stopBackgroundService() async {
    if (!_bgServiceOn) return;
    _bgServiceOn = false;
    try {
      if (FlutterBackground.isBackgroundExecutionEnabled) {
        await FlutterBackground.disableBackgroundExecution();
      }
    } catch (_) {}
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
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
              child: const Text('확인'),
            ),
          ],
        ),
      ).whenComplete(_popSelf);
    } else {
      _popSelf();
    }
  }

  // 회의 화면(라우트)만 실제로 닫는다.
  // PopScope(canPop:false) 로 뒤로가기를 가로채므로, 여기서는 maybePop 이 아니라
  // 무조건 pop 을 써야 한다(maybePop 은 다시 PopScope 에 걸려 무한 반복됨).
  void _popSelf() {
    if (!mounted) return;
    final nav = Navigator.of(context);
    if (nav.canPop()) nav.pop();
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
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('종료'),
            ),
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

  // QR 초대: TV 등에서 QR을 띄우면 휴대폰으로 스캔해 바로 입장
  void _showInviteQr() {
    final link = AppConfig.inviteLink(widget.roomName, pin: widget.pin);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        // 화면(다이얼로그)이 작은 셋톱에서 내용이 넘쳐 오버플로우 줄무늬가 뜨는 것 방지.
        scrollable: true,
        title: const Text('QR로 초대'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SizedBox(
                width: 220,
                height: 220,
                child: PrettyQrView.data(
                  data: link,
                  decoration: const PrettyQrDecoration(
                    shape: PrettyQrSmoothSymbol(color: Color(0xFF000000)),
                  ),
                  // QR 생성 실패 시에도 다이얼로그가 쓸모있도록 안내 대체
                  errorBuilder: (_, _, _) => const Center(
                    child: Text(
                      'QR 생성 실패\n아래 링크를 복사해 사용하세요',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.black54, fontSize: 13),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              '방 코드: ${widget.roomName}',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            if (widget.pin != null && widget.pin!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '입장 코드: ${widget.pin}',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            const SizedBox(height: 8),
            const Text(
              '휴대폰으로 QR을 스캔하면 이 방으로 입장합니다.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.white70),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: link));
              Navigator.pop(ctx);
              if (mounted) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('초대 링크 복사됨')));
              }
            },
            child: const Text('링크 복사'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('닫기'),
          ),
        ],
      ),
    );
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

  /// 발표자 뷰: 메인을 크게 + 하단 썸네일.
  /// 메인 우선순위: 사용자가 고정한 타일 > 화면공유 > 최근 발언자 > 첫 번째.
  /// 누군가 화면을 공유하면 자동으로 그 화면이 메인에 크게 잡힌다.
  Widget _buildSpeakerView(List<_Tile> tiles) {
    if (tiles.isEmpty) {
      return const Center(child: Text('참가자를 기다리는 중...'));
    }
    _Tile? byId(String? id) {
      if (id == null) return null;
      for (final t in tiles) {
        if (t.id == id) return t;
      }
      return null;
    }

    _Tile? firstShare;
    for (final t in tiles) {
      if (t.isScreenShare) {
        firstShare = t;
        break;
      }
    }

    final main =
        byId(_pinnedTileId) ??
        firstShare ??
        byId(_spotlightIdentity) ??
        tiles.first;
    final others = tiles.where((t) => t.id != main.id).toList();

    return Column(
      children: [
        Expanded(
          child: InkWell(
            // 리모컨/탭으로 고정 해제 (포커스 가능)
            onTap: () {
              if (_pinnedTileId != null) {
                setState(() => _pinnedTileId = null);
              }
            },
            borderRadius: BorderRadius.circular(12),
            child: Stack(
              children: [
                Positioned.fill(child: _ParticipantTile(tile: main)),
                if (_pinnedTileId != null)
                  Positioned(
                    right: 8,
                    top: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.push_pin, size: 14, color: Colors.white),
                          SizedBox(width: 4),
                          Text(
                            '고정됨 · 탭하여 해제',
                            style: TextStyle(fontSize: 12, color: Colors.white),
                          ),
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
                    // 리모컨/탭으로 이 타일 크게 고정 (포커스 가능)
                    onTap: () => setState(() => _pinnedTileId = t.id),
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
                const Icon(
                  Icons.error_outline,
                  size: 48,
                  color: Color(0xFFFF8A80),
                ),
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
    // 누군가 화면을 공유하면 자동으로 발표(프레젠테이션) 레이아웃으로 크게 보여준다.
    final hasShare = allTiles.any((t) => t.isScreenShare);
    final useSpeaker = _speakerView || hasShare;
    // 화면공유 송출 버튼 노출 조건:
    //  - 웹(노트북/PC): 항상 (핵심 사용처)
    //  - 네이티브: TV처럼 넓은 화면은 제외(자기 화면 캡처는 무의미) → 폰만
    final canPresent = kIsWeb || !isTv;
    // 갤러리 페이지네이션: 한 페이지에 maxVisibleTiles(6)명씩 → 저사양 기기 렌더 부하 고정.
    final perPage = AppConfig.maxVisibleTiles;
    final pageCount = (allTiles.length / perPage).ceil().clamp(1, 9999);
    if (_page >= pageCount) _page = pageCount - 1; // 인원 줄면 페이지 보정
    if (_page < 0) _page = 0;
    final pageTiles = allTiles.skip(_page * perPage).take(perPage).toList();

    // 넓은 화면(PC·안드로이드TV 가로)에서는 채팅을 영상 옆 인라인 패널로 → 영상이
    // 왼쪽으로 줄고 가려지지 않는다. 좁은 화면(모바일)은 기존 드로어(오버레이) 유지.
    final wideChat = size.width >= 900;
    final inlineChatOpen = wideChat && _chatOpen;

    return PopScope(
      // 뒤로가기(앱바 화살표 · 안드로이드 시스템 백)를 가로채 나가기/회의종료와
      // 동일하게 처리한다. 방장은 확인 후 방 종료(전원 퇴장).
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || _leaving) return;
        // 채팅이 열려 있으면 먼저 채팅만 닫는다(인라인/드로어 각각 처리).
        if (_chatOpen) {
          if (wideChat) {
            setState(() => _chatOpen = false);
          } else {
            _scaffoldKey.currentState?.closeEndDrawer();
          }
          return;
        }
        _onLeavePressed();
      },
      child: Scaffold(
        key: _scaffoldKey,
        onEndDrawerChanged: (open) {
          setState(() {
            _chatOpen = open;
            if (open) _unread = 0;
          });
        },
        // 좁은 화면(모바일)만 드로어. 넓은 화면은 body 안에 인라인 패널로 표시.
        endDrawer: wideChat
            ? null
            : Drawer(
                width: isTv ? 420 : 320,
                child: ChatPanel(
                  messages: _messages,
                  onSend: _sendChat,
                  targetLanguage: _targetLang,
                  onLanguageChange: _changeTargetLang,
                ),
              ),
        appBar: AppBar(
          // 뒤로가기 ↔ 방이름 간격 최소화 + 방이름 글자 작게 → 긴 방이름도 더 보이게
          titleSpacing: 0,
          leadingWidth: 40, // 뒤로가기 영역 축소 → 방이름을 왼쪽으로 더 당김
          title: Text(
            '${widget.roomName} · ${allTiles.length}명',
            style: const TextStyle(fontSize: 15),
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            // ① 카메라 전환 — 카메라가 2개 이상(전/후면, USB 외장 등)일 때만 노출
            if (_cameras.length >= 2)
              PopupMenuButton<MediaDevice>(
                tooltip: '카메라 전환',
                padding: EdgeInsets.zero,
                icon: const Icon(Icons.cameraswitch),
                onSelected: _switchCamera,
                itemBuilder: (_) => [
                  for (int i = 0; i < _cameras.length; i++)
                    PopupMenuItem<MediaDevice>(
                      value: _cameras[i],
                      child: Row(
                        children: [
                          Icon(
                            _cameras[i].deviceId == _currentCameraId
                                ? Icons.check
                                : Icons.videocam_outlined,
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              _cameraLabel(_cameras[i], i),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            // ② 화면 모드 변환 (갤러리 ↔ 발표자)
            IconButton(
              tooltip: _speakerView ? '갤러리 뷰' : '발표자 뷰',
              visualDensity: VisualDensity.compact,
              onPressed: () => setState(() => _speakerView = !_speakerView),
              icon: Icon(_speakerView ? Icons.grid_view : Icons.view_sidebar),
            ),
            // ③ 초대 (QR + 링크 복사를 한 다이얼로그로 통합 → 아이콘 1개로 축소)
            IconButton(
              tooltip: '초대 (QR·링크)',
              visualDensity: VisualDensity.compact,
              onPressed: _showInviteQr,
              icon: const Icon(Icons.person_add_alt),
            ),
            // ④ 채팅
            IconButton(
              tooltip: '채팅',
              visualDensity: VisualDensity.compact,
              onPressed: () {
                if (wideChat) {
                  // 인라인 토글 (영상 옆으로 열림/닫힘)
                  setState(() {
                    _chatOpen = !_chatOpen;
                    if (_chatOpen) _unread = 0;
                  });
                } else {
                  _scaffoldKey.currentState?.openEndDrawer();
                }
              },
              icon: Badge.count(
                count: _unread,
                isLabelVisible: _unread > 0,
                child: const Icon(Icons.chat_bubble_outline),
              ),
            ),
            // ⑤ 더보기(⋮) — 자주 안 쓰는 항목은 여기로: 화면 숨기기(저사양)
            PopupMenuButton<String>(
              tooltip: '더보기',
              padding: EdgeInsets.zero,
              onSelected: (v) {
                if (v == 'recv') _toggleReceiveVideo();
                if (v == 'name') _showNameDialog();
                if (v == 'caption') _toggleCaptions();
                if (v == 'caplang') _showCaptionLangDialog();
                if (v == 'capmode') {
                  _setCaptionMode(
                    _captionMode == CaptionMode.continuous
                        ? CaptionMode.pushToTalk
                        : CaptionMode.continuous,
                  );
                }
              },
              itemBuilder: (_) => [
                // ── 자막 ──
                PopupMenuItem<String>(
                  value: 'caption',
                  child: Row(
                    children: [
                      Icon(
                        _captionsOn
                            ? Icons.closed_caption
                            : Icons.closed_caption_off,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Text(_captionsOn ? '자막 끄기' : '자막 켜기'),
                    ],
                  ),
                ),
                PopupMenuItem<String>(
                  value: 'caplang',
                  child: Row(
                    children: [
                      const Icon(Icons.subtitles_outlined, size: 18),
                      const SizedBox(width: 8),
                      Text(
                        '자막 언어: ${AppConfig.supportedLanguages[_myLang] ?? _myLang}',
                      ),
                    ],
                  ),
                ),
                PopupMenuItem<String>(
                  value: 'capmode',
                  child: Row(
                    children: [
                      Icon(
                        _captionMode == CaptionMode.continuous
                            ? Icons.mic_none
                            : Icons.autorenew,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _captionMode == CaptionMode.continuous
                            ? '자막: 눌러 말하기로'
                            : '자막: 연속으로',
                      ),
                    ],
                  ),
                ),
                const PopupMenuDivider(),
                const PopupMenuItem<String>(
                  value: 'name',
                  child: Row(
                    children: [
                      Icon(Icons.badge_outlined, size: 18),
                      SizedBox(width: 8),
                      Text('이름 변경'),
                    ],
                  ),
                ),
                PopupMenuItem<String>(
                  value: 'recv',
                  child: Row(
                    children: [
                      Icon(
                        _receiveVideo ? Icons.visibility_off : Icons.visibility,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Text(_receiveVideo ? '화면 숨기기(저사양)' : '화면 다시 보기'),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
        body: Row(
          children: [
            Expanded(
              child: Column(
                children: [
                  // 네트워크 재연결 중 배너 (자동 복구 시도 중임을 표시)
                  if (_reconnecting)
                    Container(
                      width: double.infinity,
                      color: const Color(0xFFB45309),
                      padding: const EdgeInsets.symmetric(
                        vertical: 8,
                        horizontal: 12,
                      ),
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          ),
                          SizedBox(width: 10),
                          Text(
                            '네트워크 재연결 중...',
                            style: TextStyle(color: Colors.white, fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: useSpeaker
                          ? _buildSpeakerView(allTiles) // 발표자 뷰: 화면공유/발언자를 메인에
                          : _VideoGrid(tiles: pageTiles, isTv: isTv),
                    ),
                  ),
                  // 갤러리 페이지 이동 (참가자가 한 페이지보다 많을 때)
                  if (!useSpeaker && pageCount > 1)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          IconButton(
                            tooltip: '이전',
                            onPressed: _page > 0
                                ? () => setState(() => _page--)
                                : null,
                            icon: const Icon(Icons.chevron_left),
                          ),
                          Text(
                            '${_page + 1} / $pageCount',
                            style: const TextStyle(fontSize: 14),
                          ),
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
                  // 실시간 자막 오버레이(줌 스타일, 자막 켬일 때만)
                  if (_captionsOn)
                    CaptionOverlay(
                      lines: _displayCaptions(),
                      myLang: _myLang,
                      maxLines: _maxCaptionLines,
                    ),
                  _ControlBar(
                    micOn: _micOn,
                    camOn: _camOn,
                    isHost: widget.isHost,
                    showShare: canPresent,
                    sharing: _screenSharing,
                    shareBusy: _shareBusy,
                    captionsOn: _captionsOn,
                    pushToTalkMode: _captionMode == CaptionMode.pushToTalk,
                    pttActive: _pttActive,
                    onMic: _toggleMic,
                    onCam: _toggleCam,
                    onShare: _toggleScreenShare,
                    onPushToTalk: _pushToTalk,
                    onLeave: _onLeavePressed,
                  ),
                ],
              ),
            ),
            // 넓은 화면: 채팅을 영상 오른쪽에 인라인으로 → 영상 영역이 왼쪽으로 줄어듦
            if (inlineChatOpen)
              Container(
                width: isTv ? 380 : 340,
                decoration: const BoxDecoration(
                  color: Color(0xFF141922),
                  border: Border(left: BorderSide(color: Colors.white12)),
                ),
                child: ChatPanel(
                  messages: _messages,
                  onSend: _sendChat,
                  targetLanguage: _targetLang,
                  onLanguageChange: _changeTargetLang,
                  onClose: () => setState(() => _chatOpen = false),
                ),
              ),
          ],
        ),
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
    final isScreen = tile.isScreenShare;
    // 표시 라벨: 화면공유 타일은 "이름 님의 화면"으로 구분.
    final label = isScreen
        ? '${isLocal ? '내' : name} 화면'
        : (isLocal ? '$name (나)' : name);

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        // 화면공유는 파란 테두리, 말하는 사람은 초록 테두리로 강조
        border: isScreen
            ? Border.all(color: const Color(0xFF5B8DEF), width: 3)
            : tile.speaking
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
                  // 화면공유는 전체가 보이도록 contain(레터박스). 카메라도 기본 contain.
                  fit: VideoViewFit.contain,
                  // 화면공유는 절대 좌우반전하면 안 됨(글자가 뒤집힘). 카메라도 off로 통일.
                  mirrorMode: VideoViewMirrorMode.off,
                )
              else
                Center(
                  child: CircleAvatar(
                    radius: 32,
                    backgroundColor: const Color(0xFF2E3742),
                    child: Text(
                      name.isNotEmpty
                          ? name.characters.first.toUpperCase()
                          : '?',
                      style: const TextStyle(fontSize: 28),
                    ),
                  ),
                ),
              Positioned(
                left: 8,
                bottom: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 화면공유 타일은 화면 아이콘, 그 외엔 마이크 on/off 아이콘
                      Icon(
                        isScreen
                            ? Icons.screen_share
                            : (tile.micOn ? Icons.mic : Icons.mic_off),
                        size: 14,
                        color: isScreen
                            ? const Color(0xFF5B8DEF)
                            : (tile.micOn
                                  ? Colors.white
                                  : const Color(0xFFFF6B6B)),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        label,
                        style: const TextStyle(
                          fontSize: 13,
                          color: Colors.white,
                        ),
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
  final bool showShare; // 화면공유 버튼 노출(웹/폰), TV는 표시 위주라 숨김
  final bool sharing; // 내가 화면공유 중
  final bool shareBusy; // 화면공유 토글 진행 중
  final bool captionsOn; // 자막 켬
  final bool pushToTalkMode; // 눌러 말하기 모드
  final bool pttActive; // 눌러 말하기 캡처 중
  final VoidCallback onMic;
  final VoidCallback onCam;
  final VoidCallback onShare;
  final VoidCallback onPushToTalk;
  final VoidCallback onLeave;

  const _ControlBar({
    required this.micOn,
    required this.camOn,
    required this.isHost,
    required this.showShare,
    required this.sharing,
    required this.shareBusy,
    required this.captionsOn,
    required this.pushToTalkMode,
    required this.pttActive,
    required this.onMic,
    required this.onCam,
    required this.onShare,
    required this.onPushToTalk,
    required this.onLeave,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        // 버튼이 많아 좁은 폰에서 한 줄을 넘칠 수 있어 Wrap 으로 자동 줄바꿈.
        child: Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 16,
          runSpacing: 10,
          children: [
            _RoundButton(
              icon: micOn ? Icons.mic : Icons.mic_off,
              label: micOn ? '음소거' : '해제',
              active: micOn,
              autofocus: true, // 회의 진입 시 리모컨 시작 포커스
              onTap: onMic,
            ),
            _RoundButton(
              icon: camOn ? Icons.videocam : Icons.videocam_off,
              label: camOn ? '카메라 끄기' : '카메라 켜기',
              active: camOn,
              onTap: onCam,
            ),
            if (showShare)
              _RoundButton(
                icon: sharing ? Icons.stop_screen_share : Icons.screen_share,
                label: sharing ? '공유 중지' : '화면 공유',
                active: true, // 유휴 시에도 기본(어두운) 색 유지
                accent: sharing, // 공유 중이면 파란색 강조
                busy: shareBusy,
                onTap: shareBusy ? null : onShare,
              ),
            // 눌러 말하기 모드 + 자막 켬일 때만: '말하기' 버튼
            // (자막 켜기/끄기·언어 선택은 앱바 더보기(⋮) 메뉴로 이동)
            if (captionsOn && pushToTalkMode)
              _RoundButton(
                icon: pttActive ? Icons.mic : Icons.mic_none,
                label: pttActive ? '말하는 중' : '말하기',
                active: true,
                accent: pttActive, // 캡처 중이면 파란색 강조
                onTap: onPushToTalk,
              ),
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
  final bool accent; // 활성 강조(파란색) — 화면공유 중 표시용
  final bool autofocus;
  final bool busy; // 진행 중이면 스피너 표시 + 비활성
  final VoidCallback? onTap; // null 이면 비활성(회색 처리는 안 함, 탭만 막음)

  const _RoundButton({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
    this.danger = false,
    this.accent = false,
    this.autofocus = false,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    final bg = danger
        ? const Color(0xFFE5484D)
        : accent
        ? const Color(0xFF2E5AC0)
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
              child: busy
                  ? const SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: Colors.white,
                      ),
                    )
                  : Icon(icon, size: 28, color: Colors.white),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(label, style: const TextStyle(fontSize: 12)),
      ],
    );
  }
}
