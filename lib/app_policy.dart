import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'config.dart';
import 'l10n.dart';

/// 서브앱 실행 권한 정책(서버 app-policy.asp). 하드코딩 대신 서버 값으로 티어를 정한다.
///  - none       : 조건 없음 → 전체 허용
///  - login      : 로그인 필요(세션)
///  - registered : 로그인 + 기기 시리얼 인증(registered=Y)
/// 추가로 강제/권장 업데이트와 원격 차단(점검/중단)도 같은 응답으로 받는다.
/// 규칙: md/subapp-access-policy-guide-2026-10-15.md
///       md/subapp-force-update-and-remote-block-2026-10-19.md
enum AccessPolicy { none, login, registered }

class AppPolicyResult {
  final AccessPolicy policy;
  final String denyMessage; // 서버 안내 문구(시리얼 등록 필요 등)

  /// 강제 업데이트: 설치 버전(appVersionCode)이 이 값 "미만"이면 사용 차단. 0=없음.
  final int minVersionCode;

  /// 권장 업데이트: 이 값 "미만"이면 안내만(건너뛰기 가능). 0=없음.
  final int latestVersionCode;

  /// 업데이트 안내에서 열 주소(빈값이면 플레이스토어 기본 링크).
  final String updateUrl;

  /// 업데이트 화면 안내 문구(빈값이면 기본 문구). 강제·권장 공통.
  final String updateMessage;

  /// 원격 차단(점검/중단) — true면 앱 전체를 차단 화면으로.
  final bool blocked;
  final String blockMessage;

  const AppPolicyResult(
    this.policy, {
    this.denyMessage = '',
    this.minVersionCode = 0,
    this.latestVersionCode = 0,
    this.updateUrl = '',
    this.updateMessage = '',
    this.blocked = false,
    this.blockMessage = '',
  });

  /// 설치 버전 기준 강제 업데이트 필요 여부.
  bool get needsForceUpdate =>
      minVersionCode > 0 && AppConfig.appVersionCode < minVersionCode;

  /// 설치 버전 기준 권장 업데이트 안내 여부(강제가 아닐 때만 의미 있음).
  bool get hasRecommendedUpdate =>
      latestVersionCode > 0 && AppConfig.appVersionCode < latestVersionCode;
}

class AppPolicy {
  AppPolicy._();

  static const _kValue = 'app_policy_value';
  static const _kDeny = 'app_policy_deny';
  static const _kExpiry = 'app_policy_expiry_ms';
  static const _kMinVer = 'app_policy_min_ver';
  static const _kLatestVer = 'app_policy_latest_ver';
  static const _kUpdateUrl = 'app_policy_update_url';
  static const _kUpdateMsg = 'app_policy_update_msg';
  static const _kBlocked = 'app_policy_blocked';
  static const _kBlockMsg = 'app_policy_block_msg';

  /// 브랜드 기본 정책(서버 무응답·미지정·캐시없음일 때). mychannel='none' 등.
  /// (config 값은 리터럴로만 해석 — 모르는 값은 login.)
  static AccessPolicy get _brandDefault {
    switch (AppConfig.accessPolicyDefault.toLowerCase()) {
      case 'none':
        return AccessPolicy.none;
      case 'registered':
        return AccessPolicy.registered;
      default:
        return AccessPolicy.login;
    }
  }

  // 서버가 준 access_policy 문자열 해석. 모르는/빈 값은 브랜드 기본값으로.
  static AccessPolicy _parse(String? raw) {
    switch (raw?.toLowerCase()) {
      case 'none':
        return AccessPolicy.none;
      case 'login':
        return AccessPolicy.login;
      case 'registered':
        return AccessPolicy.registered;
      default:
        return _brandDefault;
    }
  }

  static int _int(Object? v) => int.tryParse('${v ?? ''}'.trim()) ?? 0;
  static bool _bool(Object? v) {
    final s = '${v ?? ''}'.trim().toLowerCase();
    return s == 'true' || s == '1' || s == 'y' || s == 'yes';
  }

  /// 캐시에서 결과 복원(만료 무관 — fail-open 때 재사용).
  static AppPolicyResult _fromCache(SharedPreferences sp) => AppPolicyResult(
        _parse(sp.getString(_kValue)),
        denyMessage: sp.getString(_kDeny) ?? '',
        minVersionCode: sp.getInt(_kMinVer) ?? 0,
        latestVersionCode: sp.getInt(_kLatestVer) ?? 0,
        updateUrl: sp.getString(_kUpdateUrl) ?? '',
        updateMessage: sp.getString(_kUpdateMsg) ?? '',
        blocked: sp.getBool(_kBlocked) ?? false,
        blockMessage: sp.getString(_kBlockMsg) ?? '',
      );

  /// 정책 조회. 캐시가 유효하면 그대로, 실패하면 fail-open(캐시값 → 브랜드 기본).
  /// cuid 가 없어도 호출한다(강제 업데이트·원격 차단은 모든 브랜드에 적용돼야 하므로).
  static Future<AppPolicyResult> fetch(
      {int marketVersionCode = 0, String model = ''}) async {
    final sp = await SharedPreferences.getInstance();
    final now = DateTime.now().millisecondsSinceEpoch;

    // 1. 캐시 유효하면 그대로.
    final exp = sp.getInt(_kExpiry) ?? 0;
    if (now < exp && sp.getString(_kValue) != null) {
      return _fromCache(sp);
    }

    // 2. 서버 호출(타임아웃 3초). cuid 는 있으면 함께 보낸다.
    final params = <String, String>{
      'app': AppConfig.policyAppCode,
      'brand': AppConfig.certBrand,
      if (AppConfig.cuid.isNotEmpty) 'cuid': AppConfig.cuid,
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
          final minVer = _int(res['min_version_code']);
          final latestVer = _int(res['latest_version_code']);
          final updateUrl = res['update_url']?.toString() ?? '';
          final updateMsg = res['update_message']?.toString() ?? '';
          final blocked = _bool(res['blocked']);
          final blockMsg = res['block_message']?.toString() ?? '';
          final cacheSec =
              int.tryParse(res['cache_sec']?.toString() ?? '') ?? 3600;
          await sp.setString(_kValue, raw ?? AppConfig.accessPolicyDefault);
          await sp.setString(_kDeny, deny);
          await sp.setInt(_kMinVer, minVer);
          await sp.setInt(_kLatestVer, latestVer);
          await sp.setString(_kUpdateUrl, updateUrl);
          await sp.setString(_kUpdateMsg, updateMsg);
          await sp.setBool(_kBlocked, blocked);
          await sp.setString(_kBlockMsg, blockMsg);
          await sp.setInt(_kExpiry, now + cacheSec * 1000);
          return AppPolicyResult(
            _parse(raw),
            denyMessage: deny,
            minVersionCode: minVer,
            latestVersionCode: latestVer,
            updateUrl: updateUrl,
            updateMessage: updateMsg,
            blocked: blocked,
            blockMessage: blockMsg,
          );
        }
      }
    } catch (_) {}

    // 3. fail-open: 캐시값 있으면 그 값(차단/버전 포함), 없으면 브랜드 기본 + 차단 없음.
    //    서버 장애로 전체 앱이 벽돌 되지 않게 — 차단은 서버가 명시할 때만.
    if (sp.getString(_kValue) != null) return _fromCache(sp);
    return AppPolicyResult(_brandDefault);
  }
}
