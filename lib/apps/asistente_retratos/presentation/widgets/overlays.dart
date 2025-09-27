// lib/apps/asistente_retratos/presentation/widgets/overlays.dart
import 'package:flutter/material.dart';
import 'dart:typed_data' show Float32List, Int32List;
import 'dart:ui' as ui show PointMode; // ⬅️ PointMode
import '../../infrastructure/model/pose_frame.dart' show PoseFrame; // ⬅️ ruta corregida
import '../styles/colors.dart' show CaptureTheme; // ⬅️ para faceOval/pipBorder, etc.

/// ───────────────────────── Existing widgets (palette-driven) ─────────────────────────

class CircularMaskPainter extends CustomPainter {
  const CircularMaskPainter({
    required this.circleCenter,
    required this.circleRadius,
    this.maskColor, // ⬅️ NUEVO opcional: inyecta color desde el Theme
  });

  final Offset circleCenter;
  final double circleRadius;
  final Color? maskColor;

  @override
  void paint(Canvas canvas, Size size) {
    // Si no te pasan color, usa un negro 50% (comportamiento anterior)
    final paint = Paint()
      ..color = (maskColor ?? const Color(0x80000000)); // 0.5 de opacidad
    final full = Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    final hole = Path()..addOval(Rect.fromCircle(center: circleCenter, radius: circleRadius));
    final mask = Path.combine(PathOperation.difference, full, hole);
    canvas.drawPath(mask, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}

class TopShade extends StatelessWidget {
  const TopShade({super.key});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Usa scrim de la paleta para la sombra superior, desvaneciendo a transparente.
    final top = scheme.scrim.withOpacity(0.80);
    return IgnorePointer(
      child: Container(
        height: 140,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [top, Colors.transparent],
          ),
        ),
      ),
    );
  }
}

class ProgressRing extends StatelessWidget {
  const ProgressRing({super.key, required this.value, required this.color});
  final double value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textStyle = Theme.of(context).textTheme.titleMedium?.copyWith(
          color: scheme.onSurface,
          fontWeight: FontWeight.w600,
        ) ??
        TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: scheme.onSurface,
        );

    return SizedBox(
      width: 80,
      height: 80,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CircularProgressIndicator(
            value: value,
            strokeWidth: 6,
            // Antes: Colors.white24 → ahora onSurface con baja opacidad
            backgroundColor: scheme.onSurface.withOpacity(0.24),
            valueColor: AlwaysStoppedAnimation<Color>(color), // color viene de tu paleta
          ),
          Text('${(value * 100).round()}%', style: textStyle),
        ],
      ),
    );
  }
}

/// MediaPipe Pose connections (33 pts)
const List<List<int>> kPoseConnections = [
  [0,1],[1,2],[2,3],[3,7],
  [0,4],[4,5],[5,6],[6,8],
  [9,10],
  [11,12],
  [11,13],[13,15],
  [12,14],[14,16],
  [15,17],[17,19],[19,21],
  [16,18],[18,20],[20,22],
  [11,23],[12,24],
  [23,24],
  [23,25],[25,27],
  [24,26],[26,28],
  [27,29],[29,31],
  [28,30],[30,32],
  [27,31],[28,32],
];

/// ───────────────────────── Pose skeleton painter (optimized) ─────────────────────────
class SkeletonPainter extends CustomPainter {
  SkeletonPainter({
    required this.frame,         // PoseFrame from the server (px coords)
    required this.color,
    this.strokeWidth = 2.0,
    this.drawPoints = true,
    this.mirror = false,         // set true if your preview is mirrored
    this.fit = BoxFit.contain,   // match your preview (contain/cover)
  });

  final PoseFrame frame;
  final Color color;
  final double strokeWidth;
  final bool drawPoints;
  final bool mirror;
  final BoxFit fit;

  // Reusable buffer for edge pairs (A,B,A,B,...)
  final List<Offset> _linePts = <Offset>[];

