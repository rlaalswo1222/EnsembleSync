import 'package:flutter/material.dart';
import 'screens/home_screen.dart';

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
      title: 'EnsembleSync',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF8B5CF6),
          brightness: Brightness.light,
        ),
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