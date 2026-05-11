import 'package:flutter/material.dart';
import '../services/api_service.dart';
import 'join_room_screen.dart';
import 'main_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const _purple = Color(0xFF8B5CF6);

  final _nicknameController = TextEditingController();
  bool _isLoading = false;
  bool get _hasNickname => _nicknameController.text.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    _nicknameController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _nicknameController.dispose();
    super.dispose();
  }

  Future<void> _onCreateRoom() async {
    if (!_hasNickname || _isLoading) return;
    setState(() => _isLoading = true);
    try {
      final result = await ApiService().createRoom(_nicknameController.text.trim());
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => MainScreen(
            nickname: _nicknameController.text.trim(),
            roomCode: result['room_code'] as String,
            roomId: result['room_id']?.toString() ?? '',
          ),
        ),
      );
    } on ApiException catch (e) {
      _showError(e.userMessage);
    } catch (_) {
      _showError('서버에 연결할 수 없습니다');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _onJoinRoom() {
    if (!_hasNickname) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => JoinRoomScreen(nickname: _nicknameController.text.trim()),
      ),
    );
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Colors.redAccent),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF3A3A3A),
      body: SafeArea(
        child: Center(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 400),
            height: MediaQuery.of(context).size.height * 0.85,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // ── 로고 ──────────────────────────────────────
                const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.music_note_rounded, color: _purple, size: 36),
                    SizedBox(width: 8),
                    Text(
                      'Ensemble',
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF1A1A2E),
                        letterSpacing: -0.5,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  '함께 음악을 만들어보세요',
                  style: TextStyle(fontSize: 14, color: Color(0xFF9CA3AF)),
                ),
                const SizedBox(height: 48),

                // ── 닉네임 입력 ────────────────────────────────
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '닉네임',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey[700],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _nicknameController,
                  maxLength: 20,
                  textInputAction: TextInputAction.done,
                  decoration: InputDecoration(
                    hintText: '이름을 입력하세요...',
                    hintStyle: const TextStyle(color: Color(0xFFBDBDBD)),
                    counterText: '',
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 14),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide:
                          const BorderSide(color: _purple, width: 1.5),
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // ── 방 만들기 버튼 ─────────────────────────────
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: FilledButton.icon(
                    onPressed:
                        _hasNickname && !_isLoading ? _onCreateRoom : null,
                    style: FilledButton.styleFrom(
                      backgroundColor: _purple,
                      disabledBackgroundColor: const Color(0xFFD1D5DB),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: _isLoading
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.add, size: 18),
                    label: Text(
                      _isLoading ? '생성 중...' : '방 만들기',
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
                const SizedBox(height: 10),

                // ── 방 참가하기 버튼 ───────────────────────────
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: OutlinedButton.icon(
                    onPressed: _hasNickname ? _onJoinRoom : null,
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(
                        color: _hasNickname
                            ? const Color(0xFFD1D5DB)
                            : const Color(0xFFE5E7EB),
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: const Icon(Icons.group_rounded,
                        size: 18, color: Color(0xFF6B7280)),
                    label: const Text(
                      '방 참가하기',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF374151),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 24),

                // ── 하단 안내 ──────────────────────────────────
                AnimatedOpacity(
                  opacity: _hasNickname ? 0.0 : 1.0,
                  duration: const Duration(milliseconds: 200),
                  child: const Text(
                    '닉네임을 입력하여 시작하세요',
                    style:
                        TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}