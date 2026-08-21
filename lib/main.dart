import 'package:flutter/material.dart';
import 'screens/home_screen.dart';
import 'theme/tokens.dart';

void main() {
  runApp(const EnsembleSyncApp());
}

class EnsembleSyncApp extends StatelessWidget {
  const EnsembleSyncApp({super.key});

  // ══════════════════════════════════════════════
  // UI 시작 — 앱 전체 테마 및 첫 화면 설정
  // ══════════════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Bandly',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        // 무채색 기반이라 씨앗 색은 검정이다. 강조색은 팔레트가 아니라
        // 규칙으로 쓴다 — AppColors.accent 주석 참고.
        colorScheme: ColorScheme.fromSeed(
          seedColor: AppColors.ink,
          primary: AppColors.ink,
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: AppColors.canvas,
        splashFactory: NoSplash.splashFactory,
        useMaterial3: true,
        fontFamily: 'Pretendard',
      ),
      home: const HomeScreen(),
    );
  }
  // ══════════════════════════════════════════════
  // UI 끝
  // ══════════════════════════════════════════════
}
