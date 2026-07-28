import 'package:flutter/material.dart';

/// 실시간 자막 한 줄(확정 문장 또는 말하는 중인 문장).
class LiveCaption {
  final String identity; // 발화자 고정 식별값
  final String sender; // 발화자 표시 이름
  String text; // 인식된 원문(발화 언어)
  String lang; // 발화 언어 코드(2-letter)
  bool isFinal; // 확정된 문장인지(중간 결과=false)
  String? translated; // 내 언어로 번역
  String? translatedLang; // translated 의 언어 코드
  DateTime updatedAt; // 마지막 갱신 시각
  bool mine; // 내가 말한 자막인지(번역 안 함)
  LiveCaption({
    required this.identity,
    required this.sender,
    required this.text,
    required this.lang,
    required this.isFinal,
    required this.updatedAt,
    this.translated,
    this.translatedLang,
    this.mine = false,
  });
}

/// 화면 하단 자막 오버레이(줌 스타일). 최근 여러 줄을 원문+번역으로 표시하고,
/// 새 줄이 오면 자동으로 맨 아래로 스크롤한다. 높이는 화면 일부로 제한.
class CaptionOverlay extends StatefulWidget {
  final List<LiveCaption> lines;
  final String myLang; // 내가 읽을 언어(번역 대상)
  final int maxLines; // 표시 줄 수 참고값(높이 계산용)
  const CaptionOverlay({
    super.key,
    required this.lines,
    required this.myLang,
    this.maxLines = 8,
  });

  @override
  State<CaptionOverlay> createState() => _CaptionOverlayState();
}

class _CaptionOverlayState extends State<CaptionOverlay> {
  final _scrollCtrl = ScrollController();

  @override
  void didUpdateWidget(covariant CaptionOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 새 줄/갱신 시 맨 아래로.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
      }
    });
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.lines.isEmpty) return const SizedBox.shrink();
    // 최대 높이: 화면의 약 38% 로 제한(그 이상은 내부 스크롤).
    final maxH = MediaQuery.of(context).size.height * 0.38;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      constraints: BoxConstraints(maxHeight: maxH),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(10),
      ),
      child: SingleChildScrollView(
        controller: _scrollCtrl,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final c in widget.lines) _line(c),
          ],
        ),
      ),
    );
  }

  Widget _line(LiveCaption c) {
    final showTr = !c.mine &&
        c.translated != null &&
        c.translated!.isNotEmpty &&
        c.translatedLang == widget.myLang;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
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
              fontSize: 15,
              height: 1.25,
              // 말하는 중(미확정)은 약간 흐리게.
              color: c.isFinal ? Colors.white : Colors.white70,
            ),
          ),
          if (showTr)
            Text(
              c.translated!,
              style: const TextStyle(
                fontSize: 15,
                height: 1.25,
                color: Color(0xFF9FE0A6),
              ),
            ),
        ],
      ),
    );
  }
}
