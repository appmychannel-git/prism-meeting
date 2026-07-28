import 'package:flutter/material.dart';

import 'caption_overlay.dart'; // LiveCaption
import 'l10n.dart';

/// 자막 전체 기록 패널(왼쪽). 채팅 패널과 비슷하게, 말한 내역 전부를
/// 원문+번역으로 스크롤해서 볼 수 있다(하단 8줄 오버레이와 별개).
class CaptionPanel extends StatefulWidget {
  final List<LiveCaption> lines;
  final String myLang;
  final VoidCallback? onClose;
  const CaptionPanel({
    super.key,
    required this.lines,
    required this.myLang,
    this.onClose,
  });

  @override
  State<CaptionPanel> createState() => _CaptionPanelState();
}

class _CaptionPanelState extends State<CaptionPanel> {
  final _scroll = ScrollController();

  @override
  void didUpdateWidget(covariant CaptionPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.lines.length != oldWidget.lines.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
            child: Row(
              children: [
                const Icon(Icons.subject, size: 20),
                const SizedBox(width: 8),
                Text(
                  L.t('transcript'),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
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
          Expanded(
            child: widget.lines.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        L.t('caption_empty_hint'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white38),
                      ),
                    ),
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(12),
                    itemCount: widget.lines.length,
                    itemBuilder: (_, i) => _row(widget.lines[i]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _row(LiveCaption c) {
    final showTr = !c.mine &&
        c.translated != null &&
        c.translated!.isNotEmpty &&
        c.translatedLang == widget.myLang;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            c.sender,
            style: const TextStyle(fontSize: 11, color: Colors.white54),
          ),
          Text(
            c.text,
            style: TextStyle(
              fontSize: 14,
              height: 1.25,
              color: c.isFinal ? Colors.white : Colors.white70,
            ),
          ),
          if (showTr)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                c.translated!,
                style: const TextStyle(
                  fontSize: 14,
                  height: 1.25,
                  color: Color(0xFF9FE0A6),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
