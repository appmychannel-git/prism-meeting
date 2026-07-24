import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import 'config.dart';
import 'connection_service.dart';
import 'room_screen.dart';

class JoinScreen extends StatefulWidget {
  const JoinScreen({super.key});

  @override
  State<JoinScreen> createState() => _JoinScreenState();
}

enum _Tab { join, create }

class _JoinScreenState extends State<JoinScreen> {
  final _nameCtrl = TextEditingController();
  final _codeCtrl = TextEditingController(); // 참여: 방 코드
  final _customCtrl = TextEditingController(); // 만들기: 지정 이름(선택)
  final _pinCtrl = TextEditingController(); // 비공개 방 입장 코드

  late final FocusNode _codeFocus = _fieldNode();
  late final FocusNode _customFocus = _fieldNode();
  late final FocusNode _pinFocus = _fieldNode();
  late final FocusNode _nameFocus = _fieldNode();

  _Tab _tab = _Tab.create;
  bool _private = false; // 방 만들기: 비공개 방 여부
  bool _connecting = false;
  String? _error;

  final _appLinks = AppLinks();
  StreamSubscription<Uri>? _linkSub;

  @override
  void initState() {
    super.initState();
    if (kIsWeb) {
      // 웹: 현재 URL(...?room=코드&pin=코드)에서 바로 읽음
      _applyLinkUri(Uri.base);
    } else {
      // 네이티브(App Links): 초대 링크로 앱이 열리면 그 방으로
      _initDeepLinks();
    }
  }

  Future<void> _initDeepLinks() async {
    try {
      final initial = await _appLinks.getInitialLink();
      if (initial != null) _applyLinkUri(initial, rebuild: true);
    } catch (_) {}
    _linkSub = _appLinks.uriLinkStream.listen(
      (uri) => _applyLinkUri(uri, rebuild: true),
    );
  }

  // 초대 링크의 room/pin 을 참여 탭에 채운다.
  void _applyLinkUri(Uri uri, {bool rebuild = false}) {
    final room = uri.queryParameters['room'];
    final pin = uri.queryParameters['pin'];
    if (room == null || room.trim().isEmpty) return;
    void assign() {
      _tab = _Tab.join;
      _codeCtrl.text = room.trim();
      if (pin != null) _pinCtrl.text = pin.trim();
    }

    if (rebuild && mounted) {
      setState(assign);
    } else {
      assign();
    }
  }

  FocusNode _fieldNode() {
    final node = FocusNode();
    node.onKeyEvent = (n, event) {
      if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
        return KeyEventResult.ignored;
      }
      final k = event.logicalKey;
      if (k == LogicalKeyboardKey.arrowDown) {
        n.focusInDirection(TraversalDirection.down);
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.arrowUp) {
        n.focusInDirection(TraversalDirection.up);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    };
    return node;
  }

