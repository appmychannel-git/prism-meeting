import 'package:flutter/material.dart';

import 'access.dart';
import 'config.dart';
import 'store_login.dart';

/// 홈 화면 앞단의 "로그인/권한 게이트".
///
/// Phase 1 — **차단하지 않는다.** 로그인·기기시리얼 인증(registered) 여부를 읽어
/// [Access] 티어만 정하고 항상 홈([child])을 띄운다. 제한 티어에서도 방 참여·CCTV
/// 시청은 가능하고, 방 생성·친구·통화·CCTV 송출만 막힌다(UI에서 [Access]로 게이트).
///
///   • 마켓앱 없음(모바일/웹)        → limited (Phase 2에서 자체 로그인으로 full 가능)
///   • 마켓앱 있음 + 로그아웃/만료     → limited
///   • 마켓앱 있음 + 로그인 + 인증O    → full
///   • 마켓앱 있음 + 로그인 + 인증X    → limited
///
/// [AppConfig.useStoreLogin]가 false면 게이팅 없이 full.
class StoreLoginGate extends StatefulWidget {
  const StoreLoginGate({super.key, required this.child});

  final Widget child;

  @override
  State<StoreLoginGate> createState() => _StoreLoginGateState();
}

class _StoreLoginGateState extends State<StoreLoginGate>
    with WidgetsBindingObserver {
  bool _loaded = false; // 최초 티어 판정 완료 여부(짧은 스플래시 1회)
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
    // 마켓 로그인/시리얼 등록을 하고 돌아오면 티어가 올라갈 수 있다 → 조용히 재판정.
    if (state == AppLifecycleState.resumed && _loaded) _refresh();
  }

  Future<void> _check() async {
    if (!AppConfig.useStoreLogin) {
      Access.set(AccessLevel.full); // 계정 게이팅 미사용 빌드 → 전체 허용
      _done();
      return;
    }

    final info = await StoreLogin.read();
    if (!mounted) return;

    // 마켓앱 없음(모바일/웹) → 제한 티어로 실행(Phase 2: 자체 로그인).
    if (info == null) {
      Access.set(AccessLevel.limited);
      _done();
      return;
    }

    // TV 경로 — 마켓 로그아웃 변경 감지.
    if (!_observing) {
      _observing = true;
      StoreLogin.observe(_onSessionChanged);
    }

    if (!info.isValid) {
      Access.set(AccessLevel.limited); // 로그아웃(차단하지 않음)
      _done();
      return;
    }

    // 로그인됨 → 시리얼 인증(registered)이면 full, 아니면 limited.
    Access.set(info.registered ? AccessLevel.full : AccessLevel.limited);
    _done();

    // 서버 검증은 백그라운드(네트워크 관대). 명시적 401이면 로그아웃 취급 → 제한.
    final code = await StoreLogin.verify(info.sessionToken);
    if (!mounted) return;
    if (code == 401) Access.set(AccessLevel.limited);
  }

  // 마켓앱 로그아웃/로그인 변경 감지 시 티어 재설정.
  Future<void> _onSessionChanged() => _refresh();

  Future<void> _refresh() async {
    if (!AppConfig.useStoreLogin) return;
    final info = await StoreLogin.read();
    if (!mounted) return;
    if (info == null || !info.isValid) {
      Access.set(AccessLevel.limited);
    } else {
      Access.set(info.registered ? AccessLevel.full : AccessLevel.limited);
    }
  }

  void _done() {
    if (!_loaded && mounted) setState(() => _loaded = true);
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Scaffold(
        backgroundColor: Color(0xFF0E1116),
        body: Center(child: CircularProgressIndicator()),
      );
    }
    return widget.child;
  }
}
