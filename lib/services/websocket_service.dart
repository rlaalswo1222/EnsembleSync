import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../services/api_constants.dart';

// WebSocket으로 주고받는 이벤트 타입
enum WsEventType {
  snapshot,   // 입장 시 기존 필기 전체 수신
  draw,       // 필기 데이터
  erase,      // 지우기
  clear,      // 전체 삭제
  userJoined, // 참가자 입장
  userLeft,   // 참가자 퇴장
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

  final String roomCode;
  final String nickname;

  bool _isDisposed = false;
  int _reconnectAttempts = 0;
  static const _maxReconnectAttempts = 5;

  Stream<WsEvent> get events => _controller!.stream;

  WebSocketService({required this.roomCode, required this.nickname});

  // ── 연결 ────────────────────────────────────────────────────
  void connect() {
    _controller ??= StreamController<WsEvent>.broadcast();
    _doConnect();
  }

  void _doConnect() {
    if (_isDisposed) return;
    try {
      final uri = Uri.parse(
        '${ApiConstants.wsBaseUrl}/ws/$roomCode?user_name=$nickname',
      );
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

  // ── 메시지 수신 ──────────────────────────────────────────────
  void _onMessage(dynamic raw) {
    try {
      final json = jsonDecode(raw as String) as Map<String, dynamic>;
      final type = _parseType(json['type'] as String? ?? '');
      _controller?.add(WsEvent(type, json));
    } catch (_) {}
  }

  WsEventType _parseType(String t) {
    switch (t) {
      case 'snapshot':   return WsEventType.snapshot;
      case 'draw':       return WsEventType.draw;
      case 'erase':      return WsEventType.erase;
      case 'clear':      return WsEventType.clear;
      case 'user_joined': return WsEventType.userJoined;
      case 'user_left':  return WsEventType.userLeft;
      default:           return WsEventType.unknown;
    }
  }

  // ── 메시지 송신 ──────────────────────────────────────────────
  void send(Map<String, dynamic> data) {
    try {
      _channel?.sink.add(jsonEncode(data));
    } catch (_) {}
  }

  void sendDraw(Map<String, dynamic> strokeData) {
    send({'type': 'draw', ...strokeData});
  }

  void sendErase(String strokeId) {
    send({'type': 'erase', 'stroke_id': strokeId});
  }

  void sendClear() {
    send({'type': 'clear'});
  }

  // ── 재연결 처리 (3초 이내) ───────────────────────────────────
  void _scheduleReconnect() {
    if (_isDisposed) return;
    if (_reconnectAttempts >= _maxReconnectAttempts) return;
    _reconnectAttempts++;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 3), _doConnect);
  }

  // ── 해제 ────────────────────────────────────────────────────
  void dispose() {
    _isDisposed = true;
    _reconnectTimer?.cancel();
    _channel?.sink.close();
    _controller?.close();
  }
}