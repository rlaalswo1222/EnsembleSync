import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/api_service.dart';
import 'main_screen.dart';

class JoinRoomScreen extends StatefulWidget {
  final String nickname;
  const JoinRoomScreen({super.key, required this.nickname});

  @override
  State<JoinRoomScreen> createState() => _JoinRoomScreenState();
}

class _JoinRoomScreenState extends State<JoinRoomScreen> {
  static const _purple = Color(0xFF8B5CF6);

  final _codeController = TextEditingController();
  final _focusNode = FocusNode();
  bool _isLoading = false;

  bool get _isComplete => _codeController.text.length == 6;

  @override
  void initState() {
    super.initState();
    _codeController.addListener(() => setState(() {}));
    _focusNode.addListener(() => setState(() {}));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _codeController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _onJoin() async {
    if (!_isComplete || _isLoading) return;
    setState(() => _isLoading = true);
    try {
      final result = await ApiService().joinRoom(
        _codeController.text.toUpperCase(),
        widget.nickname,
      );
      if (!mounted) return;
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(
          builder: (_) => MainScreen(
            nickname: widget.nickname,
            roomCode: result['room_code'] as String,
            roomId: result['room_id']?.toString() ?? '',
          ),
        ),
        (route) => false,
      );
    } on ApiException catch (e) {
      _showError(e.userMessage);
    } catch (_) {
      _showError('서버에 연결할 수 없습니다');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
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
            child: Column(
              children: [
                // ── AppBar ──────────────────────────────────────
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.chevron_left_rounded, size: 28),
                        onPressed: () => Navigator.pop(context),
                      ),
                      const Text(
                        '방 참가하기',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF1A1A2E),
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1, color: Color(0xFFF3F4F6)),

                // ── 본문 ────────────────────────────────────────
                Expanded(
                  child: GestureDetector(
                    onTap: () => _focusNode.requestFocus(),
                    behavior: HitTestBehavior.opaque,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 28),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Text(
                            '방 코드를 입력하세요',
                            style: TextStyle(
                              fontSize: 14,
                              color: Color(0xFF6B7280),
                            ),
                          ),
                          const SizedBox(height: 16),

                          // ── 6칸 코드 입력 ──────────────────────
                          _SixDigitInput(
                            controller: _codeController,
                            focusNode: _focusNode,
                            onSubmit: _onJoin,
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            '6자리 코드',
                            style: TextStyle(
                              fontSize: 12,
                              color: Color(0xFF9CA3AF),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

                // ── 입장하기 버튼 ────────────────────────────────
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                  child: SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: FilledButton(
                      onPressed: _isComplete && !_isLoading ? _onJoin : null,
                      style: FilledButton.styleFrom(
                        backgroundColor: _purple,
                        disabledBackgroundColor: const Color(0xFFD1D5DB),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: _isLoading
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : const Text(
                              '입장하기',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                    ),
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

// ── 6자리 입력 위젯 ─────────────────────────────────────────────
// 비어있으면 '0' (회색), 입력하면 해당 문자 (검정)로 교체
class _SixDigitInput extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onSubmit;

  const _SixDigitInput({
    required this.controller,
    required this.focusNode,
    required this.onSubmit,
  });

  static const _purple = Color(0xFF8B5CF6);

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        // 실제 TextField (투명 — 입력만 받음)
        Opacity(
          opacity: 0,
          child: TextField(
            controller: controller,
            focusNode: focusNode,
            maxLength: 6,
            keyboardType: TextInputType.text,
            textCapitalization: TextCapitalization.characters,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z0-9]')),
              TextInputFormatter.withFunction((old, val) =>
                  val.copyWith(text: val.text.toUpperCase())),
            ],
            onSubmitted: (_) => onSubmit(),
            decoration: const InputDecoration(counterText: ''),
          ),
        ),

        // 시각적 표시 (6칸)
        GestureDetector(
          onTap: () => focusNode.requestFocus(),
          child: AnimatedBuilder(
            animation: controller,
            builder: (_, __) {
              final typed = controller.text;
              final isFocused = focusNode.hasFocus;

              return Container(
                width: double.infinity,
                height: 64,
                decoration: BoxDecoration(
                  border: Border.all(
                    color: isFocused ? _purple : const Color(0xFFD1D5DB),
                    width: isFocused ? 1.5 : 1.0,
                  ),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: List.generate(6, (i) {
                    final hasChar = i < typed.length;
                    return Text(
                      hasChar ? typed[i] : '0',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w500,
                        color: hasChar
                            ? const Color(0xFF1A1A2E)
                            : const Color(0xFFD1D5DB),
                      ),
                    );
                  }),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}