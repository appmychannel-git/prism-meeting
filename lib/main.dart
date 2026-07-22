import 'package:flutter/material.dart';
import 'join_screen.dart';

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
  }
}
