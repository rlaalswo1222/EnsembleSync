import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'api_constants.dart';

class ApiService {
  static final ApiService _instance = ApiService._internal();
  factory ApiService() => _instance;
  ApiService._internal();

  final _client = http.Client();

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      };

  // ── 방 만들기 ──────────────────────────────────────────────
  /// POST /api/room/create
  /// Response: { "status": 200, "room_code": "ABC123", "message": "..." }
  Future<Map<String, dynamic>> createRoom(String roomName, String creatorName) async {
    final uri = Uri.parse('${ApiConstants.baseUrl}${ApiConstants.createRoom}');
    final response = await _client.post(
      uri,
      headers: _headers,
      body: jsonEncode({
        'room_name': roomName,
        'creator_name': creatorName,
      }),
    );

    if (response.statusCode == 200 || response.statusCode == 201) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (data['status'] == 200) return data;
      throw ApiException(data['status'] as int, data['message'] as String? ?? '알 수 없는 오류');
    }
    throw ApiException(response.statusCode, _parseError(response.body));
  }

  // ── 악보 파일 업로드 ───────────────────────────────────────────
  /// POST /api/score/{room_id}/upload
  /// Response: { "status": 200, "file_url": "...", "score_id": "..." }
  Future<String> uploadScore(String roomId, Uint8List bytes, String filename) async {
    final uri = Uri.parse('${ApiConstants.baseUrl}/api/score/$roomId/upload');
    final request = http.MultipartRequest('POST', uri)
      ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));
    final streamed = await request.send();
    final response = await http.Response.fromStream(streamed);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (data['status'] == 200) return data['file_url'] as String;
    throw ApiException(data['status'] as int, data['message'] as String? ?? '업로드 실패');
  }

  // ── 악보 이미지 다운로드 ───────────────────────────────────────
  Future<Uint8List> downloadScore(String fileUrl) async {
    final uri = Uri.parse('${ApiConstants.baseUrl}$fileUrl');
    final response = await _client.get(uri);
    if (response.statusCode == 200) return response.bodyBytes;
    throw ApiException(response.statusCode, '이미지 다운로드 실패');
  }

  // ── 최신 악보 이미지 URL ───────────────────────────────────────
  /// GET /api/score/{room_id}/latest
  Future<String?> getLatestScore(String roomId) async {
    final uri = Uri.parse('${ApiConstants.baseUrl}/api/score/$roomId/latest');
    final response = await _client.get(uri, headers: _headers);
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (data['status'] == 200) return data['file_url'] as String?;
    }
    return null;
  }

  // ── 악보 스냅샷 (기존 필기 전체) ──────────────────────────────
  /// GET /api/score/{room_id}/snapshot
  /// Response: { "status": 200, "strokes": [...] }
  Future<List<Map<String, dynamic>>> getSnapshot(String roomId) async {
    final uri = Uri.parse('${ApiConstants.baseUrl}/api/score/$roomId/snapshot');
    final response = await _client.get(uri, headers: _headers);
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (data['status'] == 200) {
        return List<Map<String, dynamic>>.from(data['strokes'] as List? ?? []);
      }
    }
    return [];
  }

  // ── 방 참가하기 ────────────────────────────────────────────
  /// POST /api/room/join
  /// Response: { "status": 200, "room_name": "...", "message": "..." }
  Future<Map<String, dynamic>> joinRoom(String roomCode, String nickname) async {
    final uri = Uri.parse('${ApiConstants.baseUrl}${ApiConstants.joinRoom}');
    final response = await _client.post(
      uri,
      headers: _headers,
      body: jsonEncode({
        'room_code': roomCode,
        'user_name': nickname,
      }),
    );

    if (response.statusCode == 200 || response.statusCode == 201) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (data['status'] == 200) return data;
      throw ApiException(data['status'] as int, data['message'] as String? ?? '알 수 없는 오류');
    }
    throw ApiException(response.statusCode, _parseError(response.body));
  }

  String _parseError(String body) {
    try {
      final json = jsonDecode(body);
      return json['detail'] ?? json['message'] ?? '알 수 없는 오류';
    } catch (_) {
      return body.isNotEmpty ? body : '서버 오류가 발생했습니다';
    }
  }
}

class ApiException implements Exception {
  final int statusCode;
  final String message;
  const ApiException(this.statusCode, this.message);

  @override
  String toString() => 'ApiException($statusCode): $message';

  String get userMessage {
    switch (statusCode) {
      case 404:
        return '존재하지 않는 방 코드입니다';
      case 409:
        return '이미 입장한 방입니다';
      case 500:
        return '서버 오류가 발생했습니다. 잠시 후 다시 시도해주세요';
      default:
        return message;
    }
  }
}