// lib/apps/asistente_retratos/presentation/widgets/face_landmarks_painter.dart
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
    final faces = lmk.last;
    if (faces == null || !lmk.isFresh) return;

    final s = srcSize ?? size;
    final sw = s.width, sh = s.height;
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
      // Mirror horizontally in destination space
      c.translate(sw * scale, 0);
      c.scale(-scale, scale);
    } else {
      c.scale(scale, scale);
    }

    // Keep ~2px radius dots on screen (diameter ≈ 4px)
    _paint
      ..color = landmarksColor
      ..strokeWidth = 4.0 / scale;

    // Draw each face in one batched call (points are already in src pixels)
    for (final face in faces) {
      if (face.isNotEmpty) {
        c.drawPoints(ui.PointMode.points, face, _paint);
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
