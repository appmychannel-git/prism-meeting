import 'dart:async';

import 'package:flutter/material.dart';
import 'app_settings.dart';
import 'cctv_hub_screen.dart';
import 'cctv_setup_screen.dart';
import 'cctv_store.dart';
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
    // 앱 시작 시 스플래시를 ~4초 유지(언어 변경 재빌드에는 다시 안 뜸).
    return _SplashGate(
      child: ValueListenableBuilder<String>(
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
      ),
    );
  }
}

/// 앱 시작 스플래시 — 약 4초 유지 후 [child](홈/게이트)로 전환.
/// 우측 상단에 버전 정보를 표시한다. (언어 변경 등 내부 재빌드에는 다시 뜨지 않도록
/// 홈 라우트 바로 안쪽, 언어 리스너 바깥에 둔다.)
class _SplashGate extends StatefulWidget {
  const _SplashGate({required this.child});

  final Widget child;

  @override
  State<_SplashGate> createState() => _SplashGateState();
}

class _SplashGateState extends State<_SplashGate> {
  bool _done = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _done = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 가로(TV)이고 브랜드 전용 이미지가 있을 때만 4초 브랜드 스플래시를 띄운다.
    // 모바일(세로)은 가로형 이미지가 잘리므로 Flutter 스플래시를 생략하고
    // OS 네이티브 스플래시만 쓴다. 전용 이미지가 없는 브랜드(prism)도 네이티브만.
    final useSplash = AppConfig.splashImage.isNotEmpty &&
        MediaQuery.of(context).orientation == Orientation.landscape;
    if (_done || !useSplash) return widget.child;
    return const _SplashScreen();
  }
}

/// 스플래시 화면 — 가로(TV)에서 브랜드 전용 이미지(`assets/splash/<brand>`)를
/// 꽉 채워 보여준다(네이티브 스플래시와 동일한 브랜드 화면). 우측 상단에 버전 표시.
/// (모바일 세로·전용 이미지 없는 브랜드는 [_SplashGate]에서 이 화면을 아예 띄우지
///  않고 네이티브 스플래시만 쓴다.)
class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  /// 'FEEE19' 같은 6자리 hex → Color. 실패/빈 값이면 검정.
  Color _bgColor() {
    final hex = AppConfig.splashBg.trim();
    if (hex.length == 6) {
      final v = int.tryParse(hex, radix: 16);
      if (v != null) return Color(0xFF000000 | v);
    }
    return Colors.black;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgColor(),
      body: Stack(
        children: [
          // 브랜드 이미지 — 화면을 꽉 채운다(가로 TV 기준).
          Positioned.fill(
            child: Image.asset(
              'assets/splash/${AppConfig.splashImage}',
              fit: BoxFit.cover,
              // 에셋 누락 등 로드 실패 시 배경색만.
              errorBuilder: (context, error, stack) => const SizedBox.shrink(),
            ),
          ),
          // 우측 상단 버전 정보 — 어떤 배경에서도 보이도록 반투명 어두운 칩.
          Positioned(
            top: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    'v${AppConfig.appVersion}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
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
    var need = name.trim().isEmpty;
    // CCTV 전용 앱: 이름뿐 아니라 기본 공유 비번(기본 그룹)도 있어야 설정 완료로 본다.
    if (AppConfig.cctvOnly && !need) {
      final groups = await CctvStore.shareGroups();
      if (groups.isEmpty) need = true;
    }
    if (!mounted) return;
    setState(() {
      _needSetup = need;
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
      // CCTV 전용 앱: 이름 + 기본 공유 비번 설정 화면.
      // 그 외(미팅): 기존 "내 ID" 화면(표시 이름 + QR + 내 코드).
      return AppConfig.cctvOnly
          ? CctvSetupScreen(onDone: () => setState(() => _needSetup = false))
          : MyIdScreen(onDone: () => setState(() => _needSetup = false));
    }
    return widget.child;
  }
}
