import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'config.dart';
import 'l10n.dart';

/// 서브앱 실행 권한 정책(서버 app-policy.asp). 하드코딩 대신 서버 값으로 티어를 정한다.
///  - none       : 조건 없음 → 전체 허용
///  - login      : 로그인 필요(세션)
///  - registered : 로그인 + 기기 시리얼 인증(registered=Y)
/// 규칙: md/subapp-access-policy-guide-2026-10-15.md (fail-open, cache_sec 존중).
enum AccessPolicy { none, login, registered }

class AppPolicyResult {
  final AccessPolicy policy;
  final String denyMessage; // 서버 안내 문구(시리얼 등록 필요 등)
  const AppPolicyResult(this.policy, {this.denyMessage = ''});
}

class AppPolicy {
  AppPolicy._();

  static const _kValue = 'app_policy_value';
  static const _kDeny = 'app_policy_deny';
  static const _kExpiry = 'app_policy_expiry_ms';

  // 모르는 값/빈 값은 login 으로 간주(앱이 깨지지 않게).
  static AccessPolicy _parse(String? raw) {
    switch (raw?.toLowerCase()) {
      case 'none':
        return AccessPolicy.none;
      case 'registered':
        return AccessPolicy.registered;
      default:
        return AccessPolicy.login;
    }
  }

  /// 정책 조회. 캐시가 유효하면 그대로, 실패하면 fail-open(캐시값 → login).
  /// cuid 가 없으면(미지정 브랜드) 호출하지 않고 login 으로 본다.
  static Future<AppPolicyResult> fetch(
      {int marketVersionCode = 0, String model = ''}) async {
    final sp = await SharedPreferences.getInstance();
    final now = DateTime.now().millisecondsSinceEpoch;

    // 1. 캐시 유효하면 그대로.
    final exp = sp.getInt(_kExpiry) ?? 0;
    if (now < exp) {
      return AppPolicyResult(_parse(sp.getString(_kValue)),
          denyMessage: sp.getString(_kDeny) ?? '');
    }

    // cuid 없는 브랜드는 이 정책 체계를 안 쓴다 → login.
    if (AppConfig.cuid.isEmpty) {
      return const AppPolicyResult(AccessPolicy.login);
    }

    // 2. 서버 호출(타임아웃 3초).
    final params = <String, String>{
      'app': AppConfig.policyAppCode,
      'brand': AppConfig.certBrand,
      'cuid': AppConfig.cuid,
      'app_version_code': '${AppConfig.appVersionCode}',
      if (marketVersionCode > 0) 'market_version_code': '$marketVersionCode',
      'language': L.lang.isNotEmpty ? L.lang : 'ko',
      if (model.isNotEmpty) 'model': model,
    };
    try {
      final uri =
          Uri.parse(AppConfig.appPolicyUrl).replace(queryParameters: params);
      final r = await http.get(uri).timeout(const Duration(seconds: 3));
      if (r.statusCode == 200) {
        final j = jsonDecode(r.body) as Map<String, dynamic>;
        final res = j['result'];
        if (res is Map) {
          final raw = res['access_policy']?.toString();
          final deny = res['deny_message']?.toString() ?? '';
          final cacheSec =
              int.tryParse(res['cache_sec']?.toString() ?? '') ?? 3600;
          await sp.setString(_kValue, raw ?? 'login');
          await sp.setString(_kDeny, deny);
          await sp.setInt(_kExpiry, now + cacheSec * 1000);
          return AppPolicyResult(_parse(raw), denyMessage: deny);
        }
      }
    } catch (_) {}

    // 3. fail-open: 캐시값 있으면 그 값, 없으면 login. (절대 차단하지 않음)
    final cached = sp.getString(_kValue);
    if (cached != null) {
      return AppPolicyResult(_parse(cached),
          denyMessage: sp.getString(_kDeny) ?? '');
    }
    return const AppPolicyResult(AccessPolicy.login);
  }
}
