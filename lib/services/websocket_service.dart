import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../services/api_constants.dart';

enum WsEventType {
  syncDraw,
  erase,
  clear,
  userJoined,
  userLeft,
  userList,
  scoreUploaded,
  audioUploaded,
  analysisStarted,
  bpmAnalyzed,
  trackSeparated,
  separationProgress,

  /// 분리 작업이 지금 어느 단계인지 알리는 메시지. 진행률만으로는 몇 분씩
  /// 걸리는 동안 무엇을 하고 있는지 알 수 없다.
  separationStage,

  unknown,
}

class WsEvent {
  final WsEventType type;
  final Map<String, dynamic> data;
  const WsEvent(this.type, this.data);
}

class WebSocketService {
  WebSocketChannel? _channel;
  final StreamController<WsEvent> _controller =
      StreamController<WsEvent>.broadcast();
  Timer? _reconnectTimer;

  /// 서버가 보내는 keepalive 에 응답하지 못하면 연결이 끊긴다. 실제로
  /// 분리가 도는 몇 분 사이에 'keepalive ping timeout' 으로 끊겨서, 완료
  /// 알림을 못 받고 앱이 계속 기다린 적이 있다. 이쪽에서도 주기적으로
  /// 신호를 보내 연결을 살려 둔다.
  Timer? _heartbeatTimer;
  static const _heartbeatInterval = Duration(seconds: 15);

  final String roomId;
  final String nickname;

  bool _isDisposed = false;
  int _reconnectAttempts = 0;
  static const _maxReconnectAttempts = 5;

  Stream<WsEvent> get events => _controller.stream;

  WebSocketService({required this.roomId, required this.nickname});

  void connect() {
    _doConnect();
  }

  void _doConnect() {
    if (_isDisposed) return;
    try {
      final uri = Uri.parse(
        '${ApiConstants.wsBaseUrl}/api/ws/room/$roomId',
      ).replace(queryParameters: {'user_name': nickname});
      _channel = WebSocketChannel.connect(uri);
      _reconnectAttempts = 0;
      _channel!.stream.listen(
        _onMessage,
        onError: (_) => _scheduleReconnect(),
        onDone: _scheduleReconnect,
      );
      _startHeartbeat();
    } catch (_) {
      _scheduleReconnect();
    }
  }

  void _onMessage(dynamic raw) {
    try {
      final json = jsonDecode(raw as String) as Map<String, dynamic>;
      final type = _parseType(json['type'] as String? ?? '');
      _controller.add(WsEvent(type, json));
    } catch (_) {}
  }

  WsEventType _parseType(String t) {
    switch (t) {
      case 'sync_draw':
        return WsEventType.syncDraw;
      case 'erase':
        return WsEventType.erase;
      case 'clear':
        return WsEventType.clear;
      case 'user_joined':
        return WsEventType.userJoined;
      case 'user_left':
        return WsEventType.userLeft;
      case 'user_list':
        return WsEventType.userList;
      case 'score_uploaded':
        return WsEventType.scoreUploaded;
      case 'audio_uploaded':
        return WsEventType.audioUploaded;
      case 'analysis_started':
        return WsEventType.analysisStarted;
      case 'bpm_analyzed':
        return WsEventType.bpmAnalyzed;
      case 'track_separated':
        return WsEventType.trackSeparated;
      case 'separation_stage':
        return WsEventType.separationStage;
      case 'separation_progress':
        return WsEventType.separationProgress;
      default:
        return WsEventType.unknown;
    }
  }

  void send(Map<String, dynamic> data) {
    try {
      _channel?.sink.add(jsonEncode(data));
    } catch (_) {}
  }

  void sendDraw(Map<String, dynamic> strokePayload) {
    send({'type': 'draw', 'payload': strokePayload});
  }

  void sendErase(String annotationId) {
    send({'type': 'erase', 'annotation_id': annotationId});
  }

  void sendClear() {
    send({'type': 'clear'});
  }

  void sendScoreUploaded(String fileUrl) {
    send({'type': 'score_uploaded', 'file_url': fileUrl});
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) {
      if (_isDisposed) return;
      try {
        // 서버는 알 수 없는 type 을 그냥 무시한다. 오가는 것 자체가 목적이다.
        _channel?.sink.add(jsonEncode({'type': 'ping'}));
      } catch (_) {
        _scheduleReconnect();
      }
    });
  }

  /// 화면이 다시 앞으로 나왔을 때처럼, 연결이 살아 있는지 확실치 않은
  /// 시점에 부른다. 끊겨 있으면 바로 다시 붙는다.
  void ensureConnected() {
    if (_isDisposed) return;
    if (_channel == null || _channel!.closeCode != null) {
      _reconnectTimer?.cancel();
      _doConnect();
    }
  }

  void _scheduleReconnect() {
    if (_isDisposed) return;
    _heartbeatTimer?.cancel();
    if (_reconnectAttempts >= _maxReconnectAttempts) return;
    _reconnectAttempts++;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 3), _doConnect);
  }

  void dispose() {
    _isDisposed = true;
    _reconnectTimer?.cancel();
    _heartbeatTimer?.cancel();
    _channel?.sink.close();
    _controller.close();
  }
}
