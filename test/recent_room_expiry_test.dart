import 'package:ensemble_sync/services/recent_rooms.dart';
import 'package:flutter_test/flutter_test.dart';

/// 마지막으로 들은 남은 날수가 [daysLeft] 이고, 그걸 [agoDays] 일 전에
/// 들었던 방.
RecentRoom room({int? daysLeft, int agoDays = 0}) => RecentRoom(
      roomId: 'r1',
      roomCode: 'ABC123',
      roomName: '연습방',
      nickname: '민재',
      visitedAt: DateTime.now(),
      token: 't',
      daysLeft: daysLeft,
      daysLeftAt: daysLeft == null
          ? null
          : DateTime.now().subtract(Duration(days: agoDays)),
    );

void main() {
  group('남은 날수 어림', () {
    test('들은 뒤로 흘러간 만큼 줄어든다', () {
      expect(room(daysLeft: 20, agoDays: 0).daysLeftEstimate, 20);
      expect(room(daysLeft: 20, agoDays: 13).daysLeftEstimate, 7);
      expect(room(daysLeft: 20, agoDays: 19).daysLeftEstimate, 1);
    });

    test('기한이 지났어도 음수로 내려가지 않는다', () {
      expect(room(daysLeft: 3, agoDays: 10).daysLeftEstimate, 0);
    });

    test('들은 적이 없으면 모른다', () {
      expect(room().daysLeftEstimate, isNull);
    });
  });

  group('목록에 띄울 문구', () {
    test('아직 여유가 있으면 띄우지 않는다', () {
      // 7일(warnWithinDays)을 넘게 남았으면 굳이 겁줄 이유가 없다.
      expect(room(daysLeft: 20, agoDays: 0).expiryLabel, isNull);
      expect(room(daysLeft: 20, agoDays: 12).expiryLabel, isNull);
    });

    test('기한이 가까우면 며칠 남았는지 띄운다', () {
      expect(room(daysLeft: 20, agoDays: 13).expiryLabel, '7일 뒤 정리됨');
      expect(room(daysLeft: 20, agoDays: 18).expiryLabel, '2일 뒤 정리됨');
    });

    test('다 됐으면 날수를 쓰지 않는다', () {
      // '0일 뒤 정리됨' 은 말이 안 된다.
      expect(room(daysLeft: 20, agoDays: 20).expiryLabel, '곧 정리됨');
      expect(room(daysLeft: 1, agoDays: 30).expiryLabel, '곧 정리됨');
    });

    test('모르는 방에는 아무 말도 하지 않는다', () {
      expect(room().expiryLabel, isNull);
    });
  });

  test('어림값은 실제보다 길게 나오지 않는다', () {
    // 그 사이 다른 사람이 방을 썼다면 서버의 기한은 오히려 늘어난다.
    // 우리는 그걸 모르므로 짧게 잡는다 — 예고는 늦는 것보다 이른 편이
    // 낫다.
    for (int ago = 0; ago <= 25; ago++) {
      final int? left = room(daysLeft: 20, agoDays: ago).daysLeftEstimate;
      expect(left! <= 20 - ago || left == 0, isTrue, reason: '$ago일 전');
    }
  });
}
