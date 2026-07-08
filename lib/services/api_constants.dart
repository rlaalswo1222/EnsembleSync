class ApiConstants {
  static const String baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://3.106.49.28:8000',
  );
  static const String wsBaseUrl = String.fromEnvironment(
    'API_WS_URL',
    defaultValue: 'ws://3.106.49.28:8000',
  );

  static const String createRoom = '/api/room/create';
  static const String joinRoom = '/api/room/join';
  static String getRoom(String roomCode) => '/rooms/$roomCode';
}