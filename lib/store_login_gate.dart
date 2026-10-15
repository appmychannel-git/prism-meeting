import 'package:flutter/material.dart';

import 'access.dart';
import 'app_policy.dart';
import 'config.dart';
import 'mobile_auth.dart';
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
  // 서버에서 받은 실행 권한 정책(기본 login — fail-open 기본값과 동일).
  AccessPolicy _policy = AccessPolicy.login;

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

    // 서버 실행 권한 정책을 받아온다(하드코딩 대신). 마켓 버전을 함께 보내
    // 구버전 마켓(registered 없음) 기기를 서버가 login 으로 낮출 수 있게 한다.
    final mvc = await StoreLogin.marketVersionCode();
    final res = await AppPolicy.fetch(marketVersionCode: mvc);
    _policy = res.policy;

    final info = await StoreLogin.read();
    if (!mounted) return;

    // 마켓앱 없음(모바일/웹) → 자체 로그인 세션으로 티어 판정.
    if (info == null) {
      await _applyMobileSession();
      _done();
      return;
    }

    // TV 경로 — 마켓 로그아웃 변경 감지.
    if (!_observing) {
      _observing = true;
      StoreLogin.observe(_onSessionChanged);
    }

    // 정책 + 세션/인증으로 티어 결정.
    Access.set(_tierFor(loggedIn: info.isValid, registered: info.registered));
    _done();

    // 로그인 상태면 서버 검증(401 → 로그아웃 취급).
    if (info.isValid) {
      final code = await StoreLogin.verify(info.sessionToken);
      if (!mounted) return;
      if (code == 401) {
        Access.set(_tierFor(loggedIn: false, registered: false));
      }
    }
  }

  // 정책별 티어: none→full, login→세션있으면 full, registered→세션+인증이면 full.
  AccessLevel _tierFor({required bool loggedIn, required bool registered}) {
    switch (_policy) {
      case AccessPolicy.none:
        return AccessLevel.full;
      case AccessPolicy.login:
        return loggedIn ? AccessLevel.full : AccessLevel.limited;
      case AccessPolicy.registered:
        return (loggedIn && registered)
            ? AccessLevel.full
            : AccessLevel.limited;
    }
  }

  // 마켓앱 로그아웃/로그인 변경 감지 시 티어 재설정.
  Future<void> _onSessionChanged() => _refresh();

  Future<void> _refresh() async {
    if (!AppConfig.useStoreLogin) return;
    final info = await StoreLogin.read();
    if (!mounted) return;
    if (info == null) {
      await _applyMobileSession(); // 모바일: 자체 로그인 세션 재확인
    } else {
      Access.set(_tierFor(loggedIn: info.isValid, registered: info.registered));
    }
  }

  // 모바일(마켓앱 없음): viewplus 자체 로그인 세션이 있으면 me 로 티어 판정.
  Future<void> _applyMobileSession() async {
    try {
      if (_policy == AccessPolicy.none) {
        Access.set(AccessLevel.full);
        return;
      }
      if (await MobileAuth.instance.hasSession()) {
        final u = await MobileAuth.instance.me();
        if (!mounted) return;
        Access.set(
            _tierFor(loggedIn: true, registered: u?.registered ?? false));
        return;
      }
    } catch (_) {}
    Access.set(_tierFor(loggedIn: false, registered: false));
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