  @override
  void paint(Canvas canvas, Size size) {
    final imgW = frame.imageSize.width;
    final imgH = frame.imageSize.height;
    if (imgW <= 0 || imgH <= 0) return;

    // Compute BoxFit transform (same criterio que rtc_pose_overlay)
    final scaleW = size.width / imgW;
    final scaleH = size.height / imgH;
    final s = (fit == BoxFit.cover)
        ? (scaleW > scaleH ? scaleW : scaleH)
        : (scaleW < scaleH ? scaleW : scaleH);

    final drawW = imgW * s;
    final drawH = imgH * s;
    final offX = (size.width - drawW) / 2.0;
    final offY = (size.height - drawH) / 2.0;

    // Paints (sin antialias para rendimiento)
    final line = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = false;

    final dot = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth + 1.0
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = false;

    canvas.save();
    if (mirror) {
      canvas.translate(size.width - offX, offY);
      canvas.scale(-s, s);
    } else {
      canvas.translate(offX, offY);
      canvas.scale(s, s);
    }

    final Float32List? packedPos = frame.packedPositions;
    final Int32List? packedRanges = frame.packedRanges;
    final bool hasPacked =
        packedPos != null && packedRanges != null && packedRanges.isNotEmpty;

    if (hasPacked) {
      for (int i = 0; i + 1 < packedRanges!.length; i += 2) {
        final int startPt = packedRanges[i];
        final int countPt = packedRanges[i + 1];
        if (countPt <= 0) continue;

        _linePts.clear();
        for (final e in kPoseConnections) {
          final int a = e[0], b = e[1];
          if (a >= countPt || b >= countPt) continue;
          final int idxA = (startPt + a) << 1;
          final int idxB = (startPt + b) << 1;
          if (idxA + 1 >= packedPos!.length || idxB + 1 >= packedPos.length) {
            continue;
          }
          final Offset pa = Offset(packedPos[idxA], packedPos[idxA + 1]);
          final Offset pb = Offset(packedPos[idxB], packedPos[idxB + 1]);
          _linePts..add(pa)..add(pb);
        }
        if (_linePts.isNotEmpty) {
          canvas.drawPoints(ui.PointMode.lines, _linePts, line);
        }

        if (drawPoints) {
          final int startF = startPt << 1;
          final int endF = startF + (countPt << 1);
          if (startF >= 0 && endF <= packedPos!.length) {
            final Float32List view =
                Float32List.sublistView(packedPos, startF, endF);
            canvas.drawRawPoints(ui.PointMode.points, view, dot);
          }
        }
      }
    } else {
      for (final pose in frame.posesPx ?? const <List<Offset>>[]) {
        if (pose.isEmpty) continue;

        _linePts.clear();
        for (final e in kPoseConnections) {
          final int a = e[0], b = e[1];
          if (a < pose.length && b < pose.length) {
            _linePts..add(pose[a])..add(pose[b]);
          }
        }
        if (_linePts.isNotEmpty) {
          canvas.drawPoints(ui.PointMode.lines, _linePts, line);
        }

        if (drawPoints) {
          canvas.drawPoints(ui.PointMode.points, pose, dot);
        }
      }
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant SkeletonPainter old) =>
      old.frame != frame ||
      old.color != color ||
      old.strokeWidth != strokeWidth ||
      old.drawPoints != drawPoints ||
      old.mirror != mirror ||
      old.fit != fit;
}

/// ───────────────────────── Overlay widget ─────────────────────────
class PoseSkeletonOverlay extends StatelessWidget {
  const PoseSkeletonOverlay({
    super.key,
    required this.data, // PoseFrame? (null => nothing to draw)
    this.color,         // ⬅️ ahora opcional: si no lo pasas, usa la paleta
    this.strokeWidth = 2.0,
    this.drawPoints = true,
    this.mirror = false,
    this.fit = BoxFit.contain,
  });

  final PoseFrame? data;
  final Color? color;
  final double strokeWidth;
  final bool drawPoints;
  final bool mirror;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    if (data == null) return const SizedBox.shrink();

    // Color por defecto desde la paleta:
    // 1) intenta usar CaptureTheme.faceOval (si está registrado)
    // 2) si no, cae a colorScheme.primary
    final scheme = Theme.of(context).colorScheme;
    final capture = Theme.of(context).extension<CaptureTheme>();
    final resolved = color ?? capture?.faceOval ?? scheme.primary;

    return CustomPaint(
      painter: SkeletonPainter(
        frame: data!,
        color: resolved,
        strokeWidth: strokeWidth,
        drawPoints: drawPoints,
        mirror: mirror,
        fit: fit,
      ),
      size: Size.infinite, // ocupa todo el overlay
      isComplex: true,
      willChange: true,
    );
  }
}
