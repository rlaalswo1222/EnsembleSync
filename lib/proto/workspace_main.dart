/// 새 분석 워크스페이스 미리보기용 진입점.
///
/// 본 앱은 방 생성 → 업로드 → 분리를 거쳐야 이 화면에 닿는다. 디자인을
/// 확인하려고 매번 그 과정을 반복할 수는 없어서, 이미 서버에 올라가 있는
/// 분리 결과를 직접 물려서 띄운다.
///
///   flutter build web -t lib/proto/workspace_main.dart -o build/proto_web
///
/// analysis.json 은 같은 서버(페이지와 동일 출처)에 두고 상대경로로 읽는다.
library;

import 'package:flutter/material.dart';

import '../models/bpm_result.dart';
import '../models/track_result.dart';
import '../widgets/mixer_workspace.dart';

const String kBase =
    'https://161-118-211-155.sslip.io/uploads/separated/536cea4e-03c5-4d20-ae48-e96773ef3fe3/htdemucs/a89375ae-b264-49e7-8ac2-84c81790362c';

/// 서버 배포 전이라 분석 결과와 재생용 mp3 는 페이지와 같은 자리에서 읽는다.
const String kAnalysisUrl = 'analysis.json';
const String kStreamBase = 'stems';

/// 이 곡의 드럼 트랙에서 뽑은 실제 값. 상세 그래프는 서버 결과가 필요해서
/// 미리보기에서는 빈 값으로 둔다.
const BpmResult kBpmResult = BpmResult(
  jobId: 'preview',
  baseBpm: 99.4,
  maxBpm: 99.4,
  minBpm: 99.4,
  avgBpm: 99.4,
  bpmData: <BpmPoint>[],
  deviationSections: <DeviationSection>[],
);

void main() => runApp(const WorkspacePreviewApp());

class WorkspacePreviewApp extends StatelessWidget {
  const WorkspacePreviewApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '분석 워크스페이스',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: 'Pretendard',
        scaffoldBackgroundColor: const Color(0xFFF8FAFC),
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0F766E)),
      ),
      home: const _PreviewShell(),
    );
  }
}

class _PreviewShell extends StatelessWidget {
  const _PreviewShell();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFE8F3F1),
      body: SafeArea(
        child: Center(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 400),
            height: MediaQuery.of(context).size.height * 0.95,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
            ),
            clipBehavior: Clip.antiAlias,
            child: const _WorkspaceFrame(),
          ),
        ),
      ),
    );
  }
}

/// 본 앱에서 이 화면은 방 화면의 탭 하나로 들어간다. 미리보기에서는 그
/// 자리를 흉내 내려고 상단 바를 직접 얹는다.
class _WorkspaceFrame extends StatelessWidget {
  const _WorkspaceFrame();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 0,
        shape: const Border(
          bottom: BorderSide(color: Color(0xFFE5E7EB)),
        ),
        leading: const BackButton(color: Color(0xFF111827)),
        centerTitle: true,
        title: const Text(
          'Ready, Get Set, Go!',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.bold,
            color: Color(0xFF111827),
          ),
        ),
        actions: const <Widget>[
          Icon(Icons.more_vert, color: Color(0xFF111827)),
          SizedBox(width: 12),
        ],
      ),
      body: MixerWorkspace(
        bpmResult: kBpmResult,
        analysisUrl: kAnalysisUrl,
        tracks: <TrackResult>[
          TrackResult(
            label: '보컬',
            url: '$kBase/vocals.wav',
            streamUrl: '$kStreamBase/vocals.mp3',
            icon: Icons.music_note_rounded,
          ),
          TrackResult(
            label: '드럼',
            url: '$kBase/drums.wav',
            streamUrl: '$kStreamBase/drums.mp3',
            icon: Icons.graphic_eq_rounded,
          ),
          TrackResult(
            label: '베이스',
            url: '$kBase/bass.wav',
            streamUrl: '$kStreamBase/bass.mp3',
            icon: Icons.bar_chart_rounded,
          ),
          TrackResult(
            label: '기타',
            url: '$kBase/other.wav',
            streamUrl: '$kStreamBase/other.mp3',
            icon: Icons.queue_music_rounded,
          ),
        ],
      ),
    );
  }
}
