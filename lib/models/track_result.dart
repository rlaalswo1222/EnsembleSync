import 'package:flutter/material.dart';

class TrackResult {
  final String label;

  /// 원본 wav 주소. 다운로드는 이쪽을 쓴다.
  final String url;

  /// 재생용 mp3 주소. 서버가 변환에 실패했으면 null 이고, 그때는 [url] 로
  /// 재생한다. wav 는 4분 곡 기준 트랙당 40MB 라 4개를 받으면 160MB 가 된다.
  final String? streamUrl;

  final IconData icon;

  TrackResult({
    required this.label,
    required this.url,
    required this.icon,
    this.streamUrl,
  });

  /// 재생에 쓸 주소. mp3 가 있으면 그쪽을 쓴다.
  String get playbackUrl => streamUrl ?? url;
}
