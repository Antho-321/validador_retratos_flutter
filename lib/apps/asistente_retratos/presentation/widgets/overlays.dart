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

  Float32List _lineBuf = Float32List(0);
  Float32List _pointBuf = Float32List(0);
  Float32List _scratch = Float32List(0);
  int _lineFloats = 0;
  int _pointFloats = 0;
  final Map<int, Float32List> _lineViews = <int, Float32List>{};
  final Map<int, Float32List> _pointViews = <int, Float32List>{};

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
    final double strokeScale = s <= 0 ? 1.0 : (1.0 / s);

    final line = Paint()
      ..color = color
      ..strokeWidth = strokeWidth * strokeScale
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = false;

    final dot = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = (strokeWidth + 1.0) * strokeScale
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

    _resetBuffers();

    final Float32List? packedPos = frame.packedPositions;
    final Int32List? packedRanges = frame.packedRanges;
    final bool hasPacked =
        packedPos != null && packedRanges != null && packedRanges.isNotEmpty;

    if (hasPacked) {
      for (int i = 0; i + 1 < packedRanges!.length; i += 2) {
        _appendPacked(packedPos!, packedRanges[i], packedRanges[i + 1],
            includePoints: drawPoints);
      }
    } else if (frame.posesPxFlat != null && frame.posesPxFlat!.isNotEmpty) {
      for (final Float32List flat in frame.posesPxFlat!) {
        _appendFlat(flat, includePoints: drawPoints);
      }
    } else {
      for (final pose in frame.posesPx ?? const <List<Offset>>[]) {
        _appendOffsets(pose, includePoints: drawPoints);
      }
    }

    final Float32List? lineView = _lineView();
    if (lineView != null) {
      canvas.drawRawPoints(ui.PointMode.lines, lineView, line);
    }

    if (drawPoints) {
      final Float32List? pointView = _pointView();
      if (pointView != null) {
        canvas.drawRawPoints(ui.PointMode.points, pointView, dot);
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

  void _resetBuffers() {
    _lineFloats = 0;
    _pointFloats = 0;
  }

  void _ensureLineCapacity(int floats) {
    if (_lineBuf.length >= floats) return;
    _lineBuf = Float32List(floats);
    _lineViews.clear();
  }

  void _ensurePointCapacity(int floats) {
    if (_pointBuf.length >= floats) return;
    _pointBuf = Float32List(floats);
    _pointViews.clear();
  }

  Float32List _ensureScratch(int floats) {
    if (_scratch.length >= floats) return _scratch;
    _scratch = Float32List(floats);
    return _scratch;
  }

  void _appendPacked(
    Float32List src,
    int startPt,
    int countPt, {
    required bool includePoints,
  }) {
    if (countPt <= 0) return;
    final int startF = startPt << 1;
    if (startF >= src.length) return;
    int endF = startF + (countPt << 1);
    if (endF > src.length) endF = src.length;
    final int floats = endF - startF;
    if (floats <= 0) return;
    final int availablePts = floats >> 1;
    if (availablePts <= 0) return;

    _ensureLineCapacity(_lineFloats + kPoseConnections.length * 4);
    for (final conn in kPoseConnections) {
      final int a = conn[0], b = conn[1];
      if (a >= availablePts || b >= availablePts) continue;
      final int idxA = startF + (a << 1);
      final int idxB = startF + (b << 1);
      if (idxA + 1 >= endF || idxB + 1 >= endF) continue;
      _lineBuf[_lineFloats++] = src[idxA];
      _lineBuf[_lineFloats++] = src[idxA + 1];
      _lineBuf[_lineFloats++] = src[idxB];
      _lineBuf[_lineFloats++] = src[idxB + 1];
    }

    if (includePoints) {
      _ensurePointCapacity(_pointFloats + floats);
      _pointBuf.setRange(_pointFloats, _pointFloats + floats, src, startF);
      _pointFloats += floats;
    }
  }

  void _appendFlat(Float32List flat, {required bool includePoints}) {
    if (flat.isEmpty) return;
    _appendPacked(flat, 0, flat.length >> 1, includePoints: includePoints);
  }

  void _appendOffsets(List<Offset> pose, {required bool includePoints}) {
    if (pose.isEmpty) return;
    final int floats = pose.length << 1;
    final Float32List scratch = _ensureScratch(floats);
    int k = 0;
    for (final Offset pt in pose) {
      scratch[k++] = pt.dx;
      scratch[k++] = pt.dy;
    }
    _appendPacked(scratch, 0, pose.length, includePoints: includePoints);
  }

  Float32List? _lineView() {
    if (_lineFloats == 0) return null;
    return _lineViews[_lineFloats] ??=
        Float32List.view(_lineBuf.buffer, 0, _lineFloats);
  }

  Float32List? _pointView() {
    if (_pointFloats == 0) return null;
    return _pointViews[_pointFloats] ??=
        Float32List.view(_pointBuf.buffer, 0, _pointFloats);
  }
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
