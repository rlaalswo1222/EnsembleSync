import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../models/bpm_result.dart';
import '../theme/tokens.dart';
import '../models/track_analysis.dart';
import '../models/track_result.dart';
import '../services/api_service.dart';
import '../services/mixer_engine.dart';
import '../services/platform_download.dart';
import 'bpm_result_view.dart';
import 'waveform_strip.dart';

/// 분리된 트랙을 한 화면에서 함께 다루는 작업 화면.
///
/// 재생 버튼은 화면에 하나뿐이고 4트랙이 같이 움직인다. 트랙마다 조절하는
/// 것은 볼륨과 음소거/솔로뿐이다.
class MixerWorkspace extends StatefulWidget {
  const MixerWorkspace({
    super.key,
    required this.tracks,
    this.analysisUrl,
    this.bpmResult,
    this.bpmPending = false,
    this.audioUrl,
    this.onUrlsExpired,
  });

  final List<TrackResult> tracks;

  /// 서버가 분리와 함께 만들어 둔 analysis.json 주소. 없을 수 있다.
  final String? analysisUrl;

  /// BPM 분석 결과. 상단에 숫자로 띄우고, 누르면 구간별 상세를 연다.
  final BpmResult? bpmResult;

  /// BPM 분석이 아직 돌고 있는 상태. 숫자 자리에 진행 표시를 낸다.
  final bool bpmPending;

  /// 업로드된 원본 음원 주소. BPM 상세 화면의 재생에 쓴다.
  final String? audioUrl;

  /// 파일 주소가 만료돼 못 불러왔을 때 부른다. 상위 화면이 서버에서 새
  /// 주소를 받아오면 트랙 주소가 바뀌고, 그러면 이 위젯이 통째로 다시
  /// 만들어지면서(key 가 주소로 되어 있다) 저절로 다시 시도된다.
  final Future<void> Function()? onUrlsExpired;

  @override
  State<MixerWorkspace> createState() => _MixerWorkspaceState();
}

class _MixerWorkspaceState extends State<MixerWorkspace> {
  static const Color _primary = AppColors.ink;
  static const Color _border = AppColors.separator;
  static const Color _muted = AppColors.inkSecondary;
  static const Color _ink = AppColors.ink;

  /// 화면 좌우 여백 + 카드 안쪽 여백. 재생선과 파형의 시작점을 맞추는 데 쓴다.
  /// 화면 좌우 여백. 파형이 시작하는 x 이기도 하다. 트랙마다 같은 값이어야
  /// 세로로 시각이 맞는다.
  static const double _outerPad = AppSpace.lg;

  /// 트랜스포트 양쪽 칸의 폭. 좌우가 같아야 재생 버튼이 가운데에 온다.
  static const double _sideSlot = 58;

  final MixerEngine _engine = MixerEngine();
  TrackAnalysis? _analysis;

  /// 무음을 뺀 코드 목록. 재생 위치는 초당 30번 바뀌는데, 그때마다 전체를
  /// 걸러내면 낭비다. 분석을 받을 때 한 번만 추린다.
  List<ChordSegment> _chords = const <ChordSegment>[];

  /// 지금 내려받는 중인 트랙의 주소. 같은 버튼을 두 번 누르는 것을 막는다.
  String? _savingUrl;

  /// 재생 바를 끄는 동안의 위치. 엔진이 보내오는 값과 손가락이 다투지
  /// 않도록, 끄는 중에는 이 값을 우선한다.
  double? _scrub;

  /// 이번 위젯에서 이미 새 주소를 요청했는가.
  bool _askedForNewUrls = false;

  @override
  void initState() {
    super.initState();
    _engine.addListener(_onEngineChanged);
    _startLoading();
    _loadAnalysis();
  }

  void _startLoading() {
    _engine.load(<String, String>{
      for (final TrackResult t in widget.tracks) _stemOf(t): t.playbackUrl,
    });
  }

  @override
  void dispose() {
    _engine.removeListener(_onEngineChanged);
    _engine.dispose();
    super.dispose();
  }

  void _onEngineChanged() {
    if (mounted) setState(() {});
    if (_engine.error != null) _recoverFromLoadFailure();
  }

