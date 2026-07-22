import 'package:flutter/foundation.dart' show kIsWeb, kDebugMode;
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

enum _Mode { server, manual }

class _JoinScreenState extends State<JoinScreen> {
  final _roomCtrl = TextEditingController(text: AppConfig.defaultRoomName);
  final _nameCtrl = TextEditingController();
  final _urlCtrl = TextEditingController();
  final _tokenCtrl = TextEditingController();

  late final FocusNode _roomFocus = _fieldNode();
  late final FocusNode _nameFocus = _fieldNode();
  late final FocusNode _urlFocus = _fieldNode();
  late final FocusNode _tokenFocus = _fieldNode();

  late _Mode _mode =
      AppConfig.tokenServerUrl.isNotEmpty ? _Mode.server : _Mode.manual;
  bool _connecting = false;
  String? _error;

  /// 입력칸용 FocusNode.
  /// 안드로이드TV 리모컨: ↑/↓ 를 글자 커서가 아니라 "포커스 이동"으로 처리한다.
  /// (←/→ 는 그대로 두어 글자 편집 가능)
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
    _roomCtrl.dispose();
    _nameCtrl.dispose();
    _urlCtrl.dispose();
    _tokenCtrl.dispose();
    _roomFocus.dispose();
    _nameFocus.dispose();
    _urlFocus.dispose();
    _tokenFocus.dispose();
    super.dispose();
  }

  Future<bool> _ensurePermissions() async {
    // 웹은 브라우저가 접속 시점에 직접 권한을 묻는다.
    if (kIsWeb) return true;
    final statuses = await [Permission.camera, Permission.microphone].request();
    return statuses.values.every((s) => s.isGranted || s.isLimited);
  }

  Future<void> _join() async {
    setState(() {
      _error = null;
      _connecting = true;
    });
    try {
      final name = _nameCtrl.text.trim().isEmpty
          ? '게스트-${DateTime.now().millisecondsSinceEpoch % 1000}'
          : _nameCtrl.text.trim();
      final room = _roomCtrl.text.trim();
      if (room.isEmpty) throw Exception('방 이름을 입력하세요.');

      final granted = await _ensurePermissions();
      if (!granted) {
        throw Exception('카메라/마이크 권한이 필요합니다. 설정에서 허용해주세요.');
      }

      final ConnectionDetails details;
      if (_mode == _Mode.server) {
        if (AppConfig.tokenServerUrl.isEmpty) {
          throw Exception(
              '토큰 서버 주소가 설정되지 않았습니다. lib/config.dart 를 확인하세요.');
        }
        details = await ConnectionService.fetchFromServer(
          tokenServerUrl: AppConfig.tokenServerUrl,
          roomName: room,
          participantName: name,
          identity: AppConfig.deviceIdentity,
        );
      } else {
        if (_urlCtrl.text.trim().isEmpty || _tokenCtrl.text.trim().isEmpty) {
          throw Exception('서버 URL과 토큰을 모두 입력하세요.');
        }
        details = ConnectionService.manual(
          serverUrl: _urlCtrl.text,
          token: _tokenCtrl.text,
        );
      }

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

  bool get _anyFieldFocused =>
      _roomFocus.hasFocus ||
      _nameFocus.hasFocus ||
      _urlFocus.hasFocus ||
      _tokenFocus.hasFocus;

  @override
  Widget build(BuildContext context) {
    final hasServer = AppConfig.tokenServerUrl.isNotEmpty;
    // "토큰 서버 / 직접 입력" 토글은 개발/디버깅용.
    // 릴리즈 빌드(거래처 전달용)에서는 숨기고 항상 토큰 서버만 사용한다.
    final showModeToggle = hasServer && kDebugMode;
    return PopScope(
      // 입력칸에 포커스가 있을 때 리모컨 Back = 앱 종료가 아니라 "포커스 아웃".
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_anyFieldFocused) {
          FocusScope.of(context).unfocus();
        } else {
          SystemNavigator.pop(); // 실제로 나가려는 경우만 종료
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
                const SizedBox(height: 32),

                // 접속 방식 선택 (디버그 빌드에서만 노출, 릴리즈에선 숨김)
                if (showModeToggle) ...[
                  SegmentedButton<_Mode>(
                    segments: const [
                      ButtonSegment(
                          value: _Mode.server,
                          label: Text('토큰 서버'),
                          icon: Icon(Icons.cloud_outlined)),
                      ButtonSegment(
                          value: _Mode.manual,
                          label: Text('직접 입력'),
                          icon: Icon(Icons.edit_outlined)),
                    ],
                    selected: {_mode},
                    onSelectionChanged: (s) => setState(() => _mode = s.first),
                  ),
                  const SizedBox(height: 20),
                ],

                TextField(
                  controller: _roomCtrl,
                  focusNode: _roomFocus,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: '방 이름',
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

                if (_mode == _Mode.manual) ...[
                  const SizedBox(height: 16),
                  TextField(
                    controller: _urlCtrl,
                    focusNode: _urlFocus,
                    decoration: const InputDecoration(
                      labelText: '서버 URL (wss://...)',
                      prefixIcon: Icon(Icons.dns_outlined),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _tokenCtrl,
                    focusNode: _tokenFocus,
                    maxLines: 2,
                    decoration: const InputDecoration(
                      labelText: '참가자 토큰',
                      prefixIcon: Icon(Icons.vpn_key_outlined),
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],

                if (!hasServer && _mode == _Mode.manual) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.amber.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text(
                      '💡 token-server/ 를 실행하고 lib/config.dart(또는 --dart-define=LK_TOKEN_URL)'
                      '에 토큰 서버 주소를 넣으면 URL/토큰 없이 방 이름만으로 접속됩니다.',
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
                  // 리모컨이 처음에 이 버튼에 놓이도록(방 이름은 기본값이 채워져 있음).
                  // ↑ 키로 입력칸으로 올라가 편집 가능.
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
                      : const Icon(Icons.login),
                  label: Text(_connecting ? '접속 중...' : '회의 입장'),
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
