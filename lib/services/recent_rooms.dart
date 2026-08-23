import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 이 기기에서 다녀간 방을 기억한다.
///
/// 방을 찾아가는 열쇠는 6자리 코드 하나뿐인데, 그걸 어디에도 적어두지
/// 않고 있었다. 앱을 껐다 켜면 방은 서버에 멀쩡히 남아 있어도 다시 갈
/// 길이 없었다. 데이터는 영원히 쌓이는데 아무도 쓸 수 없는 상태였다.
///
/// 계정을 만들지 않고 기기에만 남긴다. 로그인 없이도 "다시 들어가기" 가
/// 되는 것이 먼저이고, 계정은 여러 기기를 오갈 필요가 생겼을 때 붙이면
/// 된다.
class RecentRooms {
  const RecentRooms._();

  /// v2 부터 참가 토큰을 함께 담는다.
  ///
  /// 키를 올려 v1 목록을 버린다. 토큰 없이 남아 있으면 눌러도 들어가지지
  /// 않는 항목이 목록에 가득하게 된다. 방 코드를 다시 넣게 하는 편이 낫다.
  static const _key = 'recent_rooms_v2';

  /// 목록에 남기는 최대 개수. 오래된 것부터 밀려난다.
  static const int maxCount = 12;

  static Future<List<RecentRoom>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_key) ?? const <String>[];
    final rooms = <RecentRoom>[];
    for (final line in raw) {
      final room = RecentRoom.tryParse(line);
      // 형식이 바뀌었거나 깨진 항목은 조용히 버린다. 목록 하나 때문에
      // 첫 화면이 안 뜨면 안 된다.
      if (room != null) rooms.add(room);
    }
    rooms.sort((a, b) => b.visitedAt.compareTo(a.visitedAt));
    return rooms;
  }

  /// 방문 기록을 남긴다. 같은 방이면 시각만 새로 쓴다.
  static Future<void> remember({
    required String roomId,
    required String roomCode,
    required String roomName,
    required String nickname,
    required String token,
  }) async {
    if (roomId.isEmpty || roomCode.isEmpty) return;

    final rooms = await load()
      ..removeWhere((r) => r.roomId == roomId);
    rooms.insert(
      0,
      RecentRoom(
        roomId: roomId,
        roomCode: roomCode,
        roomName: roomName,
        nickname: nickname,
        visitedAt: DateTime.now(),
        token: token,
      ),
    );

    await _save(rooms.take(maxCount).toList());
  }

  static Future<void> forget(String roomId) async {
    final rooms = await load()
      ..removeWhere((r) => r.roomId == roomId);
    await _save(rooms);
  }

  static Future<void> _save(List<RecentRoom> rooms) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _key,
      rooms.map((r) => jsonEncode(r.toJson())).toList(),
    );
  }
}

class RecentRoom {
  const RecentRoom({
    required this.roomId,
    required this.roomCode,
    required this.roomName,
    required this.nickname,
    required this.visitedAt,
    required this.token,
  });

  final String roomId;
  final String roomCode;
  final String roomName;

  /// 그 방에서 쓰던 이름. 다시 들어갈 때 그대로 쓴다.
  final String nickname;

  final DateTime visitedAt;

  /// 이 방의 열쇠. 이것이 있어야 방 코드를 다시 넣지 않고 들어갈 수 있다.
  final String token;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'roomId': roomId,
        'roomCode': roomCode,
        'roomName': roomName,
        'nickname': nickname,
        'visitedAt': visitedAt.toIso8601String(),
        'token': token,
      };

  static RecentRoom? tryParse(String line) {
    try {
      final json = jsonDecode(line) as Map<String, dynamic>;
      return RecentRoom(
        roomId: json['roomId'] as String,
        roomCode: json['roomCode'] as String,
        roomName: json['roomName'] as String? ?? '',
        nickname: json['nickname'] as String? ?? '',
        visitedAt: DateTime.tryParse(json['visitedAt'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        token: json['token'] as String? ?? '',
      );
    } catch (_) {
      return null;
    }
  }

  /// '방금', '3시간 전', '어제' 처럼 사람이 읽는 형태.
  String get visitedLabel {
    final diff = DateTime.now().difference(visitedAt);
    if (diff.inMinutes < 1) return '방금';
    if (diff.inMinutes < 60) return '${diff.inMinutes}분 전';
    if (diff.inHours < 24) return '${diff.inHours}시간 전';
    if (diff.inDays == 1) return '어제';
    if (diff.inDays < 30) return '${diff.inDays}일 전';
    return '${visitedAt.year}.${visitedAt.month}.${visitedAt.day}';
  }
}
