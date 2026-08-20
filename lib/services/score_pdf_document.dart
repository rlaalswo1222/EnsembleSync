import 'dart:typed_data';

abstract class ScorePdfDocument {
  int get pagesCount;

  Future<Uint8List?> renderPage(int pageIndex, {double scale = 2});

  Future<void> close();
}
