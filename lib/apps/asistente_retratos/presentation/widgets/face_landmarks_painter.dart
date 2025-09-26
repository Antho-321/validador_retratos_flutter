// lib/apps/asistente_retratos/presentation/widgets/face_landmarks_painter.dart
import 'dart:typed_data' show Float32List;
import 'dart:ui' as ui show PointMode; // ← for ui.PointMode
import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' show BuildContext, Theme;
import 'package:flutter/foundation.dart' show ValueListenable;

import '../../domain/model/lmk_state.dart';
import '../styles/colors.dart';

/// Face overlay that never rebuilds per frame; the painter listens to changes.
class FaceOverlayFast extends StatelessWidget {
  const FaceOverlayFast({
    super.key,
    required this.listenable,
    this.mirror = false,
    this.srcSize,
    this.landmarksColor,
  });

  final ValueListenable<LmkState> listenable;
  final bool mirror;
  final Size? srcSize; // tamaño (w,h) del frame fuente, si se conoce
  final Color? landmarksColor;

  @override
  Widget build(BuildContext context) {
    final cap = Theme.of(context).extension<CaptureTheme>();
    final color = landmarksColor ?? cap?.landmarks ?? AppColors.landmarks;

    return RepaintBoundary(
      child: CustomPaint(
        painter: _FacePainterFast(
          listenable: listenable,
          mirror: mirror,
          srcSize: srcSize,
          color: color,
        ),
      ),
    );
  }
}

/// Painter de cara optimizado: usa hold-last interno y drawRawPoints.
/// Dibuja cruces pequeñas por landmark con un único llamado al canvas.
class _FacePainterFast extends CustomPainter {
  _FacePainterFast({
    required this.listenable,
    required this.mirror,
    required this.srcSize,
    required this.color,
  })  : _paint = Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..isAntiAlias = false
          ..strokeCap = StrokeCap.round,
        super(repaint: listenable);

  final ValueListenable<LmkState> listenable;
  final bool mirror;
  final Size? srcSize;
  final Color color;

  final Paint _paint;

  // ── Hold-last cache ─────────────────────────────────────────────────────
  List<Float32List>? _holdFlat;
  Size? _holdImgSize;
  DateTime _holdTs = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _freshWindow = Duration(milliseconds: 400);

  // ── Buffer reutilizable para drawRawPoints(PointMode.lines) ─────────────
  Float32List _lineBuf = Float32List(0);

  // Transform cache
  Size? _lastCanvasSize;
  Size? _lastImgSize;
  bool? _lastMirror;
  double _scale = 1.0, _offX = 0.0, _offY = 0.0;

  @override
  void paint(Canvas c, Size size) {
    final v = listenable.value;
    final now = DateTime.now();

    // Actualiza hold-last si llegaron datos frescos
    if (v.lastFlat != null && v.lastFlat!.isNotEmpty && v.isFresh) {
      _holdFlat = v.lastFlat;
      _holdImgSize = v.imageSize ?? _holdImgSize;
      _holdTs = v.lastTs ?? _holdTs; // ← nullable-safe
    }

    // Selecciona qué dibujar (nuevo vs hold-last)
    final bool holdFresh = now.difference(_holdTs) < _freshWindow;
    final List<Float32List>? flats = (v.lastFlat != null &&
            v.lastFlat!.isNotEmpty &&
            v.isFresh)
        ? v.lastFlat
        : (holdFresh ? _holdFlat : null);

    if (flats == null || flats.isEmpty) return;

    // Tamaño fuente (donde están expresados los puntos)
    final Size imgSize = srcSize ?? v.imageSize ?? _holdImgSize ?? size;
    if (imgSize.width <= 0 || imgSize.height <= 0) return;

    // Recalcula transform si cambian entradas
    if (_lastCanvasSize != size ||
        _lastImgSize != imgSize ||
        _lastMirror != mirror) {
      final sw = imgSize.width, sh = imgSize.height;
      final scaleW = size.width / sw;
      final scaleH = size.height / sh;
      _scale = (scaleW > scaleH) ? scaleW : scaleH;
      _offX = (size.width - sw * _scale) / 2.0;
      _offY = (size.height - sh * _scale) / 2.0;

      _lastCanvasSize = size;
      _lastImgSize = imgSize;
      _lastMirror = mirror;
    }

    // Grosor ≈ 4 px en pantalla (independiente del zoom)
    _paint
      ..color = color
      ..strokeWidth = 4.0 / _scale;

    // Radio de la cruz ≈ 2 px en pantalla
    final double r = 2.0 / _scale;

    c.save();
    c.translate(_offX, _offY);
    if (mirror) {
      c.translate(imgSize.width * _scale, 0);
      c.scale(-_scale, _scale);
    } else {
      c.scale(_scale, _scale);
    }

    // Calcula floats necesarios y ajusta buffer (exact length → no start/count)
    int neededFloats = 0;
    for (final f in flats) {
      final pts = f.length >> 1; // /2
      neededFloats += pts * 8;   // 8 floats por “+”
    }
    if (_lineBuf.length != neededFloats) {
      _lineBuf = Float32List(neededFloats);
    }

    // Rellena buffer
    int k = 0;
    for (final f in flats) {
      for (int i = 0; i + 1 < f.length; i += 2) {
        final double x = f[i], y = f[i + 1];
        // horiz
        _lineBuf[k++] = x - r; _lineBuf[k++] = y;
        _lineBuf[k++] = x + r; _lineBuf[k++] = y;
        // vert
        _lineBuf[k++] = x;     _lineBuf[k++] = y - r;
        _lineBuf[k++] = x;     _lineBuf[k++] = y + r;
      }
    }

    // Dibuja todos los segmentos (sin start/count)
    c.drawRawPoints(ui.PointMode.lines, _lineBuf, _paint);
    c.restore();
  }

  @override
  bool shouldRepaint(covariant _FacePainterFast old) {
    return old.mirror != mirror ||
        old.color != color ||
        old.srcSize != srcSize ||
        !identical(old.listenable, listenable);
  }
}