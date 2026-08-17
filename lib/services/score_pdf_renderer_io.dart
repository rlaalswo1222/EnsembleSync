import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:pdfrx/pdfrx.dart';

import 'score_pdf_document.dart';

bool _initialized = false;

Future<ScorePdfDocument> openScorePdf(Uint8List bytes) async {
  if (!_initialized) {
    pdfrxFlutterInitialize();
    _initialized = true;
  }

  final document = await PdfDocument.openData(
    Uint8List.fromList(bytes),
    sourceName: 'bandly-score.pdf',
  );
  return _PdfiumScoreDocument(document);
}

class _PdfiumScoreDocument implements ScorePdfDocument {
  final PdfDocument _document;

  _PdfiumScoreDocument(this._document);

  @override
  int get pagesCount => _document.pages.length;

  @override
  Future<Uint8List?> renderPage(
    int pageIndex, {
    double scale = 2,
  }) async {
    final page = _document.pages[pageIndex];
    final rendered = await page.render(
      fullWidth: page.width * scale,
      fullHeight: page.height * scale,
      backgroundColor: 0xFFFFFFFF,
    );
    if (rendered == null) return null;

    try {
      final image = await rendered.createImage();
      try {
        final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
        return byteData?.buffer.asUint8List();
      } finally {
        image.dispose();
      }
    } finally {
      rendered.dispose();
    }
  }

  @override
  Future<void> close() => _document.dispose();
}
