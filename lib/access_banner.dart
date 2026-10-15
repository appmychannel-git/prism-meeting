import 'package:flutter/material.dart';

import 'l10n.dart';
import 'login_screen.dart';
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
