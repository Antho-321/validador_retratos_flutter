// lib/apps/asistente_retratos/presentation/widgets/face_landmarks_painter.dart
import 'dart:typed_data' show Float32List;
import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' show BuildContext, Theme;
import '../../domain/model/lmk_state.dart';
import '../styles/colors.dart';
import 'dart:ui' as ui;

class FacePainter extends CustomPainter {
  final LmkState lmk;
  final bool mirror;
  final Size? srcSize;               // frame (w,h) de origen
  final Color landmarksColor;
  final int _seqSnapshot;

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
    // Preferimos la ruta plana si está disponible y fresca
    final flats = lmk.lastFlat;
    final facesLegacy = lmk.last;

    final hasFlat = flats != null && flats.isNotEmpty && lmk.isFresh;
    final hasLegacy = facesLegacy != null && facesLegacy.isNotEmpty && lmk.isFresh;

    if (!hasFlat && !hasLegacy) return;

    // Tamaño fuente (en px del servidor)
    final src = srcSize ?? size;
    final sw = src.width, sh = src.height;
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

    if (hasFlat) {
      // ──────────────────────────────────────────────────────────────
      // Ruta rápida: Float32List por cara [x0,y0,x1,y1,...] en px
      // No creamos Offsets; componemos un Path de cruces pequeñas.
      // (Si tienes topología de aristas, aquí harías moveTo/lineTo).
      // ──────────────────────────────────────────────────────────────
      final Path path = Path();
      final double r = 2.0; // ≈2px en pantalla (el stroke ya compensa con 1/scale)

      for (final Float32List f in flats!) {
        // f: [x0,y0,x1,y1,...] ya en coordenadas de la imagen fuente
        for (int i = 0; i < f.length; i += 2) {
          final double x = f[i];
          final double y = f[i + 1];

          // dibujamos una “+” mini (2 segmentos) para evitar crear Offsets/Rects
          path.moveTo(x - r, y);
          path.lineTo(x + r, y);
          path.moveTo(x, y - r);
          path.lineTo(x, y + r);
        }
      }
      c.drawPath(path, _paint);
    } else {
      // ──────────────────────────────────────────────────────────────
      // Fallback legado: lista de Offsets por cara → usamos drawPoints
      // ──────────────────────────────────────────────────────────────
      for (final face in facesLegacy!) {
        if (face.isNotEmpty) {
          c.drawPoints(ui.PointMode.points, face, _paint);
        }
      }
    }

    c.restore();
  }

  @override
  bool shouldRepaint(covariant FacePainter old) =>
      old._seqSnapshot != _seqSnapshot ||
      old.mirror != mirror ||
      old.landmarksColor != landmarksColor ||
      old.srcSize != srcSize;
}
