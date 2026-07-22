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

  late final FocusNode _codeFocus = _fieldNode();
  late final FocusNode _customFocus = _fieldNode();
  late final FocusNode _nameFocus = _fieldNode();

  _Tab _tab = _Tab.create;
  bool _connecting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // 웹 초대 링크(...?room=코드)로 열리면 → 참여 탭 + 코드 자동 입력
    final linkedRoom = Uri.base.queryParameters['room'];
    if (linkedRoom != null && linkedRoom.trim().isNotEmpty) {
      _tab = _Tab.join;
      _codeCtrl.text = linkedRoom.trim();
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
    _nameCtrl.dispose();
    _codeCtrl.dispose();
    _customCtrl.dispose();
    _codeFocus.dispose();
    _customFocus.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  bool get _anyFieldFocused =>
      _codeFocus.hasFocus || _customFocus.hasFocus || _nameFocus.hasFocus;

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
      // 방 코드 결정
      final String room;
      if (_tab == _Tab.join) {
        room = _codeCtrl.text.trim();
        if (room.isEmpty) throw Exception('방 코드를 입력하세요.');
      } else {
        final custom = _customCtrl.text.trim();
        room = custom.isEmpty ? AppConfig.generateRoomCode() : custom;
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
      );

      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => RoomScreen(
            details: details,
            roomName: room,
            displayName: name,
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
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.video_camera_front_rounded,
                      size: 64, color: Color(0xFF5B8DEF)),
                  const SizedBox(height: 12),
                  Text('Prism Meeting',
                      textAlign: TextAlign.center,
                      style: Theme.of(context)
                          .textTheme
                          .headlineMedium
                          ?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text('소규모 화상회의 · 웹 / 모바일 / 디스플레이',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 28),

                  // 참여 / 만들기 탭
                  SegmentedButton<_Tab>(
                    segments: const [
                      ButtonSegment(
                          value: _Tab.join,
                          label: Text('참여하기'),
                          icon: Icon(Icons.login)),
                      ButtonSegment(
                          value: _Tab.create,
                          label: Text('방 만들기'),
                          icon: Icon(Icons.add_circle_outline)),
                    ],
                    selected: {_tab},
                    onSelectionChanged: (s) => setState(() => _tab = s.first),
                  ),
                  const SizedBox(height: 20),

                  if (isJoin)
                    TextField(
                      controller: _codeCtrl,
                      focusNode: _codeFocus,
                      textInputAction: TextInputAction.next,
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
                      decoration: const InputDecoration(
                        labelText: '방 이름 (선택)',
                        hintText: '비우면 자동 코드 생성',
                        prefixIcon: Icon(Icons.meeting_room_outlined),
                        border: OutlineInputBorder(),
                      ),
                    ),
                  const SizedBox(height: 16),

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

                  if (!isJoin) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF5B8DEF).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Text(
                        '💡 방을 만들면 회의 화면에서 "초대 링크 복사"로 참여자에게 링크를 보낼 수 있어요.',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                  ],

                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.red.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(_error!,
                          style: const TextStyle(color: Color(0xFFFF8A80))),
                    ),
                  ],

                  const SizedBox(height: 24),
                  FilledButton.icon(
                    autofocus: true,
                    onPressed: _connecting ? null : _join,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 18),
                    ),
                    icon: _connecting
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(isJoin ? Icons.login : Icons.add),
                    label: Text(_connecting
                        ? '접속 중...'
                        : (isJoin ? '회의 입장' : '방 만들기 & 입장')),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
