import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import 'l10n.dart';

/// 뷰플러스 계정 사용자(모바일 로그인). TV 마켓 세션과 구분되는 "모바일 경로".
class VpUser {
  final String id; // u_...
  final String userId; // 로그인 아이디(=이메일)
  final String name;
  final String email;
  final String? socialProvider; // null=이메일 가입
  final bool registered; // 계정에 등록된 TV 시리얼 유무(기기시리얼 인증)

  const VpUser({
    required this.id,
    required this.userId,
    required this.name,
    required this.email,
    this.socialProvider,
    this.registered = false,
  });

  factory VpUser.fromJson(Map<String, dynamic> j) {
    // registration.registered 는 응답에 포함될 수 있다(계정 단위 시리얼 등록 여부).
    // 응답 형태가 문서에 고정돼 있지 않아 여러 자리를 본다:
    //  registration.registered(tv/pair 와 같은 형식) · registered · tvSerial(프로필 시리얼).
    // 프로필 시리얼은 서버가 형식·발급목록 검사 후에만 저장하므로 있으면 인증으로 본다.
    bool reg = false;
    final r = j['registration'];
    if (r is Map && r['registered'] == true) reg = true;
    if (j['registered'] == true) reg = true;
    if ((j['tvSerial']?.toString() ?? '').trim().isNotEmpty) reg = true;
    return VpUser(
      id: (j['id'] ?? '').toString(),
      userId: (j['userId'] ?? '').toString(),
      name: (j['name'] ?? '').toString(),
      email: (j['email'] ?? '').toString(),
      socialProvider: j['socialProvider']?.toString(),
      registered: reg,
    );
  }
}

/// 로그인 결과.
enum VpAuthStatus {
  success, // 로그인 완료
  needsOnboarding, // 소셜 최초 가입 → 약관 동의 필요
  cancelled, // 사용자 취소(구글/카카오)
  wrongCredential, // 401 이메일/비번
  forbidden, // 403 정지
  rateLimited, // 429
  networkError, // 네트워크
  error, // 기타
}

class VpAuthResult {
  final VpAuthStatus status;
  final VpUser? user;
  final String? message; // 서버/오류 메시지(표시용)
  final String? onboardingEmail; // needsOnboarding 시 이메일 입력 참조
  const VpAuthResult(this.status, {this.user, this.message, this.onboardingEmail});
}

/// 뷰플러스 모바일 자체 로그인 — 이메일 + 구글(id_token) + 카카오(access_token).
///
/// accessToken 은 메모리(15분), refreshToken 은 보안저장(14일, 회전).
/// 구글은 google_sign_in 플러그인, 카카오는 네이티브 MethodChannel('app/kakao').
/// viewplus API 는 Dart http 로 직접 호출(base https://viewplus.co.kr/).
class MobileAuth {
  MobileAuth._();
  static final MobileAuth instance = MobileAuth._();

  static const String _base = 'https://viewplus.co.kr';
  static const String _termsVersion = '2026-05-01';
  static const String _privacyVersion = '2026-05-01';
  // 구글 서버 웹 클라이언트 ID(앱/서버 공용 — 서버가 id_token 의 aud 를 이 값과 대조).
  static const String _googleWebClientId =
      '800914840538-k4ovs9na1rg7patpc2q85qk81dnagevv.apps.googleusercontent.com';

  static const _kRefresh = 'vp_refresh_token';
  // 이번 세션에 로그인한 경로(email/google/kakao/apple) — 메뉴 아이콘 표시용.
  static const _kMethod = 'vp_login_method';
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static const _kakaoCh = MethodChannel('app/kakao');

  String? _accessToken; // 메모리에만
  VpUser? _user;
  final _refreshLock = _Mutex();

  VpUser? get user => _user;

