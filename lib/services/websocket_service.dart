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
  trackSeparated, // 트랙 분리 완료 알림
  unknown,
}

class WsEvent {
  final WsEventType type;
  final Map<String, dynamic> data;
  const WsEvent(this.type, this.data);
}

class WebSocketService {
  WebSocketChannel? _channel;
  StreamController<WsEvent>? _controller;
  Timer? _reconnectTimer;

  final String roomId;
  final String nickname;

  bool _isDisposed = false;
  int _reconnectAttempts = 0;
  static const _maxReconnectAttempts = 5;

  Stream<WsEvent> get events => _controller!.stream;

  WebSocketService({required this.roomId, required this.nickname});

  void connect() {
    _controller ??= StreamController<WsEvent>.broadcast();
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
    } catch (_) {
      _scheduleReconnect();
    }
  }

  void _onMessage(dynamic raw) {
    try {
      final json = jsonDecode(raw as String) as Map<String, dynamic>;
      final type = _parseType(json['type'] as String? ?? '');
      _controller?.add(WsEvent(type, json));
    } catch (_) {}
  }

  WsEventType _parseType(String t) {
    switch (t) {
      case 'sync_draw':       return WsEventType.syncDraw;
      case 'erase':           return WsEventType.erase;
      case 'clear':           return WsEventType.clear;
      case 'user_joined':     return WsEventType.userJoined;
      case 'user_left':       return WsEventType.userLeft;
      case 'user_list':       return WsEventType.userList;
      case 'score_uploaded':  return WsEventType.scoreUploaded;
      case 'track_separated': return WsEventType.trackSeparated;
      default:                return WsEventType.unknown;
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

  void _scheduleReconnect() {
    if (_isDisposed) return;
    if (_reconnectAttempts >= _maxReconnectAttempts) return;
    _reconnectAttempts++;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 3), _doConnect);
  }

  void dispose() {
    _isDisposed = true;
    _reconnectTimer?.cancel();
    _channel?.sink.close();
    _controller?.close();
  }
}