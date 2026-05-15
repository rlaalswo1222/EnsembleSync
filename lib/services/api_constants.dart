class ApiConstants {
  static const String baseUrl = 'http://3.106.49.28:8000';

  // Rooms
  static const String createRoom = '/api/room/create';
  static const String joinRoom = '/api/room/join';
  static String getRoom(String roomCode) => '/rooms/$roomCode';
}