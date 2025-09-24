// lib/apps/asistente_retratos/presentation/widgets/pose_landmarks_painter.dart
import 'dart:typed_data' show Float32List;
import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' show BuildContext, Theme;
import '../../domain/model/lmk_state.dart';
import '../styles/colors.dart';
import 'dart:ui' as ui;

/// Conexiones del esqueleto (coinciden con PoseGeom.POSE_CONNECTIONS del servidor)
const List<List<int>> _POSE_EDGES = <List<int>>[
  [0,1],[1,2],[2,3],[3,7],[0,4],[4,5],[5,6],[6,8],[9,10],
  [11,12],[11,13],[13,15],[15,17],[15,19],[15,21],[17,19],
  [12,14],[14,16],[16,18],[16,20],[16,22],[18,20],[11,23],
  [12,24],[23,24],[23,25],[24,26],[25,27],[26,28],[27,29],
  [28,30],[29,31],[30,32],[27,31],[28,32],
];

class PosePainter extends CustomPainter {
  final LmkState lmk;                 // Debe contener los landmarks de pose
  final bool mirror;
  final Size? srcSize;                // Tamaño del frame (w,h) de origen
  final Color skeletonColor;
  final int _seqSnapshot;

  // Pincel reutilizado (evita alloc por frame)
  final Paint _paint;

  PosePainter(
    this.lmk, {
    this.mirror = false,
    this.srcSize,
    this.skeletonColor = AppColors.landmarks, // puedes definir AppColors.pose si lo tienes
  })  : _seqSnapshot = lmk.lastSeq,
        _paint = Paint()
          ..color = skeletonColor
          ..style = PaintingStyle.stroke
          ..isAntiAlias = true
          ..strokeCap = StrokeCap.round;

  /// Variante que toma color desde el Theme (si tu CaptureTheme lo provee).
  static PosePainter themed(
    BuildContext context,
    LmkState lmk, {
    bool mirror = false,
    Size? srcSize,
  }) {
    final cap = Theme.of(context).extension<CaptureTheme>();
    final color = cap?.landmarks ?? AppColors.landmarks;
    return PosePainter(lmk, mirror: mirror, srcSize: srcSize, skeletonColor: color);
  }

  @override
  void paint(Canvas c, Size size) {
    final flats = lmk.lastFlat;       // List<Float32List> con [x0,y0,x1,y1,...] por persona
    final posesLegacy = lmk.last;     // List<List<Offset>> por persona

    final hasFlat = flats != null && flats.isNotEmpty && lmk.isFresh;
    final hasLegacy = posesLegacy != null && posesLegacy.isNotEmpty && lmk.isFresh;
    if (!hasFlat && !hasLegacy) return;

    // Tamaño fuente (en px del servidor)
    final src = srcSize ?? size;
    final sw = src.width, sh = src.height;
    if (sw <= 0 || sh <= 0) return;

    // BoxFit.cover: escala + centrado
    final scale = (size.width / sw > size.height / sh)
        ? (size.width / sw)
        : (size.height / sh);
    final offX = (size.width - sw * scale) / 2.0;
    final offY = (size.height - sh * scale) / 2.0;

    c.save();
    c.translate(offX, offY);
    if (mirror) {
      c.translate(sw * scale, 0);
      c.scale(-scale, scale);
    } else {
      c.scale(scale, scale);
    }

    // grosor “pantalla” ≈ 4px, independiente del zoom
    _paint
      ..color = skeletonColor
      ..strokeWidth = 4.0 / scale;

    if (hasFlat) {
      // Ruta rápida (Float32List): componemos Paths sin crear Offsets
      final Path bones = Path();
      final Path joints = Path();
      final double r = 2.0; // radio de la “+” para la unión (≈2px en pantalla)

      for (final Float32List f in flats!) {
        final count = f.length >> 1; // N puntos (x,y)
        if (count == 0) continue;

        // Dibujar huesos (líneas)
        for (final e in _POSE_EDGES) {
          final int a = e[0], b = e[1];
          if (a < count && b < count) {
            final double x1 = f[(a << 1)    ];
            final double y1 = f[(a << 1) + 1];
            final double x2 = f[(b << 1)    ];
            final double y2 = f[(b << 1) + 1];
            bones.moveTo(x1, y1);
            bones.lineTo(x2, y2);
          }
        }

        // Dibujar juntas (cruces pequeñas, sin alloc de Offsets/Rects)
        for (int i = 0; i < count; i++) {
          final double x = f[(i << 1)    ];
          final double y = f[(i << 1) + 1];
          joints.moveTo(x - r, y);
          joints.lineTo(x + r, y);
          joints.moveTo(x, y - r);
          joints.lineTo(x, y + r);
        }
      }

      // Huesos un poco más gruesos que juntas
      c.drawPath(bones, _paint..strokeWidth = 4.0 / scale);
      c.drawPath(joints, _paint..strokeWidth = 3.0 / scale);
    } else {
      // Fallback legado: lista de Offsets por persona
      for (final pose in posesLegacy!) {
        if (pose.isEmpty) continue;

        // Huesos
        final Path bones = Path();
        final n = pose.length;
        for (final e in _POSE_EDGES) {
          final a = e[0], b = e[1];
          if (a < n && b < n) {
            final p1 = pose[a];
            final p2 = pose[b];
            bones.moveTo(p1.dx, p1.dy);
            bones.lineTo(p2.dx, p2.dy);
          }
        }
        c.drawPath(bones, _paint..strokeWidth = 4.0 / scale);

        // Juntas (rápido con drawPoints)
        c.drawPoints(ui.PointMode.points, pose, _paint..strokeWidth = 3.0 / scale);
      }
    }

    c.restore();
  }

  @override
  bool shouldRepaint(covariant PosePainter old) =>
      old._seqSnapshot != _seqSnapshot ||
      old.mirror != mirror ||
      old.skeletonColor != skeletonColor ||
      old.srcSize != srcSize;
}
