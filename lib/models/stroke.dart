import 'package:flutter/material.dart';

class Stroke {
  final String id;
  final List<Offset> points;
  final Color color;
  final double width;
  final bool isEraser;
  final bool isHighlighter;

  const Stroke({
    required this.id,
    required this.points,
    required this.color,
    required this.width,
    this.isEraser = false,
    this.isHighlighter = false,
  });
}

enum DrawTool { pen, eraser, highlighter }
