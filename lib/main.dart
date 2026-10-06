import 'package:flutter/material.dart';
import 'app_settings.dart';
import 'cctv_hub_screen.dart';
import 'config.dart';
import 'device_id.dart';
import 'device_quirks.dart';
import 'join_screen.dart';
import 'l10n.dart';
import 'my_id_screen.dart';
import 'push_service.dart';
import 'store_login_gate.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await DeviceQuirks.load(); // 기기별 보정(카메라 상하반전 기기 자동 판정) — AppSettings보다 먼저
  await AppSettings.load(); // 사용자 설정(수락형 등). 반전 토글 기본값이 자동 판정값을 참조
  await L.load(); // 저장된 앱 언어 복원(없으면 기기 언어)
  // 통화/친구 기능이 켜진 모바일에서만 Firebase(FCM/Firestore) 초기화.
  // (내부에서 예외를 삼키므로 구성이 없어도 앱 실행엔 영향 없음.)
  await PushService.instance.initIfEnabled();
  runApp(const PrismMeetingApp());
}

class PrismMeetingApp extends StatelessWidget {
  const PrismMeetingApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF5B8DEF),
      brightness: Brightness.dark,
    );
    return MaterialApp(
      title: AppConfig.appBrand,
      debugShowCheckedModeBanner: false,
      // 수신 통화 등 백그라운드/알림에서 화면 전환에 사용.
      navigatorKey: appNavigatorKey,
      // 키보드 아닌 영역을 탭하면 키보드(포커스) 닫기 — 전 화면 공통.
      builder: (context, child) => GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
        child: child,
      ),
      theme: ThemeData(
        colorScheme: scheme,
        scaffoldBackgroundColor: const Color(0xFF0E1116),
        useMaterial3: true,
        // 안드로이드TV: D-pad 포커스가 잘 보이도록 기본 포커스 하이라이트 유지
      ),
      // CCTV 전용 모드면 홈을 CCTV 화면으로(회의 화면 대신).
      home: const _LocalizedHome(),
    );
  }
}

/// 홈 화면(회의/CCTV)을 앱 언어에 반응하게 감싸는 래퍼.
///
/// Navigator 초기 라우트는 한 번 만들어져 캐시되므로, MaterialApp 을 감싸는 것만으론
/// 언어를 바꿔도 홈이 다시 그려지지 않는다. 언어 리스너를 "홈 라우트 안쪽"에 두고
/// [ValueKey] 로 언어를 걸어, 언어가 바뀌면 홈을 새 언어로 다시 만들게 한다.
/// (회의 등 위에 push 된 화면은 건드리지 않아 통화가 끊기지 않는다.)
class _LocalizedHome extends StatelessWidget {
  const _LocalizedHome();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: L.localeNotifier,
      builder: (context, lang, _) => KeyedSubtree(
        key: ValueKey(lang),
        // 마켓앱 로그인 게이트(안드로이드TV). 마켓 없으면(모바일/웹) 그대로 통과.
        child: StoreLoginGate(
          // 첫 실행: 내 아이디 입력(이미 설정됐으면 바로 홈).
          child: _IdSetupGate(
            child: AppConfig.cctvOnly
                ? const CctvHubScreen()
                : const JoinScreen(),
          ),
        ),
      ),
    );
  }
}

/// 첫 실행 게이트 — 내 아이디(표시 이름)가 비어 있으면 입력 화면을 띄우고,
/// 설정돼 있으면 바로 홈([child])을 보여준다. 한 번 설정하면 다음부터 안 뜬다.
class _IdSetupGate extends StatefulWidget {
  const _IdSetupGate({required this.child});

  final Widget child;

  @override
  State<_IdSetupGate> createState() => _IdSetupGateState();
}

class _IdSetupGateState extends State<_IdSetupGate> {
  bool _loaded = false;
  bool _needSetup = false;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final name = await DeviceId.name();
    if (!mounted) return;
    setState(() {
      _needSetup = name.trim().isEmpty;
      _loaded = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Scaffold(
        backgroundColor: Color(0xFF0E1116),
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (_needSetup) {
      // 첫 실행: 기존 "내 ID" 화면(표시 이름 + QR + 내 코드)으로 아이디 설정.
      return MyIdScreen(onDone: () => setState(() => _needSetup = false));
    }
    return widget.child;
  }
}
