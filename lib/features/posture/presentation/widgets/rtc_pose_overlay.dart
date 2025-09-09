// lib/features/posture/presentation/widgets/rtc_pose_overlay.dart
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show ValueListenable; // <- add this
import '../../infrastructure/model/pose_frame.dart' show PoseFrame;

/// Classic overlay that takes a concrete PoseFrame (e.g., from a StreamBuilder).
class PoseOverlay extends StatelessWidget {
  const PoseOverlay({
    super.key,
    required this.frame,
    this.mirror = false,
    this.fit = BoxFit.contain,
  });

  final PoseFrame? frame;
  final bool mirror;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _PoseOverlayPainter(frame, mirror: mirror, fit: fit),
      size: Size.infinite,
      isComplex: true,
      willChange: true,
    );
  }
}

class _PoseOverlayPainter extends CustomPainter {
  _PoseOverlayPainter(this.frame, {required this.mirror, required this.fit});
  final PoseFrame? frame;
  final bool mirror;
  final BoxFit fit;

  @override
  void paint(Canvas canvas, Size size) {
    final f = frame;
    if (f == null) return;

    final fw = f.imageSize.width.toDouble();
    final fh = f.imageSize.height.toDouble();
    if (fw <= 0 || fh <= 0) return;

    final scaleW = size.width / fw;
    final scaleH = size.height / fh;

    // contain => min; cover => max
    final s = (fit == BoxFit.cover)
        ? (scaleW > scaleH ? scaleW : scaleH)
        : (scaleW < scaleH ? scaleW : scaleH);

    final drawW = fw * s;
    final drawH = fh * s;
    final offX = (size.width - drawW) / 2.0;
    final offY = (size.height - drawH) / 2.0;

    final pt = Paint()
      ..style = PaintingStyle.fill
      ..color = Colors.limeAccent;
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..color = Colors.limeAccent;

    double mapX(double x) {
      final local = x * s + offX;
      return mirror ? (size.width - local) : local;
    }

    double mapY(double y) => y * s + offY;

    // Minimal skeleton edges (indices follow MediaPipe Pose)
    const L = {
      'ls': 11, 'rs': 12, 'le': 13, 're': 14,
      'lw': 15, 'rw': 16, 'lh': 23, 'rh': 24,
      'lk': 25, 'rk': 26, 'la': 27, 'ra': 28,
    };
    final edges = <List<int>>[
      [L['ls']!, L['rs']!],
      [L['ls']!, L['le']!], [L['le']!, L['lw']!],
      [L['rs']!, L['re']!], [L['re']!, L['rw']!],
      [L['lh']!, L['rh']!],
      [L['lh']!, L['lk']!], [L['lk']!, L['la']!],
      [L['rh']!, L['rk']!], [L['rk']!, L['ra']!],
    ];

    for (final pose in f.posesPx) {
      for (final e in edges) {
        if (pose.length <= e[0] || pose.length <= e[1]) continue;
        final a = pose[e[0]], b = pose[e[1]];
        canvas.drawLine(
          Offset(mapX(a.dx), mapY(a.dy)),
          Offset(mapX(b.dx), mapY(b.dy)),
          line,
        );
      }
      for (final lm in pose) {
        canvas.drawCircle(Offset(mapX(lm.dx), mapY(lm.dy)), 2.5, pt);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _PoseOverlayPainter old) =>
      old.frame != frame || old.mirror != mirror || old.fit != fit;
}

/// Fast overlay that listens to a ValueListenable<PoseFrame?> (preferred for low latency).
class PoseOverlayFast extends StatelessWidget {
  const PoseOverlayFast({
    super.key,
    required this.latest,
    this.mirror = false,
    this.fit = BoxFit.cover,
  });

  final ValueListenable<PoseFrame?> latest;
  final bool mirror;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _PoseOverlayFastPainter(latest, mirror: mirror, fit: fit),
      size: Size.infinite,
      isComplex: true,
      willChange: true,
    );
  }
}

class _PoseOverlayFastPainter extends CustomPainter {
  _PoseOverlayFastPainter(this.latest, {required this.mirror, required this.fit})
      : super(repaint: latest);

  final ValueListenable<PoseFrame?> latest;
  final bool mirror;
  final BoxFit fit;

  // Landmark indices (MediaPipe Pose)
  static const int LS = 11, RS = 12, LE = 13, RE = 14, LW = 15, RW = 16;
  static const int LH = 23, RH = 24, LK = 25, RK = 26, LA = 27, RA = 28;

  static const List<List<int>> _edges = [
    [LS, RS],
    [LS, LE], [LE, LW],
    [RS, RE], [RE, RW],
    [LH, RH],
    [LH, LK], [LK, LA],
    [RH, RK], [RK, RA],
  ];

  // Reusable buffers
  final Path _scratch = Path(); // (reservado por si alternas a Path)
  final List<Offset> _linePts = <Offset>[]; // pares A,B,A,B,...

  @override
  void paint(Canvas canvas, Size size) {
    final f = latest.value;
    if (f == null) return;

    final fw = f.imageSize.width.toDouble();
    final fh = f.imageSize.height.toDouble();
    if (fw <= 0 || fh <= 0) return;

    // Compute scale/offset once
    final scaleW = size.width / fw;
    final scaleH = size.height / fh;
    final s = (fit == BoxFit.cover)
        ? (scaleW > scaleH ? scaleW : scaleH)
        : (scaleW < scaleH ? scaleW : scaleH);

    final drawW = fw * s;
    final drawH = fh * s;
    final offX = (size.width - drawW) / 2.0;
    final offY = (size.height - drawH) / 2.0;

    // Configure paints (disable antialias for speed)
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = false
      ..color = Colors.limeAccent;

    final ptsPaint = Paint()
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke
      ..isAntiAlias = false
      ..color = Colors.limeAccent;

    canvas.save();
    // Apply transform: translate to box, scale to fit, mirror if needed
    if (mirror) {
      canvas.translate(size.width - offX, offY);
      canvas.scale(-s, s);
    } else {
      canvas.translate(offX, offY);
      canvas.scale(s, s);
    }

    // Batch draw per pose: one drawPoints for all edges + one drawPoints for all points
    for (final pose in f.posesPx) {
      if (pose.isEmpty) continue;

      _linePts.clear();
      for (final e in _edges) {
        if (pose.length <= e[0] || pose.length <= e[1]) continue;
        _linePts..add(pose[e[0]])..add(pose[e[1]]);
      }
      // One call for all edges
      if (_linePts.isNotEmpty) {
        canvas.drawPoints(PointMode.lines, _linePts, line);
      }

      // One call for all landmarks (round caps make them look like small circles)
      canvas.drawPoints(PointMode.points, pose, ptsPaint);
    }

    canvas.restore();
  }

  // Repaint is entirely driven by the ValueListenable in the constructor.
  @override
  bool shouldRepaint(covariant _PoseOverlayFastPainter old) => false;
}
