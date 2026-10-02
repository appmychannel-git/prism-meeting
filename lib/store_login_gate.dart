import 'package:flutter/material.dart';

import 'config.dart';
import 'l10n.dart';
import 'store_login.dart';

/// 홈 화면 앞단의 "마켓앱 로그인 게이트"(안드로이드TV).
///
/// Phase 1 — TV 경로만 게이팅한다.
///   • 마켓앱 없음(모바일/웹)      → 기존대로 실행(차단 안 함)
///   • 마켓앱 있음 + 로그인됨        → 실행(서버 검증은 백그라운드, 401이면 차단)
///   • 마켓앱 있음 + 로그아웃/만료   → 경고 화면(마켓 로그인 유도), 실행 차단
///
/// [AppConfig.useStoreLogin]가 false이거나 안드로이드가 아니면 항상 통과한다.
class StoreLoginGate extends StatefulWidget {
  const StoreLoginGate({super.key, required this.child});

  final Widget child;

  @override
  State<StoreLoginGate> createState() => _StoreLoginGateState();
}

enum _GateStatus { loading, ok, blocked }

class _StoreLoginGateState extends State<StoreLoginGate>
    with WidgetsBindingObserver {
  _GateStatus _status = _GateStatus.loading;
  bool _observing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_observing) StoreLogin.stopObserve();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 마켓 로그인 화면에 다녀온 뒤(복귀) 차단 상태면 다시 확인한다.
    if (state == AppLifecycleState.resumed && _status == _GateStatus.blocked) {
      _check();
    }
  }

  Future<void> _check() async {
    if (!AppConfig.useStoreLogin) {
      _set(_GateStatus.ok);
      return;
    }
    _set(_GateStatus.loading);

    final info = await StoreLogin.read();
    if (!mounted) return;

    // 마켓앱 없음(또는 서명키 불일치) = 모바일 경로 → 기존대로 실행.
    if (info == null) {
      _set(_GateStatus.ok);
      return;
    }

    // 여기부터 TV 경로(마켓앱 있음).
    if (!_observing) {
      _observing = true;
      StoreLogin.observe(_onSessionChanged);
    }

    if (!info.isValid) {
      _set(_GateStatus.blocked);
      return;
    }

    // provider 토큰이 있으면 일단 실행하고, 서버 검증은 백그라운드로(네트워크 관대).
    _set(_GateStatus.ok);
    final code = await StoreLogin.verify(info.sessionToken);
    if (!mounted) return;
    if (code == 401) {
      _set(_GateStatus.blocked); // 명시적 401일 때만 차단(네트워크 오류 -1은 유지)
    }
  }

  // 마켓앱 로그아웃/로그인 변경 감지 시.
  Future<void> _onSessionChanged() async {
    final info = await StoreLogin.read();
    if (!mounted) return;
    if (info == null || !info.isValid) {
      _set(_GateStatus.blocked);
    } else {
      _set(_GateStatus.ok);
    }
  }

  void _set(_GateStatus s) {
    if (_status != s && mounted) setState(() => _status = s);
  }

  @override
  Widget build(BuildContext context) {
    switch (_status) {
      case _GateStatus.ok:
        return widget.child;
      case _GateStatus.loading:
        return const Scaffold(
          backgroundColor: Color(0xFF0E1116),
          body: Center(child: CircularProgressIndicator()),
        );
      case _GateStatus.blocked:
        return _BlockedScreen(onLogin: _openLogin, onRetry: _check);
    }
  }

  Future<void> _openLogin() async {
    final ok = await StoreLogin.openStoreLogin();
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_tr('openFail'))),
      );
    }
  }
}

/// 마켓 로그인 필요 안내 화면(실행 차단). 다국어: ko / ru / 그 외 en.
class _BlockedScreen extends StatelessWidget {
  const _BlockedScreen({required this.onLogin, required this.onRetry});

  final VoidCallback onLogin;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0E1116),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.lock_outline, size: 64, color: Colors.white70),
                const SizedBox(height: 20),
                Text(
                  _tr('title'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  _tr('body'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 15, color: Colors.white70),
                ),
                const SizedBox(height: 28),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: onLogin,
                    icon: const Icon(Icons.login),
                    label: Text(_tr('login')),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: TextButton(
                    onPressed: onRetry,
                    child: Text(_tr('retry')),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 게이트 전용 짧은 다국어 문구(l10n 키 추가 없이 로컬 처리).
String _tr(String key) {
  final lang = L.lang;
  const ko = {
    'title': '마켓앱 로그인이 필요합니다',
    'body': '이 앱을 사용하려면 마켓앱에서 먼저 로그인해 주세요.\n'
        '로그인 후 자동으로 돌아옵니다.',
    'login': '마켓 로그인 열기',
    'retry': '다시 확인',
    'openFail': '마켓앱을 열 수 없습니다. 설치 상태를 확인해 주세요.',
  };
  const ru = {
    'title': 'Требуется вход через магазин',
    'body': 'Чтобы пользоваться приложением, войдите в приложении магазина.\n'
        'После входа вы вернётесь автоматически.',
    'login': 'Открыть вход в магазин',
    'retry': 'Проверить снова',
    'openFail': 'Не удалось открыть приложение магазина.',
  };
  const en = {
    'title': 'Store sign-in required',
    'body': 'Please sign in from the store app to use this app.\n'
        "You'll return here automatically after signing in.",
    'login': 'Open store sign-in',
    'retry': 'Check again',
    'openFail': 'Could not open the store app.',
  };
  final table = lang == 'ko' ? ko : (lang == 'ru' ? ru : en);
  return table[key] ?? en[key] ?? key;
}
