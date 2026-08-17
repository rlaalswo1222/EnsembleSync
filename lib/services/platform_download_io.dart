import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

class PlatformDownload {
  static Future<String?> saveBytes({
    required Uint8List bytes,
    required String filename,
    required List<String> allowedExtensions,
    String? dialogTitle,
  }) {
    return FilePicker.platform.saveFile(
      dialogTitle: dialogTitle,
      fileName: filename,
      type: FileType.custom,
      allowedExtensions: allowedExtensions,
      bytes: bytes,
    );
  }
}
