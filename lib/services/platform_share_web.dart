// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:html' as html;

class PlatformShare {
  static Future<bool> shareRoomText(String text) async {
    final navigator = html.window.navigator;

    try {
      await navigator.share({'text': text});
      return true;
    } catch (_) {
      // Fall through to clipboard. Web Share is unavailable on some browsers
      // and can also be cancelled by the user.
    }

    final clipboard = navigator.clipboard;
    if (clipboard == null) return false;
    await clipboard.writeText(text);
    return true;
  }
}
