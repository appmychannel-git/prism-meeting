import 'package:flutter/material.dart';

import 'config.dart';
import 'l10n.dart';

/// 채팅 메시지 한 건.
///
/// 번역 상태(번역문/진행중/실패)는 수신 후 변할 수 있어 가변 필드로 둔다.
/// 상위(RoomScreen)가 이 객체를 직접 갱신하고 setState 로 다시 그린다.
class ChatMessage {
  final String sender;
  final String text; // 원문
  final bool mine; // 내가 보낸 메시지인지
  String? translated; // 번역문(있으면 원문과 함께 표시)
  String? translatedLang; // translated 가 어떤 언어로 된 것인지(대상 언어 코드)
  bool translating; // 번역 요청 중
  String? translateError; // 번역 실패 메시지
  ChatMessage({
    required this.sender,
    required this.text,
    required this.mine,
    this.translated,
    this.translatedLang,
    this.translating = false,
    this.translateError,
  });
}

/// 회의 화면 우측에 열리는 채팅 패널.
///
/// 메시지 송수신 로직은 RoomScreen(LiveKit 연결부)에 있고,
/// 이 위젯은 표시 + 입력 + 번역 언어 선택만 담당한다.
/// 번역은 언어를 고르면 RoomScreen 이 자동으로 수행한다(버튼 없음).
class ChatPanel extends StatefulWidget {
  final List<ChatMessage> messages;
  final void Function(String text) onSend;
  // 닫기 동작. null이면 드로어처럼 Navigator.maybePop()(오버레이 닫기).
  // 인라인(영상 옆) 모드에선 상위에서 setState로 패널을 접는 콜백을 넘긴다.
  final VoidCallback? onClose;
  // 번역 대상(선호) 언어 코드. ''(빈 문자열)이면 "사용 안 함"(번역 표시 안 함).
  final String targetLanguage;
  final ValueChanged<String> onLanguageChange;
  const ChatPanel({
    super.key,
    required this.messages,
    required this.onSend,
    required this.targetLanguage,
    required this.onLanguageChange,
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
                  L.t('chat'),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                // 번역 대상(선호) 언어 선택. '사용 안 함' 선택 시 번역 표시 안 함.
                // SHOW_TRANSLATION=false 빌드에선 숨김(번역 기능 비노출).
                if (AppConfig.showTranslation)
                  _LanguageSelector(
                    value: widget.targetLanguage,
                    onChanged: widget.onLanguageChange,
                  ),
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: L.t('close'),
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
                ? Center(
                    child: Text(
                      L.t('no_messages'),
                      style: const TextStyle(color: Colors.white38),
                    ),
                  )
                : ListView.builder(
                    controller: _scrollCtrl,
                    padding: const EdgeInsets.all(12),
                    itemCount: widget.messages.length,
                    itemBuilder: (_, i) => _Bubble(
                      msg: widget.messages[i],
                      targetLang: widget.targetLanguage,
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
                    decoration: InputDecoration(
                      hintText: L.t('message_hint'),
                      border: const OutlineInputBorder(),
                      contentPadding: const EdgeInsets.symmetric(
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
                  tooltip: L.t('send'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 번역 대상 언어 드롭다운. 맨 위 "사용 안 함"(값 '') + 지원 언어들.
class _LanguageSelector extends StatelessWidget {
  final String value; // '' = 사용 안 함
  final ValueChanged<String> onChanged;
  const _LanguageSelector({required this.value, required this.onChanged});

  String _label(String code) => code.isEmpty
      ? L.t('translate_off')
      : (AppConfig.supportedLanguages[code] ?? code);

  @override
  Widget build(BuildContext context) {
    final off = value.isEmpty;
    return PopupMenuButton<String>(
      tooltip: L.t('translate_lang'),
      initialValue: value,
      onSelected: onChanged,
      itemBuilder: (_) => [
        PopupMenuItem(value: '', child: Text(L.t('translate_off'))),
        const PopupMenuDivider(),
        for (final e in AppConfig.supportedLanguages.entries)
          PopupMenuItem(value: e.key, child: Text(e.value)),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.translate,
              size: 18,
              color: off ? Colors.white38 : const Color(0xFF9FC0FF),
            ),
            const SizedBox(width: 4),
            Text(
              _label(value),
              style: TextStyle(
                fontSize: 13,
                color: off ? Colors.white54 : null,
              ),
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
  final String targetLang; // '' = 사용 안 함
  const _Bubble({required this.msg, required this.targetLang});

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
                // 번역 영역(받은 메시지 + 언어 선택됨일 때만 자동 표시)
                if (!mine && targetLang.isNotEmpty) _translationArea(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _translationArea() {
    // 번역 진행 중
    if (msg.translating) {
      return Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(
          children: [
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 6),
            Text(L.t('translating'),
                style: const TextStyle(fontSize: 11, color: Colors.white54)),
          ],
        ),
      );
    }
    // 현재 대상 언어로 번역 완료 → 원문 아래에 함께 표시
    if (msg.translated != null && msg.translatedLang == targetLang) {
      return Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Divider(height: 1, color: Colors.white24),
            const SizedBox(height: 6),
            Row(
              children: [
                const Icon(Icons.translate, size: 12, color: Colors.white38),
                const SizedBox(width: 4),
                Text(
                  L.t('translation'),
                  style: const TextStyle(fontSize: 10, color: Colors.white38),
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
    // 실패
    if (msg.translateError != null) {
      return Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(
          '${L.t('translate_fail')}: ${msg.translateError!}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 10, color: Colors.white38),
        ),
      );
    }
    // 아직 시작 전(곧 자동 번역됨) → 아무것도 표시 안 함
    return const SizedBox.shrink();
  }
}
