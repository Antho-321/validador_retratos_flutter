// lib/apps/asistente_retratos/presentation/widgets/face_landmarks_painter.dart

import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' show BuildContext, Theme; // para Theme.of
import '../../domain/model/lmk_state.dart';
import '../styles/colors.dart'; // AppColors & CaptureTheme

class FacePainter extends CustomPainter {
  final LmkState lmk;
  final bool mirror;
  final Size? srcSize;              // tamaño del frame de video (w,h)
  final Color landmarksColor;       // color ya resuelto (temable)
  final int _seqSnapshot;

  FacePainter(
    this.lmk, {
    this.mirror = false,
    this.srcSize,
    this.landmarksColor = AppColors.landmarks, // fallback a la paleta
  }) : _seqSnapshot = lmk.lastSeq;

  /// Creador auxiliar que resuelve el color desde el Theme (si existe).
  static FacePainter themed(
    BuildContext context,
    LmkState lmk, {
    bool mirror = false,
    Size? srcSize,
  }) {
    final cap = Theme.of(context).extension<CaptureTheme>();
    final color = cap?.landmarks ?? AppColors.landmarks;
    return FacePainter(
      lmk,
      mirror: mirror,
      srcSize: srcSize,
      landmarksColor: color,
    );
  }

  @override
  void paint(Canvas c, Size size) {
    final faces = lmk.last;
    if (faces == null || !lmk.isFresh) return;

    // Tamaño fuente (frame del servidor). Si es null, asumimos canvas.
    final s = srcSize ?? size;
    final sw = s.width;
    final sh = s.height;
    if (sw <= 0 || sh <= 0) return;

    // BoxFit.cover
    final scale = (size.width / sw) > (size.height / sh)
        ? (size.width / sw)
        : (size.height / sh);
    final offX = (size.width - sw * scale) / 2;
    final offY = (size.height - sh * scale) / 2;

    final paint = Paint()
      ..color = landmarksColor
      ..style = PaintingStyle.fill;

    for (final face in faces) {
      for (final p in face) {
        var x = p.dx * scale + offX;
        if (mirror) x = size.width - x; // espejo como en la preview
        final y = p.dy * scale + offY;
        c.drawCircle(Offset(x, y), 2.0, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant FacePainter old) =>
      old._seqSnapshot != _seqSnapshot ||
      old.mirror != mirror ||
      old.landmarksColor != landmarksColor ||
      (old.srcSize?.width != srcSize?.width) ||
      (old.srcSize?.height != srcSize?.height);
}
