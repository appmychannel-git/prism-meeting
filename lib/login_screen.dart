import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import 'access.dart';
import 'app_policy.dart';
import 'config.dart';
import 'l10n.dart';
import 'mobile_auth.dart';
import 'supported_devices.dart';

/// 모바일 자체 로그인 화면(viewplus 계정) — 이메일 + 구글 + 카카오.
/// 로그인 성공 시 계정의 기기시리얼 인증(registered)에 따라 [Access] 티어를 갱신하고
/// `true` 로 pop 한다. (회원가입/비번찾기는 웹 viewplus.co.kr)
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailCtrl = TextEditingController();
  final _pwCtrl = TextEditingController();
  bool _busy = false;
  // 구글: iOS 는 GIDClientID 설정 전까지 숨긴다(미설정 시 네이티브 크래시). 확인 전 기본 숨김.
  bool _googleReady = !(!kIsWeb && Platform.isIOS);

  @override
  void initState() {
    super.initState();
    if (!kIsWeb && Platform.isIOS) {
      MobileAuth.isGoogleAvailable().then((ok) {
        if (mounted) setState(() => _googleReady = ok);
      });
    }
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _pwCtrl.dispose();
    super.dispose();
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  // 로그인 성공 처리 — 최신 정보(me)로 티어 반영 후 닫기.
  Future<void> _onSuccess() async {
    // registered 는 로그인 응답에 없을 수 있어 me 로 한 번 더 확인.
    final u = await MobileAuth.instance.me() ?? MobileAuth.instance.user;
    // 티어는 서버 정책 기준(미팅=login 이면 시리얼 미인증이어도 full). 게이트와 같은 규칙.
    (await AppPolicy.fetch())
        .apply(loggedIn: true, registered: u?.registered ?? false);
    if (!mounted) return;
    if (Access.isLimited) {
      _snack(L.t('login_ok_unverified'));
    }
    Navigator.of(context).pop(true);
  }

  // 서버 오류 문구: 비었거나 현재 언어가 아니면(한국어 아닌데 한글) 앱 문구로 대신.
  String _srv(String? m, String fallbackKey) =>
      (m != null && m.isNotEmpty && (L.lang == 'ko' || !RegExp(r'[가-힣]').hasMatch(m)))
          ? m
          : L.t(fallbackKey);

  Future<void> _handle(Future<VpAuthResult> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    final r = await action();
    if (!mounted) return;
    setState(() => _busy = false);
    switch (r.status) {
      case VpAuthStatus.success:
        await _onSuccess();
        break;
      case VpAuthStatus.needsOnboarding:
        await _onboarding(r.onboardingEmail ?? '');
        break;
      case VpAuthStatus.cancelled:
        break; // 조용히
      case VpAuthStatus.wrongCredential:
        _snack(L.t('login_err_credential'));
        break;
      case VpAuthStatus.forbidden:
        _snack(_srv(r.message, 'login_err_forbidden'));
        break;
      case VpAuthStatus.rateLimited:
        _snack(_srv(r.message, 'login_err_rate'));
        break;
      case VpAuthStatus.networkError:
        _snack(L.t('login_err_network'));
        break;
      case VpAuthStatus.error:
        _snack(_srv(r.message, 'login_err_generic'));
        break;
    }
  }

  Future<void> _emailLogin() async {
    final email = _emailCtrl.text.trim();
    final pw = _pwCtrl.text;
    if (email.isEmpty || pw.isEmpty) {
      _snack(L.t('login_enter_both'));
      return;
    }
    await _handle(() => MobileAuth.instance.loginEmail(email, pw));
  }

  // 소셜 최초 가입 → 약관 동의 후 온보딩 완료.
  Future<void> _onboarding(String email) async {
    final name = MobileAuth.instance.user?.name ?? '';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L.t('onboarding_title')),
        content: Text(L.t('onboarding_body')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(L.t('cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(L.t('onboarding_agree'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    final r = await MobileAuth.instance.completeOnboarding(email, name);
    if (!mounted) return;
    setState(() => _busy = false);
    if (r.status == VpAuthStatus.success) {
      await _onSuccess();
    } else {
      _snack(_srv(r.message, 'login_err_generic'));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0E1116),
      appBar: AppBar(title: Text(AppConfig.appBrand)),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.account_circle_outlined,
                      size: 56, color: Color(0xFF5B8DEF)),
                  const SizedBox(height: 16),
                  Text(L.t('login_title'),
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 20),
                  TextField(
                    controller: _emailCtrl,
                    keyboardType: TextInputType.emailAddress,
                    textInputAction: TextInputAction.next,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                      labelText: L.t('login_email'),
                      prefixIcon: const Icon(Icons.mail_outline),
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _pwCtrl,
                    obscureText: true,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _emailLogin(),
                    decoration: InputDecoration(
                      labelText: L.t('login_password'),
                      prefixIcon: const Icon(Icons.lock_outline),
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _busy ? null : _emailLogin,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(L.t('login')),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Row(children: [
                    const Expanded(child: Divider()),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Text(L.t('login_or'),
                          style: const TextStyle(color: Colors.white54)),
                    ),
                    const Expanded(child: Divider()),
                  ]),
                  const SizedBox(height: 16),
                  // 애플(iOS 전용) — App Store 가이드라인 4.8: 소셜로그인 제공 시 필수.
                  // 애플 권장상 다른 소셜과 최소 동등하게 노출 → 맨 위에 공식 버튼.
                  if (!kIsWeb && Platform.isIOS) ...[
                    SignInWithAppleButton(
                      onPressed: _busy
                          ? () {}
                          : () => _handle(() => MobileAuth.instance.loginApple()),
                      style: SignInWithAppleButtonStyle.black,
                      height: 48,
                    ),
                    const SizedBox(height: 10),
                  ],
                  // 구글 (iOS 는 GIDClientID 설정 완료 후에만 노출)
                  if (_googleReady) ...[
                    OutlinedButton.icon(
                      onPressed: _busy
                          ? null
                          : () => _handle(() => MobileAuth.instance.loginGoogle()),
                      icon: const Icon(Icons.g_mobiledata, size: 28),
                      label: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Text(L.t('login_google')),
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],
                  // 카카오
                  OutlinedButton.icon(
                    onPressed: _busy
                        ? null
                        : () => _handle(() => MobileAuth.instance.loginKakao()),
                    icon: const Icon(Icons.chat_bubble, size: 20),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF3C1E1E),
                      backgroundColor: const Color(0xFFFEE500),
                    ),
                    label: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Text(L.t('login_kakao')),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(L.t('login_signup_notice'),
                      textAlign: TextAlign.center,
                      style:
                          const TextStyle(fontSize: 12, color: Colors.white54)),
                  if (_busy) ...[
                    const SizedBox(height: 20),
                    const Center(child: CircularProgressIndicator()),
                  ],
                  // CS 진단: 로그인에서 막힌 사용자도 기기정보에 닿아야 한다(가이드 §4).
                  const SizedBox(height: 24),
                  const Center(child: VersionBadge()),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