  /// 트랙을 못 불러왔을 때 주소를 새로 받아 한 번 더 해본다.
  ///
  /// 실패 이유가 주소 만료인지 네트워크 문제인지는 여기서 알 수 없다.
  /// SoLoud 는 그냥 못 불러왔다고만 알려준다. 둘 다 주소를 새로 받아
  /// 다시 해보면 나아질 수 있는 일이라 구분하지 않는다.
  ///
  /// 되풀이는 상위 화면이 막는다. 여기서 세면 안 되는데, 주소가 바뀌면
  /// 이 위젯 자체가 새로 만들어져서 센 값이 사라지기 때문이다.
  void _recoverFromLoadFailure() {
    if (_askedForNewUrls || widget.onUrlsExpired == null) return;
    _askedForNewUrls = true;
    widget.onUrlsExpired!();
  }

  /// analysis.json 의 피크는 스템 이름으로 묶여 있다. 파일명에서 그 이름을
  /// 되찾는다. 확장자를 떼므로 wav 든 mp3 든 같은 값이 나온다.
  String _stemOf(TrackResult t) {
    final String name = Uri.parse(t.url).pathSegments.last;
    final int dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  Future<void> _loadAnalysis() async {
    final String? url = widget.analysisUrl;
    if (url == null) return;
    try {
      final http.Response res =
          await http.get(Uri.parse(url)).timeout(const Duration(seconds: 10));
      if (!mounted) return;
      // 410 은 주소의 유효기간이 지났다는 뜻이다. 새로 받아오면 살아난다.
      if (res.statusCode == 410) {
        _recoverFromLoadFailure();
        return;
      }
      if (res.statusCode != 200) return;
      final TrackAnalysis? parsed = TrackAnalysis.tryParse(res.body);
      setState(() {
        _analysis = parsed;
        _chords = parsed == null
            ? const <ChordSegment>[]
            : parsed.chords
                .where((ChordSegment c) => !c.isSilence)
                .toList(growable: false);
      });
    } catch (_) {
      // 파형과 코드가 없어도 재생은 된다. 조용히 넘어간다.
    }
  }

  double get _totalSeconds {
    final double fromEngine = _engine.length.inMilliseconds / 1000;
    if (fromEngine > 0) return fromEngine;
    return _analysis?.duration ?? 0;
  }

  /// 화면에 보여줄 재생 위치.
  ///
  /// 재생 바를 끄는 동안에는 손가락 위치를 쓴다. 소리는 손을 뗄 때 한 번만
  /// 옮기지만(끄는 내내 seek 하면 뚝뚝 끊긴다), 눈에 보이는 것은 손을
  /// 따라와야 한다. 파형의 재생선과 코드 표시가 이 값을 함께 쓴다.
  double _shownProgress(Duration pos) {
    if (_scrub != null) return _scrub!;
    final double total = _totalSeconds;
    if (total <= 0) return 0;
    return (pos.inMilliseconds / 1000 / total).clamp(0.0, 1.0);
  }

  double _shownSeconds(Duration pos) => _shownProgress(pos) * _totalSeconds;

  void _seekToFraction(double fraction) {
    final double total = _totalSeconds;
    if (total <= 0) return;
    _engine.seek(
      Duration(milliseconds: (fraction.clamp(0.0, 1.0) * total * 1000).round()),
    );
  }

  String _extensionOf(TrackResult track) {
    final String? ext =
        Uri.tryParse(track.url)?.pathSegments.last.split('.').last;
    if (ext == null || ext.length > 5) return 'wav';
    return ext.toLowerCase();
  }

  String _filenameOf(TrackResult track) {
    final String safe = track.label.replaceAll(RegExp(r'[\/:*?"<>|\s]+'), '_');
    return '${safe}_track.${_extensionOf(track)}';
  }

  Future<void> _downloadTrack(TrackResult track) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final String filename = _filenameOf(track);
    setState(() => _savingUrl = track.url);

    try {
      final Uint8List bytes = await ApiService().downloadTrack(track.url);
      if (!mounted) return;

      messenger.showSnackBar(
        const SnackBar(content: Text('저장할 위치를 선택해주세요.')),
      );

      final String? savedPath = await PlatformDownload.saveBytes(
        bytes: bytes,
        filename: filename,
        allowedExtensions: <String>[_extensionOf(track)],
        dialogTitle: '트랙 저장 위치 선택',
      );
      if (!mounted) return;

      messenger.showSnackBar(
        SnackBar(
          content: Text(
            savedPath == null ? '트랙 저장이 취소되었습니다.' : '저장 완료: $savedPath',
          ),
        ),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      // 410 은 주소의 유효기간이 지났다는 뜻이다. 파일은 서버에 그대로
      // 있으니, 새 주소를 받아 다시 누르면 된다고 알려준다.
      if (e.statusCode == 410) {
        _recoverFromLoadFailure();
        messenger.showSnackBar(
          const SnackBar(content: Text('주소를 새로 받았습니다. 다시 눌러주세요.')),
        );
      } else {
        messenger.showSnackBar(
          SnackBar(content: Text('트랙 다운로드 실패: ${e.message}')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('트랙 다운로드 실패: $e')),
      );
    } finally {
      if (mounted) setState(() => _savingUrl = null);
    }
  }

  static String _fmt(Duration d) {
    final String m = d.inMinutes.toString();
    final String s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    if (_engine.error != null) {
      return _Message(
        icon: Icons.error_outline_rounded,
        text: '오디오를 불러오지 못했습니다\n${_engine.error}',
        onRetry: _startLoading,
      );
    }
    if (!_engine.isReady) {
      return _Message(
        icon: Icons.graphic_eq_rounded,
        text: _engine.loadingLabel.isEmpty ? '준비 중' : _engine.loadingLabel,
        spinner: true,
        // 오래 걸리면 손으로 다시 걸어볼 수 있어야 한다. 화면에 갇히면 안 된다.
        onRetry: _engine.isLoading ? null : _startLoading,
      );
    }

    return Column(
      children: <Widget>[
        _buildInfoBar(),
        Expanded(child: _buildTrackStack()),
        _buildTransport(),
      ],
    );
  }

  // ── 상단 정보 바 ────────────────────────────────────────────

  Widget _buildInfoBar() {
    return Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: _border)),
      ),
      child: IntrinsicHeight(
        child: Row(
          children: <Widget>[
            Expanded(child: _buildBpmCell()),
            const VerticalDivider(width: 1, color: _border),
            Expanded(flex: 2, child: _buildKeyCell()),
          ],
        ),
      ),
    );
  }

  Widget _buildBpmCell() {
    final BpmResult? result = widget.bpmResult;

    return InkWell(
      onTap: result == null ? null : _openBpmDetail,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                const Text(
                  'BPM',
                  style: TextStyle(fontSize: 10, color: _muted),
                ),
                if (result != null) ...<Widget>[
                  const SizedBox(width: 2),
                  const Icon(
                    Icons.chevron_right_rounded,
                    size: 14,
                    color: _muted,
                  ),
                ],
              ],
            ),
            if (result != null)
              Text(
                result.avgBpm.round().toString(),
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: _primary,
                ),
              )
            else if (widget.bpmPending)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 5),
                child: SizedBox(
                  width: 17,
                  height: 17,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: _primary,
                  ),
                ),
              )
            else
              const Text(
                '—',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: AppColors.inkTertiary,
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 구간별 템포 상세. 기존 BPM 결과 화면을 그대로 시트로 띄운다.
  /// 그 화면도 자체 재생기를 갖고 있어서, 겹쳐 나오지 않도록 믹서를 멈춘다.
  void _openBpmDetail() {
    _engine.pause();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (BuildContext context) => FractionallySizedBox(
        heightFactor: 0.9,
        child: Column(
          children: <Widget>[
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.separator,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Expanded(
              child: BpmResultView(
                result: widget.bpmResult!,
                audioUrl: widget.audioUrl,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildKeyCell() {
    final KeyEstimate? key = _analysis?.key;
    final int shift = _engine.semitones;
    final bool canShift = _engine.pitchAvailable;

    final String display;
    if (key != null && key.isValid) {
      display = shift == 0
          ? key.short()!
          : '${key.short()} → ${key.short(semitones: shift)}';
    } else {
      display = shift == 0 ? '—' : (shift > 0 ? '+$shift' : '$shift');
    }

    // 나란한조는 구성음이 같아 기계가 확신을 못 준다. 숨기지 말고 같이 띄운다.
    final String sub;
    if (shift != 0) {
      sub = '${shift > 0 ? '+' : ''}$shift 반음';
    } else if (key != null && key.isValid && key.isAmbiguous) {
      sub = '${key.label} 또는 ${key.relativeLabel}';
    } else if (key != null && key.isValid) {
      sub = key.label;
    } else {
      sub = '분석 없음';
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Text('KEY', style: TextStyle(fontSize: 10, color: _muted)),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              _StepButton(
                icon: Icons.remove,
                onTap: canShift && shift > -MixerEngine.maxSemitones
                    ? () => _engine.setSemitones(shift - 1)
                    : null,
              ),
              const SizedBox(width: 10),
              ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 92),
                child: Text(
                  display,
                  textAlign: TextAlign.center,
                  // 원키가 아니면 원곡과 달라져 있다는 뜻이라 눈에 띄어야 한다.
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: shift == 0 ? AppColors.ink : AppColors.accent,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              _StepButton(
                icon: Icons.add,
                onTap: canShift && shift < MixerEngine.maxSemitones
                    ? () => _engine.setSemitones(shift + 1)
                    : null,
              ),
            ],
          ),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: shift == 0 ? null : () => _engine.setSemitones(0),
            child: Text(
              shift == 0 ? sub : '$sub · 원키로',
              style: TextStyle(
                fontSize: AppText.caption,
                color: shift == 0 ? AppColors.inkSecondary : AppColors.accent,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── 트랙 스택 ──────────────────────────────────────────────

  /// 트랙 목록.
  ///
  /// 파형을 눌러 재생 위치를 옮기는 기능은 뺐다. 볼륨 슬라이더 바로 아래에
  /// 파형이 있어서, 슬라이더를 끌 때마다 부모의 가로 드래그와 슬라이더의
  /// 드래그가 서로 뺏는다. 이동은 아래 재생 바로 한다.
  /// 트랙 한 줄에서 파형을 뺀 나머지가 차지하는 높이.
  ///
  /// 위아래 여백 16, 이름·볼륨·버튼 줄 34, 그 아래 틈 6, 구분선 1.
  /// 남는 높이를 파형에 나눠주려면 이 값을 먼저 빼야 한다.
  static const double _rowChromeHeight = 57;

  /// 파형 높이의 아래위 한계.
  ///
  /// 폰에서는 28 이 빠듯하게 맞고, 태블릿에서는 그대로 두면 화면 아래쪽이
  /// 통째로 빈다. 그렇다고 끝없이 늘리면 파형 하나가 화면을 차지해 여러
  /// 트랙을 견주어 보는 뜻이 사라진다.
  static const double _minWaveHeight = 28;
  static const double _maxWaveHeight = 96;

  Widget _buildTrackStack() {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final int count = widget.tracks.length;
        // 남는 높이를 트랙 수로 나눠 파형에 준다. 화면이 커질수록 파형이
        // 커지는 편이, 아래쪽을 비워두는 것보다 쓸모 있다.
        final double perTrack = count == 0 ? 0 : constraints.maxHeight / count;
        final double waveHeight =
            (perTrack - _rowChromeHeight).clamp(_minWaveHeight, _maxWaveHeight);

        // 트랙은 위에서부터 쌓는다.
        //
        // 가운데로 모아 봤는데 오히려 나빴다. 위 정보 바에 이어 붙어
        // 있어야 한 덩어리로 읽힌다. 가운데에 띄우면 그 사이가 벌어져
        // 서로 상관없는 것처럼 보였다.
        return ListView(
          padding: const EdgeInsets.symmetric(horizontal: _outerPad),
          physics: const ClampingScrollPhysics(),
          children: <Widget>[
            for (int i = 0; i < count; i++)
              _buildTrackRow(
                widget.tracks[i],
                isLast: i == count - 1,
                waveHeight: waveHeight,
              ),
          ],
        );
      },
    );
  }

  /// 트랙 한 줄.
  ///
  /// 카드로 감싸지 않는다. 카드마다 테두리와 안쪽 여백이 생기면 트랙끼리
  /// 파형 시작 x 가 미묘하게 달라 보이고, 무엇보다 상자 네 개가 따로 놀아서
  /// 세로로 훑기가 어렵다. 멀티트랙은 같은 시각이 같은 x 에 있어야 비교가
  /// 되므로, 구분은 얇은 선으로만 한다.
  Widget _buildTrackRow(
    TrackResult track, {
    required bool isLast,
    required double waveHeight,
  }) {
    final String stem = _stemOf(track);
    final bool audible = _engine.isAudible(stem);
    final bool soloed = _engine.isSoloed(stem);
    final List<int> peaks = _analysis?.peaks[stem] ?? const <int>[];

    return DecoratedBox(
      decoration: BoxDecoration(
        border: isLast
            ? null
            : const Border(bottom: BorderSide(color: AppColors.separator)),
      ),
      child: AnimatedOpacity(
        // 소리가 죽은 트랙은 줄째로 흐려진다. 작은 버튼 색만 바꾸는 것보다
        // 훨씬 빨리 읽힌다.
        opacity: audible ? 1.0 : 0.4,
        duration: const Duration(milliseconds: 150),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  SizedBox(
                    width: 46,
                    child: Text(
                      track.label,
                      style: const TextStyle(
                        fontSize: AppText.footnote,
                        fontWeight: FontWeight.w600,
                        color: AppColors.ink,
                      ),
                      overflow: TextOverflow.visible,
                      softWrap: false,
                    ),
                  ),
                  Expanded(
                    child: SliderTheme(
                      // 파형이 이 줄의 주인공이다. 막대가 굵고 진하면 바로
                      // 아래 파형과 경쟁하므로 가늘고 흐리게 둔다.
                      //
                      // 다만 잡는 노브에는 강조색을 준다. 막대까지 칠하면
                      // 화면에 강조색 막대가 다섯 개가 되어 강조가 흐려지고,
                      // 그렇다고 노브까지 무채색이면 흰 배경에서 어디를
                      // 잡아야 할지 안 보인다.
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 2,
                        activeTrackColor: AppColors.inkSecondary,
                        inactiveTrackColor: AppColors.separator,
                        thumbColor: AppColors.accent,
                        overlayShape:
                            const RoundSliderOverlayShape(overlayRadius: 12),
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 6,
                          elevation: 0,
                          pressedElevation: 0,
                        ),
                      ),
                      child: SizedBox(
                        height: 20,
                        child: Slider(
                          value: _engine.volumeOf(stem),
                          onChanged: (double v) => _engine.setVolume(stem, v),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpace.xs),
                  _ToggleCircle(
                    label: 'M',
                    active: _engine.isMuted(stem),
                    color: AppColors.ink,
                    onTap: () => _engine.toggleMute(stem),
                  ),
                  const SizedBox(width: 6),
                  _ToggleCircle(
                    label: 'S',
                    active: soloed,
                    // 솔로만 강조색을 쓴다. "지금 이것만 들린다"는 예외 상태라서.
                    color: AppColors.accent,
                    onTap: () => _engine.toggleSolo(stem),
                  ),
                  const SizedBox(width: 2),
                  _DownloadButton(
                    busy: _savingUrl == track.url,
                    onTap:
                        _savingUrl == null ? () => _downloadTrack(track) : null,
                  ),
                ],
              ),
              const SizedBox(height: 6),
              SizedBox(
                height: waveHeight,
                child: peaks.isEmpty
                    ? const _NoWaveform()
                    : ValueListenableBuilder<Duration>(
                        valueListenable: _engine.position,
                        builder: (BuildContext context, Duration pos, _) {
                          return WaveformStrip(
                            peaks: peaks,
                            peakScale: _analysis?.peakScale ?? 255,
                            color: AppColors.wavePlayed,
                            upcomingColor: AppColors.waveUpcoming,
                            progress: _shownProgress(pos),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 트랜스포트 왼쪽의 코드 칸.
  ///
  /// 반복 버튼이 오른쪽에 있는데 왼쪽은 비어 있었다. 코드를 위에 줄로 따로
  /// 두면 화면이 한 줄 더 눌린다. 남는 자리에 넣는다.
  ///
  /// 지금 코드보다 다음 코드가 더 쓸모 있다. 연주자는 지금 치고 있는 것을
  /// 이미 알기 때문이다. 그래서 둘 다 보여주되 다음 것을 아래에 붙인다.
  Widget _buildChordSlot() {
    if (_chords.isEmpty) return const SizedBox.shrink();

    return ValueListenableBuilder<Duration>(
      valueListenable: _engine.position,
      builder: (BuildContext context, Duration pos, _) {
        final int index = _chordIndexAt(_shownSeconds(pos));
        final String current = _chords[index].label;
        final String? next =
            index + 1 < _chords.length ? _chords[index + 1].label : null;

        // 반대편 반복 버튼이 칸 가운데 있으니 이쪽도 가운데로 둔다.
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            // 코드가 넘어가는 것 자체가 박자 정보다. 짧게 밀어올린다.
            // 결과 화면은 초당 30번 다시 그려지므로 길면 재생선이 끊겨 보인다.
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 160),
              transitionBuilder: (Widget child, Animation<double> a) {
                return FadeTransition(
                  opacity: a,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0, 0.35),
                      end: Offset.zero,
                    ).animate(a),
                    child: child,
                  ),
                );
              },
              child: Text(
                current,
                key: ValueKey<String>(current),
                maxLines: 1,
                overflow: TextOverflow.visible,
                softWrap: false,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: AppColors.ink,
                  height: 1.1,
                ),
              ),
            ),
            if (next != null)
              Text(
                '→ $next',
                maxLines: 1,
                overflow: TextOverflow.visible,
                softWrap: false,
                style: const TextStyle(
                  fontSize: AppText.caption,
                  color: AppColors.inkTertiary,
                ),
              ),
          ],
        );
      },
    );
  }

  /// 지금 울리는 코드의 인덱스. 무음 구간에 걸려 있으면 마지막으로 지난
  /// 코드를 쓴다. 그래야 쉬는 동안 표시가 앞으로 튀지 않는다.
  int _chordIndexAt(double seconds) {
    int last = 0;
    for (int i = 0; i < _chords.length; i++) {
      if (seconds >= _chords[i].time && seconds < _chords[i].end) return i;
      if (_chords[i].time <= seconds) last = i;
    }
    return last;
  }

  // ── 하단 트랜스포트 ─────────────────────────────────────────

  Widget _buildTransport() {
    final Duration total =
        Duration(milliseconds: (_totalSeconds * 1000).round());

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: _border)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          ValueListenableBuilder<Duration>(
            valueListenable: _engine.position,
            builder: (BuildContext context, Duration pos, _) {
              final double value = _shownProgress(pos);
              final Duration shown = Duration(
                milliseconds: (_shownSeconds(pos) * 1000).round(),
              );

              return Row(
                children: <Widget>[
                  SizedBox(
                    width: 40,
                    child: Text(
                      _fmt(shown),
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: _ink,
                      ),
                    ),
                  ),
                  Expanded(
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 3,
                        activeTrackColor: AppColors.accent,
                        inactiveTrackColor: AppColors.fill,
                        thumbColor: AppColors.accent,
                        overlayShape:
                            const RoundSliderOverlayShape(overlayRadius: 12),
                        thumbShape:
                            const RoundSliderThumbShape(enabledThumbRadius: 6),
                      ),
                      child: SizedBox(
                        height: 24,
                        child: Slider(
                          value: value,
                          // 끄는 동안에는 손가락 위치를 그대로 보여주고,
                          // 실제 이동은 손을 뗄 때 한 번만 한다.
                          onChangeStart: (double v) =>
                              setState(() => _scrub = v),
                          onChanged: (double v) => setState(() => _scrub = v),
                          onChangeEnd: (double v) {
                            _seekToFraction(v);
                            setState(() => _scrub = null);
                          },
                        ),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 40,
                    child: Text(
                      _fmt(total),
                      textAlign: TextAlign.right,
                      style: const TextStyle(fontSize: 11, color: _muted),
                    ),
                  ),
                ],
              );
            },
          ),
          Row(
            children: <Widget>[
              SizedBox(width: _sideSlot, child: _buildChordSlot()),
              Expanded(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    IconButton(
                      iconSize: 26,
                      color: _ink,
                      visualDensity: VisualDensity.compact,
                      onPressed: () =>
                          _engine.seekBy(const Duration(seconds: -10)),
                      icon: const Icon(Icons.replay_10_rounded),
                    ),
                    const SizedBox(width: 10),
                    _PlayButton(
                      playing: _engine.isPlaying,
                      onTap: _engine.togglePlay,
                    ),
                    const SizedBox(width: 10),
                    IconButton(
                      iconSize: 26,
                      color: _ink,
                      visualDensity: VisualDensity.compact,
                      onPressed: () =>
                          _engine.seekBy(const Duration(seconds: 10)),
                      icon: const Icon(Icons.forward_10_rounded),
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: _sideSlot,
                child: IconButton(
                  iconSize: 22,
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _engine.setLooping(!_engine.looping),
                  color: _engine.looping
                      ? AppColors.accent
                      : AppColors.inkTertiary,
                  icon: const Icon(Icons.repeat_rounded),
                  tooltip: _engine.looping ? '반복 켜짐' : '반복 꺼짐',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final bool enabled = onTap != null;
    return InkResponse(
      onTap: onTap,
      radius: 22,
      child: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: enabled ? AppColors.inkSecondary : AppColors.separator,
          ),
        ),
        child: Icon(
          icon,
          size: 16,
          color: enabled ? AppColors.ink : AppColors.inkTertiary,
        ),
      ),
    );
  }
}

class _ToggleCircle extends StatelessWidget {
  const _ToggleCircle({
    required this.label,
    required this.active,
    required this.color,
    required this.onTap,
  });

  final String label;
  final bool active;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkResponse(
      onTap: onTap,
      radius: 22,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: active ? color : Colors.transparent,
          border: Border.all(color: active ? color : AppColors.separator),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            color: active ? AppColors.onAccent : AppColors.inkSecondary,
          ),
        ),
      ),
    );
  }
}

