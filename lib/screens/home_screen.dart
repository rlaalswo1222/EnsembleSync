import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/api_service.dart';
import '../services/recent_rooms.dart';
import 'join_room_screen.dart';
import 'main_screen.dart';
import '../theme/tokens.dart';

/// 약관 문서가 놓인 곳. 웹 앱과 함께 배포된다.
const String _legalBase = String.fromEnvironment(
  'LEGAL_BASE_URL',
  defaultValue: 'https://bandly-4e2f0.web.app',
);

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  static const _primary = AppColors.ink;

  final _nicknameController = TextEditingController();
  final _roomNameController = TextEditingController();
  bool _isLoading = false;
  bool get _hasNickname => _nicknameController.text.trim().isNotEmpty;

  /// 이 기기에서 다녀간 방. 6자리 코드를 외우고 있지 않아도 돌아갈 수 있게
  /// 하는 유일한 길이다.
  List<RecentRoom> _recent = const <RecentRoom>[];

  // 흔들기 애니메이션
  late final AnimationController _shakeController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 400),
  );
  late final Animation<double> _shakeAnimation = TweenSequence([
    TweenSequenceItem(tween: Tween(begin: 0.0, end: -10.0), weight: 1),
    TweenSequenceItem(tween: Tween(begin: -10.0, end: 10.0), weight: 2),
    TweenSequenceItem(tween: Tween(begin: 10.0, end: -10.0), weight: 2),
    TweenSequenceItem(tween: Tween(begin: -10.0, end: 10.0), weight: 2),
    TweenSequenceItem(tween: Tween(begin: 10.0, end: 0.0), weight: 1),
  ]).animate(CurvedAnimation(
    parent: _shakeController,
    curve: Curves.easeInOut,
  ));

  @override
  void initState() {
    super.initState();
    _nicknameController.addListener(() => setState(() {}));
    _loadRecent();
  }

  @override
  void dispose() {
    _nicknameController.dispose();
    _roomNameController.dispose();
    _shakeController.dispose();
    super.dispose();
  }

  void _shake() {
    _shakeController.forward(from: 0);
  }

  Future<void> _onCreateRoom() async {
    if (!_hasNickname) {
      _shake();
      return;
    }
    if (_isLoading) return;
    setState(() => _isLoading = true);
    try {
      final roomName = _roomNameController.text.trim().isEmpty
          ? '${_nicknameController.text.trim()}의 방'
          : _roomNameController.text.trim();
      final result = await ApiService()
          .createRoom(roomName, _nicknameController.text.trim());

      // 이 방의 열쇠. 이후 모든 요청이 이걸로 확인받는다.
      ApiService.roomToken = result['room_token'] as String?;

      await RecentRooms.remember(
        roomId: result['room_id']?.toString() ?? '',
        roomCode: result['room_code'] as String,
        roomName: roomName,
        nickname: _nicknameController.text.trim(),
        token: result['room_token'] as String? ?? '',
      );
      if (!mounted) return;
      FocusScope.of(context).unfocus();
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(
          builder: (_) => MainScreen(
            nickname: _nicknameController.text.trim(),
            roomCode: result['room_code'] as String,
            roomId: result['room_id']?.toString() ?? '',
          ),
        ),
        (route) => false,
      );
    } on ApiException catch (e) {
      if (mounted) setState(() => _isLoading = false);
      _showError(e.userMessage);
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
      _showError('서버에 연결할 수 없습니다');
    }
  }

  void _onJoinRoom() {
    if (!_hasNickname) {
      _shake();
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            JoinRoomScreen(nickname: _nicknameController.text.trim()),
      ),
    );
  }

  /// 이용약관과 개인정보처리방침으로 가는 길.
  ///
  /// 앱 안에 문서를 넣지 않고 웹 주소로 연다. 스토어에 올리려면 어차피
  /// 누구나 볼 수 있는 주소가 있어야 하고, 문구를 고칠 때마다 앱을 새로
  /// 배포하는 것도 말이 안 된다.
  Widget _buildLegalLinks() {
    Widget link(String label, String path) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => launchUrl(
          Uri.parse('$_legalBase/$path'),
          mode: LaunchMode.externalApplication,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              color: AppColors.inkTertiary,
              decoration: TextDecoration.underline,
              decorationColor: AppColors.separator,
            ),
          ),
        ),
      );
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        link('이용약관', 'terms.html'),
        const Text('·', style: TextStyle(color: AppColors.separator)),
        link('개인정보처리방침', 'privacy.html'),
      ],
    );
  }

  Future<void> _loadRecent() async {
    final rooms = await RecentRooms.load();
    if (mounted) setState(() => _recent = rooms);
  }

  /// 목록에서 바로 들어간다. 그 방에서 쓰던 이름을 그대로 쓴다.
  Future<void> _reenter(RecentRoom room) async {
    if (_isLoading) return;
    setState(() => _isLoading = true);
    try {
      // 열쇠를 이미 들고 있으면 다시 입장 요청을 하지 않는다.
      //
      // 예전에는 목록에서 누를 때마다 join 을 불렀고, 그때마다 member 와
      // room_participant 행이 새로 쌓였다. 같은 사람이 다섯 번 들어가면
      // 참가자가 다섯 명이 되는 셈이었다.
      String roomId = room.roomId;
      String roomName = room.roomName;

      if (room.token.isEmpty) {
        final result =
            await ApiService().joinRoom(room.roomCode, room.nickname);
        ApiService.roomToken = result['room_token'] as String?;
        roomId = result['room_id']?.toString() ?? room.roomId;
        roomName = result['room_name']?.toString() ?? room.roomName;
      } else {
        ApiService.roomToken = room.token;
      }

      await RecentRooms.remember(
        roomId: roomId,
        roomCode: room.roomCode,
        roomName: roomName,
        nickname: room.nickname,
        token: ApiService.roomToken ?? '',
      );
      if (!mounted) return;
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(
          builder: (_) => MainScreen(
            nickname: room.nickname,
            roomCode: room.roomCode,
            roomId: roomId,
          ),
        ),
        (route) => false,
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      // 서버에서 사라진 방이면 목록에 남겨둘 이유가 없다.
      if (e.statusCode == 404) {
        await RecentRooms.forget(room.roomId);
        await _loadRecent();
        _showError('사라진 방입니다. 목록에서 지웠어요.');
      } else {
        _showError(e.userMessage);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      _showError('서버에 연결할 수 없습니다');
    }
  }

  Future<void> _forget(RecentRoom room) async {
    await RecentRooms.forget(room.roomId);
    await _loadRecent();
  }

  Widget _buildRecentRooms() {
    if (_recent.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 28),
        Row(
          children: [
            const Text(
              '최근 방',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppColors.inkSecondary,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              '${_recent.length}',
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.inkTertiary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        for (final room in _recent) _buildRecentTile(room),
      ],
    );
  }

  Widget _buildRecentTile(RecentRoom room) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _isLoading ? null : () => _reenter(room),
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.separator),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        room.roomName.isEmpty ? room.roomCode : room.roomName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: AppColors.ink,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${room.roomCode} · ${room.nickname} · '
                        '${room.visitedLabel}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppColors.inkTertiary,
                        ),
                      ),
                    ],
                  ),
                ),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _forget(room),
                  child: const Padding(
                    padding: EdgeInsets.all(6),
                    child: Icon(
                      Icons.close_rounded,
                      size: 16,
                      color: AppColors.inkTertiary,
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

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Colors.redAccent),
    );
  }

  // ══════════════════════════════════════════════
  // UI 시작
  // ══════════════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.sizeOf(context).width < 600;

    return Scaffold(
      resizeToAvoidBottomInset: true,
      backgroundColor: isMobile ? Colors.white : AppColors.canvas,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              // 폰은 화면을 다 쓰고, 그보다 넓은 화면에서는 가운데에
              // 모은다. 400 은 데스크톱 창을 기준으로 잡은 값이라 태블릿
              // 에서는 지나치게 좁았다. 세로로 긴 카드가 화면 한가운데
              // 실처럼 서 있었다.
              constraints: BoxConstraints(
                maxWidth: isMobile ? double.infinity : 480,
              ),
              child: ColoredBox(
                color: Colors.white,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    const verticalPadding = 24.0;
                    return SingleChildScrollView(
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 28,
                        vertical: verticalPadding,
                      ),
                      child: ConstrainedBox(
                        // 남은 높이보다 여백이 더 클 수 있다. 그대로 빼면
                        // 최소 높이가 음수가 되어 배치가 통째로 터진다.
                        // 화면이 아주 낮을 때(키보드가 올라온 작은 기기)
                        // 실제로 그런 일이 난다.
                        constraints: BoxConstraints(
                          minHeight: (constraints.maxHeight -
                                  verticalPadding * 2)
                              .clamp(0.0, double.infinity),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            // ── 로고 ──────────────────────────────────────
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                // 앱 아이콘에서 글리프만 뽑아낸 그림이다.
                                // 비슷하게 다시 그린 것이 아니라 원본의
                                // 픽셀 비율을 역산해 만든 것이라 설치
                                // 아이콘과 모양이 완전히 같다.
                                //
                                // 흰색으로 저장해 두고 여기서 물들인다.
                                //
                                // 강조색은 이 앱에서 아껴 쓰는 색이라
                                // 어디에 두느냐가 곧 무엇이 중심인지를
                                // 말한다. 첫 화면에서 가장 먼저 봐야 할
                                // 것은 이 앱이 무엇인가이므로 로고에 준다.
                                Image.asset(
                                  'assets/icons/bandly_mark.png',
                                  height: 48,
                                  color: AppColors.accent,
                                  filterQuality: FilterQuality.medium,
                                ),
                                const SizedBox(width: 10),
                                const Text(
                                  'Bandly',
                                  style: TextStyle(
                                    fontSize: 28,
                                    fontWeight: FontWeight.bold,
                                    color: AppColors.ink,
                                    letterSpacing: -0.5,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              '함께 음악을 만들어보세요',
                              style: TextStyle(
                                fontSize: 14,
                                color: AppColors.inkTertiary,
                              ),
                            ),
                            const SizedBox(height: 48),

                            // ── 닉네임 입력 (흔들기 적용) ──────────────────
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
                            AnimatedBuilder(
                              animation: _shakeAnimation,
                              builder: (_, child) => Transform.translate(
                                offset: Offset(_shakeAnimation.value, 0),
                                child: child,
                              ),
                              child: TextField(
                                controller: _nicknameController,
                                maxLength: 20,
                                textInputAction: TextInputAction.done,
                                decoration: InputDecoration(
                                  hintText: '이름을 입력하세요...',
                                  hintStyle: const TextStyle(
                                      color: AppColors.inkTertiary),
                                  counterText: '',
                                  contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 16, vertical: 14),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    borderSide: const BorderSide(
                                        color: AppColors.separator),
                                  ),
                                  enabledBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    borderSide: const BorderSide(
                                        color: AppColors.separator),
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    borderSide: const BorderSide(
                                      color: _primary,
                                      width: 1.5,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 16),

                            // ── 방 이름 입력 ───────────────────────────────
                            Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                '방 이름 (선택)',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.grey[700],
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            TextField(
                              controller: _roomNameController,
                              maxLength: 30,
                              textInputAction: TextInputAction.done,
                              decoration: InputDecoration(
                                hintText: '비워두면 "닉네임의 방"으로 설정됩니다',
                                hintStyle: const TextStyle(
                                    color: AppColors.inkTertiary, fontSize: 12),
                                counterText: '',
                                contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 14),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(10),
                                  borderSide: const BorderSide(
                                      color: AppColors.separator),
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(10),
                                  borderSide: const BorderSide(
                                      color: AppColors.separator),
                                ),
                                focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(10),
                                  borderSide: const BorderSide(
                                    color: _primary,
                                    width: 1.5,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 16),

                            // ── 방 만들기 버튼 ─────────────────────────────
                            SizedBox(
                              width: double.infinity,
                              height: 50,
                              child: FilledButton.icon(
                                onPressed: _isLoading ? null : _onCreateRoom,
                                style: FilledButton.styleFrom(
                                  backgroundColor: _primary,
                                  disabledBackgroundColor:
                                      AppColors.inkTertiary,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                                icon: _isLoading
                                    ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Colors.white),
                                      )
                                    : const Icon(Icons.add, size: 18),
                                label: Text(
                                  _isLoading ? '생성 중...' : '방 만들기',
                                  style: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600),
                                ),
                              ),
                            ),
                            const SizedBox(height: 10),

                            // ── 방 참가하기 버튼 ───────────────────────────
                            SizedBox(
                              width: double.infinity,
                              height: 50,
                              child: OutlinedButton.icon(
                                onPressed: _onJoinRoom,
                                style: OutlinedButton.styleFrom(
                                  side: const BorderSide(
                                      color: AppColors.inkTertiary),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                                icon: const Icon(Icons.group_rounded,
                                    size: 18, color: AppColors.inkSecondary),
                                label: const Text(
                                  '방 참가하기',
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.inkBody,
                                  ),
                                ),
                              ),
                            ),
                            // ── 안내 ──────────────────────────────────
                            // 목록 아래에 두면 밀려서 안 보인다. 버튼 바로
                            // 밑이라야 왜 눌러도 반응이 없는지 알 수 있다.
                            AnimatedSize(
                              duration: const Duration(milliseconds: 200),
                              child: _hasNickname
                                  ? const SizedBox(width: double.infinity)
                                  : const Padding(
                                      padding: EdgeInsets.only(top: 12),
                                      child: Text(
                                        '닉네임을 입력하여 시작하세요',
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: AppColors.inkTertiary,
                                        ),
                                      ),
                                    ),
                            ),
                            _buildRecentRooms(),
                            const SizedBox(height: 24),
                            _buildLegalLinks(),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
  // ══════════════════════════════════════════════
  // UI 끝
  // ══════════════════════════════════════════════
}
