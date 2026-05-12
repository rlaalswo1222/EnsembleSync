class ApiConstants {
  // TODO: 서버 배포 후 실제 URL로 변경
  static const String baseUrl = 'http://localhost:8000';

  // Rooms
  static const String createRoom = '/rooms';
  static String joinRoom(String roomCode) => '/rooms/$roomCode/join';
  static String getRoom(String roomCode) => '/rooms/$roomCode';
}