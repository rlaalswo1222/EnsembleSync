import 'package:flutter/material.dart';
import 'screens/home_screen.dart';

void main() {
  runApp(const EnsembleSyncApp());
}

class EnsembleSyncApp extends StatelessWidget {
  const EnsembleSyncApp({super.key});

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
}