import 'dart:convert';
import 'package:http/http.dart' as http;

import 'config.dart';

/// 번역 결과: 번역문 + 감지된 원문 언어 코드.
class TranslationResult {
  final String translatedText;
  final String detectedSourceLanguage;
  const TranslationResult(this.translatedText, this.detectedSourceLanguage);
}

/// 채팅 번역 클라이언트.
///
/// 토큰 서버의 `POST /translate` 프록시(그 뒤에 Google Cloud Translation)를
/// 호출한다. Google API 키는 서버에만 있고 앱엔 없다.
/// 같은 (대상언어, 원문) 조합은 캐시해 재요청/과금을 줄인다.
class TranslationService {
  static final Map<String, TranslationResult> _cache = {};

  static Future<TranslationResult> translate(String text, String target) async {
    final key = '$target|$text';
    final cached = _cache[key];
    if (cached != null) return cached;

    final res = await http
        .post(
          Uri.parse(AppConfig.translateServerUrl),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'text': text, 'target': target}),
        )
        .timeout(const Duration(seconds: 15));

    final bodyText = utf8.decode(res.bodyBytes);
    if (res.statusCode != 200) {
      String msg = '(HTTP ${res.statusCode})';
      try {
        final m = jsonDecode(bodyText) as Map<String, dynamic>;
        if (m['error'] != null) msg = m['error'].toString();
      } catch (_) {}
      throw Exception(msg);
    }

    final m = jsonDecode(bodyText) as Map<String, dynamic>;
    final out = TranslationResult(
      (m['translatedText'] ?? '').toString(),
      (m['detectedSourceLanguage'] ?? '').toString(),
    );
    _cache[key] = out;
    return out;
  }
}
