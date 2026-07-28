import 'package:flutter/material.dart';

/// 실시간 자막 한 줄(발화자별 현재 문장).
class LiveCaption {
  final String identity; // 발화자 고정 식별값
  final String sender; // 발화자 표시 이름
  String text; // 인식된 원문(발화 언어)
  String lang; // 발화 언어 코드(2-letter)
  bool isFinal; // 확정된 문장인지(중간 결과=false)
  String? translated; // 내 언어로 번역
  String? translatedLang; // translated 의 언어 코드
  DateTime updatedAt; // 마지막 갱신 시각(오래되면 자동 숨김)
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

/// 화면 하단 자막 오버레이(줌 스타일). 활성 자막 몇 줄을 원문+번역으로 표시.
class CaptionOverlay extends StatelessWidget {
  final List<LiveCaption> captions;
  final String myLang; // 내가 읽을 언어(번역 대상)
  const CaptionOverlay({
    super.key,
    required this.captions,
    required this.myLang,
  });

  @override
  Widget build(BuildContext context) {
    if (captions.isEmpty) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.bottomCenter,
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final c in captions) _line(c),
          ],
        ),
      ),
    );
  }

  Widget _line(LiveCaption c) {
    final showTr = !c.mine &&
        c.translated != null &&
        c.translated!.isNotEmpty &&
        c.translatedLang == myLang;
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
