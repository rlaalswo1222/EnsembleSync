class ApiConstants {
  static const String baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://3-106-49-28.sslip.io',
  );
  static const String wsBaseUrl = String.fromEnvironment(
    'API_WS_URL',
    defaultValue: 'wss://3-106-49-28.sslip.io',
  );

  static const String createRoom = '/api/room/create';
  static const String joinRoom = '/api/room/join';
  static String getRoom(String roomCode) => '/rooms/$roomCode';
}
