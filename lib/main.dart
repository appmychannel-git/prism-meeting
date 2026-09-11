import 'package:flutter/material.dart';
import 'app_settings.dart';
import 'cctv_hub_screen.dart';
import 'config.dart';
import 'join_screen.dart';
import 'l10n.dart';
import 'push_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppSettings.load(); // 사용자 설정(수락형 등) 로드
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
        child: AppConfig.cctvOnly
            ? const CctvHubScreen()
            : const JoinScreen(),
      ),
    );
  }
}
