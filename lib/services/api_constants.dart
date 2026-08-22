class ApiConstants {
  /// 올릴 수 있는 음원 한 건의 최대 크기.
  ///
  /// 서버의 MAX_AUDIO_MB 와 같은 값이어야 한다. 서버도 따로 막지만, 앱이
  /// 파일을 이미 손에 들고 있으므로 올리기 전에 먼저 걸러낸다. 안 그러면
  /// 500MB 를 다 올린 뒤에야 거절당한다.
  static const int maxAudioMb = 100;
  static const int maxAudioBytes = maxAudioMb * 1024 * 1024;

  static const String baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://161-118-211-155.sslip.io',
  );
  static const String wsBaseUrl = String.fromEnvironment(
    'API_WS_URL',
    defaultValue: 'wss://161-118-211-155.sslip.io',
  );

  static const String createRoom = '/api/room/create';
  static const String joinRoom = '/api/room/join';
  static String getRoom(String roomCode) => '/rooms/$roomCode';
}