  /// 저장된 refreshToken 이 있으면 "로그인된 세션"으로 본다(부팅 게이트용).
  Future<bool> hasSession() async {
    try {
      return (await _storage.read(key: _kRefresh))?.isNotEmpty ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<String?> _readRefresh() async {
    try {
      return await _storage.read(key: _kRefresh);
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveTokens(Map<String, dynamic> data) async {
    _accessToken = (data['accessToken'] ?? '').toString();
    final rt = (data['refreshToken'] ?? '').toString();
    if (rt.isNotEmpty) {
      try {
        await _storage.write(key: _kRefresh, value: rt);
      } catch (_) {}
    }
    final u = data['user'];
    if (u is Map) _user = VpUser.fromJson(u.cast<String, dynamic>());
  }

  Future<void> _clear() async {
    _accessToken = null;
    _user = null;
    try {
      await _storage.delete(key: _kRefresh);
      await _storage.delete(key: _kMethod);
    } catch (_) {}
  }

  /// 현재 세션의 로그인 경로(email/google/kakao/apple). 없으면 null.
  Future<String?> loginMethod() async {
    try {
      return await _storage.read(key: _kMethod);
    } catch (_) {
      return null;
    }
  }

  String get _lang => L.lang.isNotEmpty ? L.lang : 'ko';

  // ── 이메일 로그인 ──
  Future<VpAuthResult> loginEmail(String email, String password) async {
    return _authPost('api/mobile/auth/login',
        {'userId': email.trim(), 'password': password});
  }

  // ── 구글 로그인 ──
  Future<VpAuthResult> loginGoogle() async {
    String? idToken;
    try {
      final gsi = GoogleSignIn(
        serverClientId: _googleWebClientId,
        scopes: const ['email'],
      );
      await gsi.signOut(); // 계정 선택 보장(이전 세션 캐시 방지)
      final acc = await gsi.signIn();
      if (acc == null) return const VpAuthResult(VpAuthStatus.cancelled);
      final auth = await acc.authentication;
      idToken = auth.idToken;
    } catch (e) {
      return VpAuthResult(VpAuthStatus.error, message: e.toString());
    }
    if (idToken == null || idToken.isEmpty) {
      return const VpAuthResult(VpAuthStatus.error);
    }
    return _authPost('api/mobile/auth/social/google',
        {'providerToken': idToken, 'language': _lang},
        social: true);
  }

  // ── 카카오 로그인(네이티브 MethodChannel 이 access_token 반환) ──
  Future<VpAuthResult> loginKakao() async {
    String? accessToken;
    try {
      accessToken = await _kakaoCh.invokeMethod<String>('login');
    } on PlatformException catch (e) {
      if (e.code == 'cancelled') return const VpAuthResult(VpAuthStatus.cancelled);
      return VpAuthResult(VpAuthStatus.error, message: e.message);
    } catch (e) {
      return VpAuthResult(VpAuthStatus.error, message: e.toString());
    }
    if (accessToken == null || accessToken.isEmpty) {
      return const VpAuthResult(VpAuthStatus.cancelled);
    }
    return _authPost('api/mobile/auth/social/kakao',
        {'providerToken': accessToken, 'language': _lang},
        social: true);
  }

  // ── 애플 로그인(iOS, App Store 가이드라인 4.8 필수) ──
  // sign_in_with_apple 로 identity token(JWT) + 최초 1회 이름을 받아 서버로 전송.
  // 서버(viewplus)가 identityToken 을 Apple 공개키로 검증한다.
  Future<VpAuthResult> loginApple() async {
    AuthorizationCredentialAppleID cred;
    try {
      cred = await SignInWithApple.getAppleIDCredential(
        scopes: const [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
      );
    } on SignInWithAppleAuthorizationException catch (e) {
      if (e.code == AuthorizationErrorCode.canceled) {
        return const VpAuthResult(VpAuthStatus.cancelled);
      }
      return VpAuthResult(VpAuthStatus.error, message: e.message);
    } catch (e) {
      return VpAuthResult(VpAuthStatus.error, message: e.toString());
    }
    final idToken = cred.identityToken;
    if (idToken == null || idToken.isEmpty) {
      return const VpAuthResult(VpAuthStatus.error);
    }
    // 이름은 애플이 "최초 동의 시 1회만" 준다 → 있으면 함께 보낸다.
    final name = [cred.givenName, cred.familyName]
        .where((s) => (s ?? '').isNotEmpty)
        .join(' ')
        .trim();
    return _authPost('api/mobile/auth/social/apple', {
      'providerToken': idToken,
      if (cred.authorizationCode.isNotEmpty) 'authorizationCode': cred.authorizationCode,
      if (name.isNotEmpty) 'name': name,
      if ((cred.email ?? '').isNotEmpty) 'email': cred.email,
      'language': _lang,
    }, social: true);
  }

  // 로그인/소셜 공통 POST → 토큰 저장 + 결과 매핑.
  Future<VpAuthResult> _authPost(String path, Map<String, dynamic> body,
      {bool social = false}) async {
    http.Response resp;
    try {
      resp = await http
          .post(Uri.parse('$_base/$path'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode(body))
          .timeout(const Duration(seconds: 15));
    } catch (_) {
      return const VpAuthResult(VpAuthStatus.networkError);
    }
    Map<String, dynamic> env;
    try {
      env = jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (_) {
      env = {};
    }
    final data = env['data'];
    final msg = (env['error'] is Map) ? env['error']['message']?.toString() : null;

    if (resp.statusCode == 200 && data is Map) {
      final d = data.cast<String, dynamic>();
      await _saveTokens(d);
      // 로그인 경로 기록: .../social/<provider> 또는 이메일.
      final method = social ? path.split('/').last : 'email';
      try {
        await _storage.write(key: _kMethod, value: method);
      } catch (_) {}
      if (social && d['needsOnboarding'] == true) {
        final email = (_user?.email ?? '');
        return VpAuthResult(VpAuthStatus.needsOnboarding,
            user: _user, onboardingEmail: email);
      }
      return VpAuthResult(VpAuthStatus.success, user: _user);
    }
    switch (resp.statusCode) {
      case 401:
        return VpAuthResult(VpAuthStatus.wrongCredential, message: msg);
      case 403:
        return VpAuthResult(VpAuthStatus.forbidden, message: msg);
      case 429:
        return VpAuthResult(VpAuthStatus.rateLimited, message: msg);
      default:
        return VpAuthResult(VpAuthStatus.error, message: msg);
    }
  }

  // ── 온보딩(소셜 신규 약관 동의) ──
  Future<VpAuthResult> completeOnboarding(String email, String name) async {
    final r = await _authedRequest(
      'POST',
      'api/mobile/me/onboarding',
      body: {
        'email': email,
        'name': name,
        'agreements': {
          'termsVersion': _termsVersion,
          'privacyVersion': _privacyVersion,
        },
        'marketingOptIn': false,
      },
    );
    if (r == null) return const VpAuthResult(VpAuthStatus.networkError);
    if (r.statusCode == 200) {
      final d = _data(r);
      if (d is Map) _user = VpUser.fromJson(d.cast<String, dynamic>());
      return VpAuthResult(VpAuthStatus.success, user: _user);
    }
    return VpAuthResult(VpAuthStatus.error, message: _errMsg(r));
  }

  // ── 내 정보(시리얼 인증 여부 포함) ──
  Future<VpUser?> me() async {
    final r = await _authedRequest('GET', 'api/mobile/me');
    if (r == null || r.statusCode != 200) return null;
    final d = _data(r);
    if (d is Map) {
      // me 응답엔 registration 이 없고 tvSerial 만 온다(2026-10-21 실측) → fromJson 참고.
      _user = VpUser.fromJson(d.cast<String, dynamic>());
      return _user;
    }
    return null;
  }

  // ── 로그아웃 ──
  Future<void> logout() async {
    try {
      await _authedRequest('POST', 'api/mobile/auth/logout');
    } catch (_) {}
    await _clear();
  }

  // ── 토큰 갱신(단일 수행) ──
  Future<bool> refresh() async {
    return _refreshLock.run(() async {
      final rt = await _readRefresh();
      if (rt == null || rt.isEmpty) return false;
      http.Response resp;
      try {
        resp = await http
            .post(Uri.parse('$_base/api/mobile/auth/refresh'),
                headers: {'Content-Type': 'application/json'},
                body: jsonEncode({'refreshToken': rt}))
            .timeout(const Duration(seconds: 15));
      } catch (_) {
        return false;
      }
      if (resp.statusCode == 200) {
        try {
          final env = jsonDecode(resp.body) as Map<String, dynamic>;
          final d = env['data'];
          if (d is Map &&
              (d['accessToken']?.toString().isNotEmpty ?? false) &&
              (d['refreshToken']?.toString().isNotEmpty ?? false)) {
            await _saveTokens(d.cast<String, dynamic>());
            return true;
          }
        } catch (_) {}
        return false;
      }
      if (resp.statusCode == 401) await _clear(); // 재사용 탐지/만료 → 로그아웃
      return false;
    });
  }

  // 인증 필요한 호출: Bearer 첨부 → 401이면 refresh 1회 후 재시도.
  Future<http.Response?> _authedRequest(String method, String path,
      {Map<String, dynamic>? body}) async {
    Future<http.Response> send() {
      final uri = Uri.parse('$_base/$path');
      final headers = <String, String>{
        if (_accessToken != null && _accessToken!.isNotEmpty)
          'Authorization': 'Bearer $_accessToken',
        if (body != null) 'Content-Type': 'application/json',
      };
      final b = body != null ? jsonEncode(body) : null;
      final f = (method == 'POST')
          ? http.post(uri, headers: headers, body: b)
          : http.get(uri, headers: headers);
      return f.timeout(const Duration(seconds: 15));
    }

    http.Response resp;
    try {
      // accessToken 이 없으면 먼저 refresh 로 확보 시도.
      if (_accessToken == null || _accessToken!.isEmpty) {
        await refresh();
      }
      resp = await send();
      if (resp.statusCode == 401) {
        if (await refresh()) resp = await send();
      }
    } catch (_) {
      return null;
    }
    return resp;
  }

  dynamic _data(http.Response r) {
    try {
      return (jsonDecode(r.body) as Map<String, dynamic>)['data'];
    } catch (_) {
      return null;
    }
  }

  String? _errMsg(http.Response r) {
    try {
      final e = (jsonDecode(r.body) as Map<String, dynamic>)['error'];
      return (e is Map) ? e['message']?.toString() : null;
    } catch (_) {
      return null;
    }
  }
}

/// 간단한 async 뮤텍스(단일 refresh 보장).
class _Mutex {
  Future<void> _last = Future.value();
  Future<T> run<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    final prev = _last;
    _last = completer.future.then((_) {}, onError: (_) {});
    prev.then((_) async {
      try {
        completer.complete(await action());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }
}