  @override
  void dispose() {
    _linkSub?.cancel();
    _nameCtrl.dispose();
    _codeCtrl.dispose();
    _customCtrl.dispose();
    _pinCtrl.dispose();
    _codeFocus.dispose();
    _customFocus.dispose();
    _pinFocus.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  bool get _anyFieldFocused =>
      _codeFocus.hasFocus ||
      _customFocus.hasFocus ||
      _pinFocus.hasFocus ||
      _nameFocus.hasFocus;

  Future<bool> _ensurePermissions() async {
    if (kIsWeb) return true; // 웹은 브라우저가 직접 물어봄
    final statuses = await [Permission.camera, Permission.microphone].request();
    return statuses.values.every((s) => s.isGranted || s.isLimited);
  }

  Future<void> _join() async {
    setState(() {
      _error = null;
      _connecting = true;
    });
    try {
      // 방 코드 + 입장코드(pin) 결정
      final String room;
      final String pin;
      if (_tab == _Tab.join) {
        room = _codeCtrl.text.trim();
        if (room.isEmpty) throw Exception('방 코드를 입력하세요.');
        pin = _pinCtrl.text.trim(); // 공개방이면 서버가 무시
      } else {
        final custom = _customCtrl.text.trim();
        room = custom.isEmpty ? AppConfig.generateRoomCode() : custom;
        if (_private) {
          pin = _pinCtrl.text.trim();
          if (pin.isEmpty) throw Exception('비공개 방은 입장 코드를 입력하세요.');
        } else {
          pin = '';
        }
      }

      final name = _nameCtrl.text.trim().isEmpty
          ? '게스트-${DateTime.now().millisecondsSinceEpoch % 1000}'
          : _nameCtrl.text.trim();

      if (AppConfig.tokenServerUrl.isEmpty) {
        throw Exception('토큰 서버 주소가 설정되지 않았습니다. (LK_TOKEN_URL)');
      }

      final granted = await _ensurePermissions();
      if (!granted) {
        throw Exception('카메라/마이크 권한이 필요합니다. 설정에서 허용해주세요.');
      }

      final details = await ConnectionService.fetchFromServer(
        tokenServerUrl: AppConfig.tokenServerUrl,
        roomName: room,
        participantName: name,
        identity: AppConfig.deviceIdentity,
        pin: pin,
        create: _tab == _Tab.create, // 방 만들기만 새 방 생성 허용
      );

      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => RoomScreen(
            details: details,
            roomName: room,
            displayName: name,
            pin: pin,
            isHost: _tab == _Tab.create, // 방 만든 사람이 방장
          ),
        ),
      );
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isJoin = _tab == _Tab.join;
    final size = MediaQuery.of(context).size;
    final landscape = size.width > size.height; // 가로모드(TV 등)
    final gap = landscape ? 10.0 : 16.0; // 항목 간 세로 간격
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_anyFieldFocused) {
          FocusScope.of(context).unfocus();
        } else {
          SystemNavigator.pop();
        }
      },
      child: Scaffold(
        body: Stack(
          children: [
            Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 460),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Icon(
                        Icons.video_camera_front_rounded,
                        size: landscape ? 40 : 60,
                        color: const Color(0xFF5B8DEF),
                      ),
                      SizedBox(height: landscape ? 6 : 10),
                      Text(
                        'Prism Meeting',
                        textAlign: TextAlign.center,
                        style:
                            (landscape
                                    ? Theme.of(context).textTheme.headlineSmall
                                    : Theme.of(
                                        context,
                                      ).textTheme.headlineMedium)
                                ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      if (!landscape) ...[
                        const SizedBox(height: 4),
                        Text(
                          '소규모 화상회의 · 웹 / 모바일 / 디스플레이',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                      SizedBox(height: landscape ? 16 : 24),

                      // 참여 / 만들기 탭
                      SegmentedButton<_Tab>(
                        segments: const [
                          ButtonSegment(
                            value: _Tab.join,
                            label: Text('참여하기'),
                            icon: Icon(Icons.login),
                          ),
                          ButtonSegment(
                            value: _Tab.create,
                            label: Text('방 만들기'),
                            icon: Icon(Icons.add_circle_outline),
                          ),
                        ],
                        selected: {_tab},
                        onSelectionChanged: (s) => setState(() {
                          _tab = s.first;
                          _pinCtrl.clear(); // 탭 바꾸면 입장코드 초기화(잔상 방지)
                        }),
                      ),
                      SizedBox(height: gap),

                      // 방 코드/이름 — 영문·숫자·하이픈만 (한글 불가)
                      if (isJoin)
                        TextField(
                          controller: _codeCtrl,
                          focusNode: _codeFocus,
                          textInputAction: TextInputAction.next,
                          inputFormatters: [
                            FilteringTextInputFormatter.allow(
                              RegExp(r'[a-zA-Z0-9-]'),
                            ),
                          ],
                          decoration: const InputDecoration(
                            labelText: '방 코드',
                            hintText: '예: abc-defg-hij',
                            prefixIcon: Icon(Icons.meeting_room_outlined),
                            border: OutlineInputBorder(),
                          ),
                        )
                      else
                        TextField(
                          controller: _customCtrl,
                          focusNode: _customFocus,
                          textInputAction: TextInputAction.next,
                          inputFormatters: [
                            FilteringTextInputFormatter.allow(
                              RegExp(r'[a-zA-Z0-9-]'),
                            ),
                          ],
                          decoration: const InputDecoration(
                            labelText: '방 이름 (선택)',
                            hintText: '영문·숫자·- 만 (비우면 자동)',
                            prefixIcon: Icon(Icons.meeting_room_outlined),
                            border: OutlineInputBorder(),
                          ),
                        ),
                      SizedBox(height: gap),

                      // 방 만들기: 비공개 체크 + (체크 시) 옆에 입장 코드
                      if (!isJoin)
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            // 행 전체를 InkWell로 → 리모컨(D-pad) 포커스 이동 가능
                            Expanded(
                              child: InkWell(
                                onTap: () =>
                                    setState(() => _private = !_private),
                                borderRadius: BorderRadius.circular(8),
                                focusColor: Colors.white24,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 4,
                                  ),
                                  child: Row(
                                    children: [
                                      // 체크박스는 포커스 대상에서 제외(InkWell이 담당)
                                      ExcludeFocus(
                                        child: Checkbox(
                                          value: _private,
                                          onChanged: (v) => setState(
                                            () => _private = v ?? false,
                                          ),
                                        ),
                                      ),
                                      const Flexible(
                                        child: Text(
                                          '비공개 방 (입장 코드)',
                                          style: TextStyle(fontSize: 14),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            if (_private) ...[
                              const SizedBox(width: 8),
                              SizedBox(
                                width: 180,
                                child: TextField(
                                  controller: _pinCtrl,
                                  focusNode: _pinFocus,
                                  textInputAction: TextInputAction.next,
                                  keyboardType: TextInputType.number,
                                  inputFormatters: [
                                    FilteringTextInputFormatter.digitsOnly,
                                    LengthLimitingTextInputFormatter(6),
                                  ],
                                  decoration: const InputDecoration(
                                    labelText: '입장 코드',
                                    hintText: '숫자 6자리',
                                    border: OutlineInputBorder(),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),

                      // 참여 탭: 입장 코드(선택) 전체폭
                      if (isJoin) ...[
                        TextField(
                          controller: _pinCtrl,
                          focusNode: _pinFocus,
                          textInputAction: TextInputAction.next,
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                            LengthLimitingTextInputFormatter(6),
                          ],
                          decoration: const InputDecoration(
                            labelText: '입장 코드 (비공개 방일 경우)',
                            hintText: '공개 방이면 비워두세요',
                            prefixIcon: Icon(Icons.password_outlined),
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ],
                      SizedBox(height: gap),

                      TextField(
                        controller: _nameCtrl,
                        focusNode: _nameFocus,
                        textInputAction: TextInputAction.done,
                        decoration: const InputDecoration(
                          labelText: '내 이름 (선택)',
                          prefixIcon: Icon(Icons.person_outline),
                          border: OutlineInputBorder(),
                        ),
                      ),

                      if (_error != null) ...[
                        SizedBox(height: gap),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.red.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            _error!,
                            style: const TextStyle(color: Color(0xFFFF8A80)),
                          ),
                        ),
                      ],

                      SizedBox(height: landscape ? 14 : 24),
                      FilledButton.icon(
                        autofocus: true,
                        onPressed: _connecting ? null : _join,
                        style: FilledButton.styleFrom(
                          padding: EdgeInsets.symmetric(
                            vertical: landscape ? 14 : 18,
                          ),
                        ),
                        icon: _connecting
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Icon(isJoin ? Icons.login : Icons.add),
                        label: Text(
                          _connecting
                              ? '접속 중...'
                              : (isJoin ? '회의 입장' : '방 만들기 & 입장'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            // 앱 버전 표시 (우측 상단)
            Positioned(
              top: 0,
              right: 0,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.only(top: 8, right: 14),
                  child: Text(
                    'v${AppConfig.appVersion}',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.white.withValues(alpha: 0.45),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
