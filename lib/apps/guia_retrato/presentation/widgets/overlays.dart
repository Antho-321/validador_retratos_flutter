// lib/apps/guia_retrato/presentation/widgets/overlays.dart
import 'package:flutter/material.dart';
import 'dart:ui' as ui show PointMode; // ⬅️ PointMode
import '../../infrastructure/model/pose_frame.dart' show PoseFrame; // ⬅️ ruta corregida

/// ───────────────────────── Existing widgets (unchanged) ─────────────────────────

class CircularMaskPainter extends CustomPainter {
  const CircularMaskPainter({required this.circleCenter, required this.circleRadius});
  final Offset circleCenter;
  final double circleRadius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.black.withOpacity(0.5);
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
  Widget build(BuildContext context) => IgnorePointer(
        child: Container(
          height: 140,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xCC000000), Colors.transparent],
            ),
          ),
        ),
      );
}

class ProgressRing extends StatelessWidget {
  const ProgressRing({super.key, required this.value, required this.color});
  final double value;
  final Color color;
  @override
  Widget build(BuildContext context) => SizedBox(
        width: 80,
        height: 80,
        child: Stack(
          alignment: Alignment.center,
          children: [
            CircularProgressIndicator(
              value: value,
              strokeWidth: 6,
              backgroundColor: Colors.white24,
              valueColor: AlwaysStoppedAnimation(color),
            ),
            Text(
              '${(value * 100).round()}%',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      );
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
    // Aplicar transform: letterbox + escala + espejo (si procede)
    if (mirror) {
      canvas.translate(size.width - offX, offY);
      canvas.scale(-s, s);
    } else {
      canvas.translate(offX, offY);
      canvas.scale(s, s);
    }

    for (final pose in frame.posesPx) {
      if (pose.isEmpty) continue;

      // Líneas: construir pares A,B… y dibujar en un batch
      _linePts.clear();
      for (final e in kPoseConnections) {
        final a = e[0], b = e[1];
        if (a < pose.length && b < pose.length) {
          _linePts..add(pose[a])..add(pose[b]);
        }
      }
      if (_linePts.isNotEmpty) {
        canvas.drawPoints(ui.PointMode.lines, _linePts, line);
      }

      // Puntos: un único batch
      if (drawPoints) {
        canvas.drawPoints(ui.PointMode.points, pose, dot);
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
    this.color = Colors.limeAccent,
    this.strokeWidth = 2.0,
    this.drawPoints = true,
    this.mirror = false,
    this.fit = BoxFit.contain,
  });

  final PoseFrame? data;
  final Color color;
  final double strokeWidth;
  final bool drawPoints;
  final bool mirror;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    if (data == null) return const SizedBox.shrink();
    return CustomPaint(
      painter: SkeletonPainter(
        frame: data!,
        color: color,
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
