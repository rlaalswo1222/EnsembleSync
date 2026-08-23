import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'screens/home_screen.dart';
import 'theme/tokens.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // 세로로만 쓴다.
  //
  // 가로를 지원하려면 화면마다 배치를 따로 짜야 하는데, 악보 한 장을
  // 온전히 보는 것이 이 앱의 중심이라 가로가 주는 이점이 크지 않다.
  // 어중간하게 열어두면 세로 공간이 모자라 배치가 무너진다.
  //
  // 태블릿은 세로로도 넓으므로 넓은 화면 배치는 그대로 살아 있다.
  SystemChrome.setPreferredOrientations(<DeviceOrientation>[
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
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
