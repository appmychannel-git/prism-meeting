import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

import 'config.dart';

/// Firebase 인증(보안 규칙용). 로그인 화면 없이, 우리 기기 신원(uuid)을 그대로
/// Firebase 인증 uid 로 사용한다.
///
/// 흐름: 앱이 토큰서버 /authtoken 에 내 uuid 를 보내 **커스텀 토큰**을 받고,
/// signInWithCustomToken 으로 로그인 → `request.auth.uid == 내 uuid`.
/// 이렇게 하면 보안 규칙에서 "본인/당사자만" 판별이 가능하고, uuid 가
/// (ANDROID_ID 기반) 재설치에도 유지되므로 인증도 재설치에 유지된다.
class AuthService {
  /// 내 uuid 로 로그인돼 있지 않으면 커스텀 토큰을 받아 로그인.
  /// 실패해도 예외를 던지지 않는다(규칙 적용 전에는 인증 없이도 동작해야 하므로).
  static Future<void> ensureSignedIn(String uuid) async {
    if (uuid.isEmpty) return;
    final auth = FirebaseAuth.instance;
    if (auth.currentUser?.uid == uuid) return;
    try {
      final url = AppConfig.tokenServerUrl
          .replaceFirst(RegExp(r'/token/?$'), '/authtoken');
      final resp = await http
          .post(
            Uri.parse(url),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'uuid': uuid}),
          )
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return;
      final token = (jsonDecode(resp.body)['token'] ?? '').toString();
      if (token.isEmpty) return;
      await auth.signInWithCustomToken(token);
    } catch (_) {
      // 인증 실패 시 조용히 진행(규칙 적용 전에는 문제 없음).
    }
  }
}
