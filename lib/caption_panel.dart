import 'package:flutter/material.dart';

import 'caption_overlay.dart'; // LiveCaption
import 'config.dart';
import 'l10n.dart';
import 'transcript_download_io.dart'
    if (dart.library.html) 'transcript_download_web.dart';

/// 자막 전체 기록 패널(왼쪽). 채팅 패널과 비슷하게, 말한 내역 전부를
/// 원문+번역으로 스크롤해서 볼 수 있다(하단 8줄 오버레이와 별개).
class CaptionPanel extends StatefulWidget {
  final List<LiveCaption> lines;
  final String myLang;
  final bool compareOn;
  final VoidCallback? onClose;
  const CaptionPanel({
    super.key,
    required this.lines,
    required this.myLang,
    this.compareOn = false,
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

  // 현재 화면에 보이는 그대로(원문 + 선택 언어 번역 / 비교 엔진) 텍스트로 만든다.
  String _buildText() {
    final buf = StringBuffer();
    final now = DateTime.now();
    buf.writeln('${L.t('transcript')} — '
        '${now.year}-${_pad2(now.month)}-${_pad2(now.day)} '
        '${_pad2(now.hour)}:${_pad2(now.minute)}');
    buf.writeln('');
    for (final c in widget.lines) {
      buf.writeln('${c.sender}: ${c.text}');
      final translatable = !c.mine && c.lang != widget.myLang;
      if (widget.compareOn && translatable) {
        for (final eng in AppConfig.compareEngines) {
          final t = c.compareTexts[eng] ??
              (c.compareErrs[eng] != null ? '✕ ${c.compareErrs[eng]}' : '');
          if (t.isNotEmpty) {
            buf.writeln('  [${AppConfig.engineLabels[eng] ?? eng}] $t');
          }
        }
      } else if (translatable &&
          c.translated != null &&
          c.translated!.isNotEmpty &&
          c.translatedLang == widget.myLang) {
        buf.writeln('  → ${c.translated}');
      }
    }
    return buf.toString();
  }

  static String _pad2(int n) => n.toString().padLeft(2, '0');

  Future<void> _download() async {
    final now = DateTime.now();
    final name =
        'caption_${now.year}${_pad2(now.month)}${_pad2(now.day)}_${_pad2(now.hour)}${_pad2(now.minute)}${_pad2(now.second)}.txt';
    try {
      await saveTranscript(name, _buildText());
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${L.t('transcript_download')}: $e')),
        );
      }
    }
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
                  icon: const Icon(Icons.download),
                  tooltip: L.t('transcript_download'),
                  onPressed: widget.lines.isEmpty ? null : _download,
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
          Expanded(
            child: widget.lines.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        L.t(AppConfig.serverStt
                            ? 'caption_empty_hint_server'
                            : 'caption_empty_hint'),
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
          if (widget.compareOn && !c.mine && c.lang != widget.myLang)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final eng in AppConfig.compareEngines)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(AppConfig.engineLabels[eng] ?? eng,
                              style: const TextStyle(
                                  fontSize: 9,
                                  color: Colors.white38,
                                  fontWeight: FontWeight.bold)),
                          Text(
                            c.compareTexts[eng] ??
                                (c.compareErrs[eng] != null
                                    ? '✕ ${c.compareErrs[eng]}'
                                    : '…'),
                            style: TextStyle(
                              fontSize: 13,
                              height: 1.2,
                              color: c.compareTexts[eng] != null
                                  ? const Color(0xFF9FE0A6)
                                  : Colors.white38,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            )
          else if (showTr)
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
