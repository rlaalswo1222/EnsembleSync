import 'package:flutter/services.dart';

class PlatformShare {
  static const _shareChannel = MethodChannel('ensemble_sync/share');

  static Future<bool> shareRoomText(String text) async {
    final shared = await _shareChannel.invokeMethod<bool>(
      'shareToKakao',
      {'text': text},
    );
    return shared == true;
  }
}
