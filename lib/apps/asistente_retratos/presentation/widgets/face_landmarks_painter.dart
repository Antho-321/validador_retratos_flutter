// lib/apps/asistente_retratos/presentation/widgets/face_landmarks_painter.dart
import 'dart:typed_data' show Float32List;
import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' show BuildContext, Theme;
import '../../domain/model/lmk_state.dart';
import '../styles/colors.dart';

class FacePainter extends CustomPainter {
  final LmkState lmk;
  final bool mirror;
  final Size? srcSize;               // frame (w,h) de origen
  final Color landmarksColor;
  final int _seqSnapshot;

  // Hold-last SOLO-flat (evita parpadeos si un frame viene vacío)
  List<Float32List>? _holdFlat;
  Size? _holdImgSize;
  DateTime _holdTs = DateTime.fromMillisecondsSinceEpoch(0);
  bool get _holdFresh =>
      DateTime.now().difference(_holdTs) < const Duration(milliseconds: 400);

  // Reused paint (no allocation on every frame)
  final Paint _paint;

  FacePainter(
    this.lmk, {
    this.mirror = false,
    this.srcSize,
    this.landmarksColor = AppColors.landmarks,
  })  : _seqSnapshot = lmk.lastSeq,
        _paint = Paint()
          ..color = landmarksColor
          ..style = PaintingStyle.stroke
          ..isAntiAlias = true
          ..strokeCap = StrokeCap.round;

  static FacePainter themed(
    BuildContext context,
    LmkState lmk, {
    bool mirror = false,
    Size? srcSize,
  }) {
    final cap = Theme.of(context).extension<CaptureTheme>();
    final color = cap?.landmarks ?? AppColors.landmarks;
    return FacePainter(lmk, mirror: mirror, srcSize: srcSize, landmarksColor: color);
  }

  @override
  void paint(Canvas c, Size size) {
    // Ruta rápida plana
    List<Float32List>? flats = lmk.lastFlat;
    Size imgSize = srcSize ?? size;

    // Actualiza hold-last cuando llegan datos frescos
    if (flats != null && flats.isNotEmpty && lmk.isFresh) {
      _holdFlat = flats;
      _holdImgSize = imgSize;
      _holdTs = DateTime.now();
    }

    // Si no hay datos actuales, usa el hold-last reciente
    if ((flats == null || flats.isEmpty) && _holdFresh) {
      flats = _holdFlat;
      imgSize = _holdImgSize ?? imgSize;
    }

    if (flats == null || flats.isEmpty) return;

    // Tamaño fuente (en px del servidor o del último frame válido)
    final sw = imgSize.width;
    final sh = imgSize.height;
    if (sw <= 0 || sh <= 0) return;

    // BoxFit.cover transform (scale + center)
    final scale = (size.width / sw > size.height / sh)
        ? (size.width / sw)
        : (size.height / sh);
    final offX = (size.width - sw * scale) / 2.0;
    final offY = (size.height - sh * scale) / 2.0;

    c.save();
    c.translate(offX, offY);
    if (mirror) {
      // Mirror horizontal en espacio destino
      c.translate(sw * scale, 0);
      c.scale(-scale, scale);
    } else {
      c.scale(scale, scale);
    }

    // grosor “pantalla” ≈ 4px, independiente del zoom
    _paint
      ..color = landmarksColor
      ..strokeWidth = 4.0 / scale;

    // Ruta rápida: Float32List por cara [x0,y0,x1,y1,...] en px
    // Componemos un Path de cruces pequeñas (dos segmentos por punto).
    final Path path = Path();
    const double r = 2.0; // ≈2px en pantalla (stroke ya compensa con 1/scale)

    for (final Float32List f in flats) {
      for (int i = 0; i + 1 < f.length; i += 2) {
        final double x = f[i];
        final double y = f[i + 1];
        path
          ..moveTo(x - r, y)
          ..lineTo(x + r, y)
          ..moveTo(x, y - r)
          ..lineTo(x, y + r);
      }
    }
    c.drawPath(path, _paint);

    c.restore();
  }

  @override
  bool shouldRepaint(covariant FacePainter old) =>
      old._seqSnapshot != _seqSnapshot ||
      old.lmk != lmk || // repinta cuando llega un LmkState nuevo
      old.mirror != mirror ||
      old.landmarksColor != landmarksColor ||
      old.srcSize != srcSize;
}