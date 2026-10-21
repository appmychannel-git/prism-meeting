import 'package:flutter/material.dart';

import 'access.dart';
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
    final policy = (await AppPolicy.fetch()).policy;
    Access.set(policy.tierFor(loggedIn: false, registered: false));
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

/// 제한(limited) 티어 안내 배너 — "로그인·기기 인증하면 전체 기능".
/// TV(마켓앱)는 마켓 로그인 화면을 열고, 모바일은 자체 로그인 화면을 연다.
class AccessUpgradeBanner extends StatelessWidget {
  const AccessUpgradeBanner({super.key, required this.message});

  /// 화면별 설명 문구(미팅/CCTV 등).
  final String message;

  Future<void> _login(BuildContext context) => promptAccountLogin(context);

  @override
  Widget build(BuildContext context) {
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
          const Icon(Icons.lock_outline, size: 18, color: Color(0xFF5B8DEF)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(message,
                style: const TextStyle(fontSize: 12, color: Colors.white70)),
          ),
          const SizedBox(width: 4),
          TextButton(
            onPressed: () => _login(context),
            child: Text(L.t('login')),
          ),
        ],
      ),
    );
  }
}
