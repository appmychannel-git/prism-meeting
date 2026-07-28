import 'package:flutter/material.dart';

import 'config.dart';

/// 채팅 메시지 한 건.
///
/// 번역 상태(번역문/진행중/실패)는 수신 후 변할 수 있어 가변 필드로 둔다.
/// 상위(RoomScreen)가 이 객체를 직접 갱신하고 setState 로 다시 그린다.
class ChatMessage {
  final String sender;
  final String text; // 원문
  final bool mine; // 내가 보낸 메시지인지
  String? translated; // 번역문(있으면 원문과 함께 표시)
  bool translating; // 번역 요청 중
  String? translateError; // 번역 실패 메시지
  ChatMessage({
    required this.sender,
    required this.text,
    required this.mine,
    this.translated,
    this.translating = false,
    this.translateError,
  });
}

/// 회의 화면 우측에 열리는 채팅 패널.
///
/// 메시지 송수신 로직은 RoomScreen(LiveKit 연결부)에 있고,
/// 이 위젯은 표시 + 입력 + 번역 트리거만 담당한다.
class ChatPanel extends StatefulWidget {
  final List<ChatMessage> messages;
  final void Function(String text) onSend;
  // 닫기 동작. null이면 드로어처럼 Navigator.maybePop()(오버레이 닫기).
  // 인라인(영상 옆) 모드에선 상위에서 setState로 패널을 접는 콜백을 넘긴다.
  final VoidCallback? onClose;
  // 번역 대상(선호) 언어 코드 + 변경 콜백.
  final String targetLanguage;
  final ValueChanged<String> onLanguageChange;
  // 특정 메시지를 현재 대상 언어로 번역 요청.
  final void Function(ChatMessage msg) onTranslate;
  const ChatPanel({
    super.key,
    required this.messages,
    required this.onSend,
    required this.targetLanguage,
    required this.onLanguageChange,
    required this.onTranslate,
    this.onClose,
  });

  @override
  State<ChatPanel> createState() => _ChatPanelState();
}

class _ChatPanelState extends State<ChatPanel> {
  final _inputCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();

  @override
  void didUpdateWidget(covariant ChatPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 새 메시지가 들어오면 맨 아래로 스크롤
    if (widget.messages.length != oldWidget.messages.length) {
      _scrollToBottom();
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
      }
    });
  }

  void _send() {
    final text = _inputCtrl.text.trim();
    if (text.isEmpty) return;
    widget.onSend(text);
    _inputCtrl.clear();
  }

  @override
  void dispose() {
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          // 헤더
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
            child: Row(
              children: [
                const Icon(Icons.chat_bubble_outline, size: 20),
                const SizedBox(width: 8),
                Text(
                  '채팅',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                // 번역 대상(선호) 언어 선택
                _LanguageSelector(
                  value: widget.targetLanguage,
                  onChanged: widget.onLanguageChange,
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: '닫기',
                  onPressed:
                      widget.onClose ?? () => Navigator.of(context).maybePop(),
                ),
              ],
            ),
          ),
          const Divider(height: 1),

          // 메시지 목록
          Expanded(
            child: widget.messages.isEmpty
                ? const Center(
                    child: Text(
                      '아직 메시지가 없습니다.',
                      style: TextStyle(color: Colors.white38),
                    ),
                  )
                : ListView.builder(
                    controller: _scrollCtrl,
                    padding: const EdgeInsets.all(12),
                    itemCount: widget.messages.length,
                    itemBuilder: (_, i) => _Bubble(
                      msg: widget.messages[i],
                      onTranslate: () =>
                          widget.onTranslate(widget.messages[i]),
                    ),
                  ),
          ),

          // 입력 줄
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _inputCtrl,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _send(),
                    minLines: 1,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      hintText: '메시지 입력...',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                IconButton.filled(
                  onPressed: _send,
                  icon: const Icon(Icons.send),
                  tooltip: '보내기',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 번역 대상 언어 드롭다운(🌐 + 언어명).
class _LanguageSelector extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;
  const _LanguageSelector({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: '번역 언어',
      initialValue: value,
      onSelected: onChanged,
      itemBuilder: (_) => [
        for (final e in AppConfig.supportedLanguages.entries)
          PopupMenuItem(value: e.key, child: Text(e.value)),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.translate, size: 18),
            const SizedBox(width: 4),
            Text(
              AppConfig.supportedLanguages[value] ?? value,
              style: const TextStyle(fontSize: 13),
            ),
            const Icon(Icons.arrow_drop_down, size: 18),
          ],
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  final ChatMessage msg;
  final VoidCallback onTranslate;
  const _Bubble({required this.msg, required this.onTranslate});

  @override
  Widget build(BuildContext context) {
    final mine = msg.mine;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: mine
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          if (!mine)
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 2),
              child: Text(
                msg.sender,
                style: const TextStyle(fontSize: 11, color: Colors.white54),
              ),
            ),
          Container(
            constraints: const BoxConstraints(maxWidth: 240),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: mine ? const Color(0xFF3B6FE0) : const Color(0xFF2A313B),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 원문
                Text(msg.text, style: const TextStyle(fontSize: 14)),
                // 번역 영역(내가 받은 메시지에만): 번역문 or 번역 버튼 or 상태
                if (!mine) _translationArea(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _translationArea() {
    // 번역문이 있으면 원문 아래에 함께 표시(원문 + 번역 동시)
    if (msg.translated != null) {
      return Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Divider(height: 1, color: Colors.white24),
            const SizedBox(height: 6),
            Row(
              children: const [
                Icon(Icons.translate, size: 12, color: Colors.white38),
                SizedBox(width: 4),
                Text(
                  '번역',
                  style: TextStyle(fontSize: 10, color: Colors.white38),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              msg.translated!,
              style: const TextStyle(fontSize: 14, color: Color(0xFFBFE0C0)),
            ),
          ],
        ),
      );
    }
    if (msg.translating) {
      return const Padding(
        padding: EdgeInsets.only(top: 6),
        child: Row(
          children: [
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 6),
            Text('번역 중...',
                style: TextStyle(fontSize: 11, color: Colors.white54)),
          ],
        ),
      );
    }
    // 아직 번역 안 함 → 번역 버튼(실패 시 재시도 문구)
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: InkWell(
        onTap: onTranslate,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.translate, size: 13, color: Color(0xFF9FC0FF)),
            const SizedBox(width: 4),
            Text(
              msg.translateError == null ? '번역' : '다시 시도',
              style: const TextStyle(
                fontSize: 12,
                color: Color(0xFF9FC0FF),
                fontWeight: FontWeight.w600,
              ),
            ),
            if (msg.translateError != null) ...[
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  msg.translateError!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 10, color: Colors.white38),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
