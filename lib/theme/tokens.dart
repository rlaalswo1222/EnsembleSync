import 'package:flutter/material.dart';

/// 앱 전체가 공유하는 디자인 토큰.
///
/// 화면마다 색을 직접 적으면 반드시 어긋난다. 실제로 개편 전 코드에는
/// `0xFF1A1A2E` 와 `0xFF111827` 이 둘 다 "거의 검정"으로 섞여 쓰이고 있었고,
/// 탭마다 카드 여백이 12 와 16 으로 달랐다. 값은 여기에만 둔다.
///
/// 색 규칙은 하나다 — **기본은 무채색, 강조색은 예외 상태에만.**
/// 검정이 곧 "켜짐"이고, [AppColors.accent] 는 솔로처럼 한 트랙만 들리는
/// 특별한 상태에만 쓴다. 강조색이 흔해지면 강조가 아니게 된다.
class AppColors {
  const AppColors._();

  // ── 바탕 ────────────────────────────────────────────────
  /// 카드와 시트의 바탕.
  static const Color surface = Color(0xFFFFFFFF);

  /// 카드 뒤에 깔리는 화면 바탕. 흰 카드가 떠 보이게 하는 역할.
  static const Color canvas = Color(0xFFF5F5F7);

  /// 비활성 컨트롤의 채움. 슬라이더의 지나지 않은 구간 같은 것.
  static const Color fill = Color(0xFFF2F2F7);

  // ── 글자 ────────────────────────────────────────────────
  /// 제목과 주요 숫자. 켜진 컨트롤의 색이기도 하다.
  static const Color ink = Color(0xFF000000);

  /// 본문. 검정보다 한 단계 약하게.
  static const Color inkBody = Color(0xFF1C1C1E);

  /// 라벨과 보조 설명.
  static const Color inkSecondary = Color(0xFF6E6E73);

  /// 힌트와 비활성 글자.
  static const Color inkTertiary = Color(0xFFAEAEB2);

  // ── 선 ─────────────────────────────────────────────────
  /// 카드 테두리와 구분선. 둘을 같은 값으로 두어야 화면이 정돈돼 보인다.
  static const Color separator = Color(0xFFE5E5EA);

  // ── 파형 ────────────────────────────────────────────────
  /// 파형이 놓이는 바닥.
  ///
  /// 검은 막대를 흰 카드에 바로 얹으면 옆의 검은 글씨·슬라이더와 뭉쳐 보인다.
  /// 색을 더하는 대신 **옅은 바닥을 깔아** 영역을 나눈다. 색은 사람 구분에
  /// 쓰기로 했으니 여기서는 쓸 수 없다.
  static const Color waveGround = Color(0xFFF5F5F7);

  /// 이미 지나간 구간.
  static const Color wavePlayed = Color(0xFF000000);

  /// 아직 남은 구간. 바닥보다 확실히 진해야 막대로 보인다.
  static const Color waveUpcoming = Color(0xFFAEAEB2);

  // ── 강조 ────────────────────────────────────────────────
  /// 솔로처럼 "지금 이것만"을 뜻하는 예외 상태 전용.
  ///
  /// 시안 계열을 쓰되 시안 그대로(#00C2D1)는 쓰지 않는다. 그 위에 흰 글씨를
  /// 얹으면 명도 대비가 2.3:1 밖에 안 나와서 글자가 안 읽힌다. 한 단계
  /// 어둡게 내려 대비를 확보했다.
  static const Color accent = Color(0xFF00849A);
  static const Color onAccent = Color(0xFFFFFFFF);

  // ── 알림 ────────────────────────────────────────────────
  static const Color danger = Color(0xFFD70015);

  // ── 목록 색 ─────────────────────────────────────────────
  /// 참가자 아바타.
  ///
  /// 이 앱에서 색이 하는 일은 **사람을 구분하는 것** 하나다. 화면 구조는
  /// 흑백이 맡고, 상태와 진행은 [accent] 가 맡는다. 역할을 나눠 두면
  /// 색이 늘어나도 화면이 시끄러워지지 않는다.
  ///
  /// 청록은 [accent] 와, 빨강은 [danger] 와 겹쳐서 뺐다.
  static const List<Color> avatar = <Color>[
    Color(0xFFC2410C),
    Color(0xFF1D4ED8),
    Color(0xFF15803D),
    Color(0xFF7E22CE),
    Color(0xFFBE185D),
  ];

  /// 악보에 필기하는 펜 색.
  ///
  /// 여기만 유채색을 남긴다. 화면을 꾸미는 색이 아니라 **도구**이기 때문이다.
  /// 악보 이미지 위에서 눈에 띄어야 하고, 여러 사람이 각자 다른 색으로
  /// 표시해야 누가 쓴 것인지 구분된다. 무채색으로 바꾸면 기능이 죽는다.
  static const List<Color> pen = <Color>[
    Color(0xFF000000),
    Color(0xFFD70015),
    Color(0xFF007AFF),
    Color(0xFF34C759),
    Color(0xFFFF9500),
    Color(0xFFAF52DE),
  ];
}

/// 여백. 4의 배수로만 간다. 10, 14, 18 같은 값이 섞이면 리듬이 깨진다.
class AppSpace {
  const AppSpace._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
}

/// 모서리 반경. 요소 크기에 따라 세 단계만 쓴다.
class AppRadius {
  const AppRadius._();

  /// 버튼, 작은 컨트롤.
  static const double sm = 10;

  /// 카드.
  static const double md = 14;

  /// 시트, 큰 컨테이너.
  static const double lg = 20;
}

/// 글자 크기. iOS 의 단계 구성을 따랐다.
class AppText {
  const AppText._();

  /// 라벨. 'BPM', 'KEY' 같은 것.
  static const double caption = 11;

  /// 보조 설명.
  static const double footnote = 13;

  /// 본문.
  static const double body = 15;

  /// 소제목. 트랙 이름 같은 것.
  static const double subhead = 17;

  /// 큰 숫자.
  static const double title = 22;

  /// 화면을 대표하는 숫자.
  static const double display = 28;
}
