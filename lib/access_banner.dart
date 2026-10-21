import 'package:flutter/material.dart';

import 'access.dart';
import 'app_gate_block.dart' show openUpdate;
import 'app_policy.dart';
import 'l10n.dart';
import 'login_screen.dart';
import 'mobile_auth.dart';
import 'store_login.dart';

/// 로그인 유도(공용). TV(마켓앱)면 마켓 로그인 화면을, 모바일/웹이면 자체 로그인 화면을
/// 연다. 성공 시 [Access] 티어가 갱신되므로 호출부가 그 뒤 조건을 다시 확인하면 된다.
Future<void> promptAccountLogin(BuildContext context) async {
  final ok = await StoreLogin.openStoreLogin(); // TV: 마켓 / 그 외: false
  if (ok || !context.mounted) return;
  await Navigator.of(context).push<bool>(
    MaterialPageRoute(builder: (_) => const LoginScreen()),
  );
}

/// 햄버거 메뉴의 계정 항목 — 자체 로그인 세션이 있으면 "로그아웃(이메일)",
/// 없으면 "로그인". (full 티어에선 배너가 숨겨지므로 로그인/로그아웃 진입점이 여기뿐)
class AccountMenuTile extends StatefulWidget {
  const AccountMenuTile({super.key});

  @override
  State<AccountMenuTile> createState() => _AccountMenuTileState();
}

class _AccountMenuTileState extends State<AccountMenuTile> {
  bool? _hasSession;
  String? _method; // 이번 로그인 경로(email/google/kakao/apple)

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final has = await MobileAuth.instance.hasSession();
    // 기록이 없으면(이전 버전에서 로그인) 계정의 가입 경로로 대신 표시.
    final m = has
        ? (await MobileAuth.instance.loginMethod() ??
            MobileAuth.instance.user?.socialProvider)
        : null;
    if (mounted) {
      setState(() {
        _hasSession = has;
        _method = m;
      });
    }
  }

  // 소셜 로그인이면 그 브랜드 배지, 아니면 기본 로그아웃 아이콘.
  Widget _leading() {
    Widget badge(Color bg, Widget child) => Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
          child: child,
        );
    switch (_method) {
      case 'kakao':
        return badge(const Color(0xFFFEE500),
            const Icon(Icons.chat_bubble, size: 15, color: Color(0xFF3C1E1E)));
      case 'google':
        return badge(
            Colors.white,
            const Text('G',
                style: TextStyle(
                    color: Color(0xFF4285F4),
                    fontSize: 16,
                    fontWeight: FontWeight.bold)));
      case 'apple':
        return badge(Colors.black,
            const Icon(Icons.apple, size: 18, color: Colors.white));
      default:
        return const Icon(Icons.logout);
    }
  }

  Future<void> _logout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(L.t('logout_confirm')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(L.t('cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(L.t('logout'))),
        ],
      ),
    );
    if (ok != true) return;
    await MobileAuth.instance.logout();
    (await AppPolicy.fetch()).apply(loggedIn: false, registered: false);
    if (mounted) Navigator.pop(context); // 드로어 닫기
  }

  // 드로어 위로 로그인 화면을 띄운다(먼저 닫으면 이 context 가 사라짐).
  Future<void> _login() async {
    await promptAccountLogin(context);
    if (mounted) Navigator.pop(context); // 드로어 닫기
  }

  @override
  Widget build(BuildContext context) {
    final has = _hasSession;
    if (has == null) return const SizedBox.shrink();
    if (has) {
      final email = MobileAuth.instance.user?.email ?? '';
      final social = _method != null && _method != 'email';
      return ListTile(
        leading: _leading(),
        title: Text(L.t('logout')),
        subtitle: email.isNotEmpty ? Text(email) : null,
        trailing: social ? const Icon(Icons.logout, size: 20) : null,
        onTap: _logout,
      );
    }
    return ListTile(
      leading: const Icon(Icons.login),
      title: Text(L.t('login')),
      onTap: _login,
    );
  }
}