class _DownloadButton extends StatelessWidget {
  const _DownloadButton({required this.busy, required this.onTap});

  final bool busy;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkResponse(
      onTap: busy ? null : onTap,
      radius: 22,
      child: SizedBox(
        width: 30,
        height: 30,
        child: busy
            ? const Padding(
                padding: EdgeInsets.all(7),
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppColors.inkTertiary,
                ),
              )
            : const Icon(
                Icons.download_rounded,
                size: 20,
                color: AppColors.inkTertiary,
              ),
      ),
    );
  }
}

/// 화면에서 가장 자주 누르는 버튼이라 두 모양이 이어지게 한다.
class _PlayButton extends StatefulWidget {
  const _PlayButton({required this.playing, required this.onTap});

  final bool playing;
  final VoidCallback onTap;

  @override
  State<_PlayButton> createState() => _PlayButtonState();
}

class _PlayButtonState extends State<_PlayButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    value: widget.playing ? 1 : 0,
  );

  @override
  void didUpdateWidget(_PlayButton old) {
    super.didUpdateWidget(old);
    if (widget.playing != old.playing) {
      widget.playing ? _controller.forward() : _controller.reverse();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return InkResponse(
      onTap: widget.onTap,
      radius: 40,
      child: Container(
        width: 64,
        height: 64,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: AppColors.ink,
        ),
        // Icon 은 스스로 가운데에 그리지만 AnimatedIcon 은 그러지 않는다.
        // 정렬을 안 주면 꽉 찬 제약을 그대로 받아 한쪽으로 쏠린다.
        alignment: Alignment.center,
        child: AnimatedIcon(
          icon: AnimatedIcons.play_pause,
          progress: _controller,
          color: AppColors.surface,
          size: 34,
        ),
      ),
    );
  }
}

class _NoWaveform extends StatelessWidget {
  const _NoWaveform();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text(
        '파형 정보 없음',
        style:
            TextStyle(fontSize: AppText.caption, color: AppColors.inkTertiary),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.text,
    this.spinner = false,
    this.onRetry,
  });

  final IconData icon;
  final String text;
  final bool spinner;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          if (spinner)
            const CircularProgressIndicator(color: AppColors.ink)
          else
            Icon(icon, size: 44, color: AppColors.inkTertiary),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: AppText.footnote,
                color: AppColors.inkSecondary,
              ),
            ),
          ),
          if (onRetry != null) ...<Widget>[
            const SizedBox(height: AppSpace.md),
            TextButton.icon(
              onPressed: onRetry,
              style: TextButton.styleFrom(foregroundColor: AppColors.ink),
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('다시 시도'),
            ),
          ],
        ],
      ),
    );
  }
}
