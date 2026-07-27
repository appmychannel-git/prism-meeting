import 'package:flutter/material.dart';

/// 채팅 메시지 한 건.
class ChatMessage {
  final String sender;
  final String text;
  final bool mine; // 내가 보낸 메시지인지
  const ChatMessage({
    required this.sender,
    required this.text,
    required this.mine,
  });
}

/// 회의 화면 우측에 열리는 채팅 패널.
///
/// 메시지 송수신 로직은 RoomScreen(LiveKit 연결부)에 있고,
/// 이 위젯은 표시 + 입력만 담당한다. [onSend] 로 입력값을 넘긴다.
class ChatPanel extends StatefulWidget {
  final List<ChatMessage> messages;
  final void Function(String text) onSend;
  // 닫기 동작. null이면 드로어처럼 Navigator.maybePop()(오버레이 닫기).
  // 인라인(영상 옆) 모드에선 상위에서 setState로 패널을 접는 콜백을 넘긴다.
  final VoidCallback? onClose;
  const ChatPanel({
    super.key,
    required this.messages,
    required this.onSend,
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
                    itemBuilder: (_, i) => _Bubble(msg: widget.messages[i]),
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

class _Bubble extends StatelessWidget {
  final ChatMessage msg;
  const _Bubble({required this.msg});

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
            child: Text(msg.text, style: const TextStyle(fontSize: 14)),
          ),
        ],
      ),
    );
  }
}