/// 기기 인증(TV 시리얼 등록) 웹 페이지 — 마이페이지 > 프로필 > TV 시리얼(소셜 가입자 포함).
const String kVerifyUrl = 'https://viewplus.co.kr/my/profile';

/// 제한(limited) 티어 안내 배너.
///  - 미로그인: 화면별 문구 + [로그인] (TV=마켓 로그인, 모바일=자체 로그인 화면)
///  - 로그인했지만 기기 미인증: 서버 deny_message(없으면 기본 문구) + [다시 확인]
///    (다른 기기에서 시리얼 등록을 마친 뒤 앱을 다시 켜지 않고 바로 반영)
class AccessUpgradeBanner extends StatefulWidget {
  const AccessUpgradeBanner({super.key, required this.message});

  /// 미로그인일 때의 화면별 설명 문구(미팅/CCTV 등).
  final String message;

  @override
  State<AccessUpgradeBanner> createState() => _AccessUpgradeBannerState();
}

class _AccessUpgradeBannerState extends State<AccessUpgradeBanner> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    L.localeNotifier.addListener(_onLocale);
  }

  @override
  void dispose() {
    L.localeNotifier.removeListener(_onLocale);
    super.dispose();
  }

  // 언어를 바꾸면 서버 안내 문구도 그 언어로 다시 받는다(조용히).
  void _onLocale() => _recheck(silent: true);

  // 인증 상태 다시 읽기: TV=마켓 세션, 모바일=viewplus me.
  Future<void> _recheck({bool silent = false}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final res = await AppPolicy.fetch();
      final info = await StoreLogin.read();
      if (info != null) {
        res.apply(loggedIn: info.isValid, registered: info.registered);
      } else if (await MobileAuth.instance.hasSession()) {
        final u = await MobileAuth.instance.me();
        res.apply(loggedIn: true, registered: u?.registered ?? false);
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() => _busy = false);
    if (!silent && Access.verifyNeededListenable.value != null) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L.t('verify_still_needed'))));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String?>(
      valueListenable: Access.verifyNeededListenable,
      builder: (context, verifyMsg, _) {
        final needVerify = verifyMsg != null;
        // 인증 필요: 서버 안내 + "회의 참여는 지금도 가능"(막힌 것처럼 보이지 않게).
        // 서버 문구가 비었거나 현재 언어가 아닌 것(한국어 아닌데 한글)은 앱 문구로 대신.
        final serverOk = verifyMsg != null &&
            verifyMsg.isNotEmpty &&
            (L.lang == 'ko' || !RegExp(r'[가-힣]').hasMatch(verifyMsg));
        final verifyText =
            '${serverOk ? verifyMsg : L.t('access_need_verify')}'
            '\n${L.t('access_join_ok')}';
        return _box(
          icon: needVerify ? Icons.verified_user_outlined : Icons.lock_outline,
          text: needVerify ? verifyText : widget.message,
          action: needVerify
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    // 웹 마이페이지 > 프로필 > TV 시리얼. 돌아오면(앱 복귀) 게이트가 자동 재확인.
                    TextButton(
                      onPressed: () => openUpdate(kVerifyUrl),
                      child: Text(L.t('verify_register')),
                    ),
                    TextButton(
                      onPressed: _busy ? null : () => _recheck(),
                      style: TextButton.styleFrom(
                          foregroundColor: Colors.white54,
                          visualDensity: VisualDensity.compact),
                      child: _busy
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : Text(L.t('verify_recheck'),
                              style: const TextStyle(fontSize: 12)),
                    ),
                  ],
                )
              : TextButton(
                  onPressed: () => promptAccountLogin(context),
                  child: Text(L.t('login')),
                ),
        );
      },
    );
  }

  Widget _box(
      {required IconData icon, required String text, required Widget action}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: const Color(0xFF5B8DEF).withValues(alpha: 0.45)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: const Color(0xFF5B8DEF)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text,
                style: const TextStyle(fontSize: 12, color: Colors.white70)),
          ),
          const SizedBox(width: 4),
          action,
        ],
      ),
    );
  }
}
