import 'package:flutter/material.dart';
import 'join_screen.dart';
import 'l10n.dart';

void main() {
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
    // UI 언어가 바뀌면 앱 전체를 다시 그린다(문구가 L.t로 읽히므로 갱신됨).
    return ValueListenableBuilder<String>(
      valueListenable: L.localeNotifier,
      builder: (context, _, _) {
        return MaterialApp(
          title: 'Prism Meeting',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            colorScheme: scheme,
            scaffoldBackgroundColor: const Color(0xFF0E1116),
            useMaterial3: true,
            // 안드로이드TV: D-pad 포커스가 잘 보이도록 기본 포커스 하이라이트 유지
          ),
          home: const JoinScreen(),
        );
      },
    );
  }
}
