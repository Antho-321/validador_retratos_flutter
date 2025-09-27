// lib/apps/asistente_retratos/presentation/widgets/rtc_pose_overlay.dart
import 'dart:typed_data' show Float32List, Int32List;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show ValueListenable, Listenable;

import '../../infrastructure/model/pose_frame.dart' show PoseFrame;
import '../../domain/model/lmk_state.dart' show LmkState;
import '../styles/colors.dart'; // AppColors & CaptureTheme

/// Overlay clásico que recibe un PoseFrame y DIBUJA SOLO la ruta rápida (flat).
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
    final cap = Theme.of(context).extension<CaptureTheme>();
    final landmarksColor = cap?.landmarks ?? AppColors.landmarks;

    return CustomPaint(
      painter: _PoseOverlayPainter(
        frame,
        mirror: mirror,
        fit: fit,
        landmarksColor: landmarksColor,
      ),
      size: Size.infinite,
      isComplex: true,
      willChange: true,
    );
  }
}

class _PoseOverlayPainter extends CustomPainter {
  _PoseOverlayPainter(
    this.frame, {
    required this.mirror,
    required this.fit,
    required this.landmarksColor,
  });

  final PoseFrame? frame;
  final bool mirror;
  final BoxFit fit;
  final Color landmarksColor;

  // MediaPipe Pose (índices)
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

  @override
  void paint(Canvas canvas, Size size) {
    final f = frame;
    if (f == null) return;

    final Float32List? packedPos = f.packedPositions;
    final Int32List? packedRanges = f.packedRanges;
    final bool hasPacked =
        packedPos != null && packedRanges != null && packedRanges.isNotEmpty;

    final flats = f.posesPxFlat;
    final posesPx = f.posesPx;
    if (!hasPacked && (flats == null || flats.isEmpty) &&
        (posesPx == null || posesPx.isEmpty)) {
      return; // nada que pintar
    }

    final fw = f.imageSize.width.toDouble();
    final fh = f.imageSize.height.toDouble();
    if (fw <= 0 || fh <= 0) return;

    final scaleW = size.width / fw;
    final scaleH = size.height / fh;
    final s = (fit == BoxFit.cover)
        ? (scaleW > scaleH ? scaleW : scaleH)
        : (scaleW < scaleH ? scaleW : scaleH);

    final drawW = fw * s;
    final drawH = fh * s;
    final offX = (size.width - drawW) / 2.0;
    final offY = (size.height - drawH) / 2.0;

    final pt = Paint()
      ..style = PaintingStyle.fill
      ..color = landmarksColor;

    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..color = landmarksColor;

    double mapX(double x) {
      final local = x * s + offX;
      return mirror ? (size.width - local) : local;
    }
    double mapY(double y) => y * s + offY;

    final Path bones = Path();
    final Path dots  = Path();
    const double r = 2.5;

    void paintPacked(Float32List positions, Int32List ranges) {
      for (int i = 0; i + 1 < ranges.length; i += 2) {
        final int startPt = ranges[i];
        final int countPt = ranges[i + 1];
        if (countPt <= 0) continue;

        if (showBones) {
          for (final e in _edges) {
            final int a = e[0], b = e[1];
            if (a >= countPt || b >= countPt) continue;
            final int idxA = (startPt + a) << 1;
            final int idxB = (startPt + b) << 1;
            if (idxA + 1 >= positions.length || idxB + 1 >= positions.length) {
              continue;
            }
            final double ax = mapX(positions[idxA]);
            final double ay = mapY(positions[idxA + 1]);
            final double bx = mapX(positions[idxB]);
            final double by = mapY(positions[idxB + 1]);
            bones.moveTo(ax, ay);
            bones.lineTo(bx, by);
          }
        }

        if (showPoints) {
          final int startF = startPt << 1;
          final int endF = startF + (countPt << 1);
          for (int idx = startF; idx + 1 < endF && idx + 1 < positions.length; idx += 2) {
            final double cx = mapX(positions[idx]);
            final double cy = mapY(positions[idx + 1]);
            dots.addOval(Rect.fromCircle(center: Offset(cx, cy), radius: r));
          }
        }
      }
    }

    if (hasPacked) {
      paintPacked(packedPos!, packedRanges!);
    } else if (flats != null && flats.isNotEmpty) {
      for (final Float32List p in flats) {
        if (showBones) {
          for (final e in _edges) {
            final i0 = e[0] * 2, i1 = e[1] * 2;
            if (p.length <= i0 + 1 || p.length <= i1 + 1) continue;
            final ax = mapX(p[i0]), ay = mapY(p[i0 + 1]);
            final bx = mapX(p[i1]), by = mapY(p[i1 + 1]);
            bones.moveTo(ax, ay);
            bones.lineTo(bx, by);
          }
        }
        if (showPoints) {
          for (int i = 0; i + 1 < p.length; i += 2) {
            final cx = mapX(p[i]), cy = mapY(p[i + 1]);
            dots.addOval(Rect.fromCircle(center: Offset(cx, cy), radius: r));
          }
        }
      }
    } else if (posesPx != null && posesPx.isNotEmpty) {
      for (final pose in posesPx) {
        if (showBones) {
          for (final e in _edges) {
            final int a = e[0], b = e[1];
            if (a >= pose.length || b >= pose.length) continue;
            final Offset pa = pose[a];
            final Offset pb = pose[b];
            bones.moveTo(mapX(pa.dx), mapY(pa.dy));
            bones.lineTo(mapX(pb.dx), mapY(pb.dy));
          }
        }
        if (showPoints) {
          for (final pt in pose) {
            final double cx = mapX(pt.dx);
            final double cy = mapY(pt.dy);
            dots.addOval(Rect.fromCircle(center: Offset(cx, cy), radius: r));
          }
        }
      }
    }

    canvas.drawPath(bones, line);
    canvas.drawPath(dots, pt);
  }

  @override
  bool shouldRepaint(covariant _PoseOverlayPainter old) =>
      old.frame != frame ||
      old.mirror != mirror ||
      old.fit != fit ||
      old.landmarksColor != landmarksColor;
}

/// Overlay rápido SOLO-flat con hold-last plano para evitar parpadeos.
/// Puede pintar también la cara (LmkState) si se pasa `face`.
class PoseOverlayFast extends StatefulWidget {
  const PoseOverlayFast({
    super.key,
    required this.latest,
    this.face,                  // opcional (cara)
    this.mirror = false,
    this.fit = BoxFit.cover,
    this.showPoints = true,
    this.showBones = true,
    this.showFace = false,
    this.useHoldLastForPose = true,
  });

  final ValueListenable<PoseFrame?> latest;
  final ValueListenable<LmkState>? face;
  final bool mirror;
  final BoxFit fit;
  final bool showPoints;
  final bool showBones;
  final bool showFace;
  final bool useHoldLastForPose;

  @override
  State<PoseOverlayFast> createState() => _PoseOverlayFastState();
}

class _PoseOverlayFastState extends State<PoseOverlayFast> {
  // Hold-last (pose) conservando el frame completo para reaprovechar buffers
  PoseFrame? _poseHoldFrame;
  DateTime _poseHoldTs = DateTime.fromMillisecondsSinceEpoch(0);

  bool get _poseHoldFresh =>
      DateTime.now().difference(_poseHoldTs) < const Duration(milliseconds: 400);

  bool _hasPoseData(PoseFrame? frame) {
    if (frame == null) return false;
    if (frame.packedPositions != null &&
        frame.packedRanges != null &&
        frame.packedRanges!.isNotEmpty) {
      return true;
    }
    if (frame.posesPxFlat != null && frame.posesPxFlat!.isNotEmpty) return true;
    if (frame.posesPx != null && frame.posesPx!.isNotEmpty) return true;
    return false;
  }

  @override
  void initState() {
    super.initState();
    widget.latest.addListener(_onPoseFrame);
  }

  @override
  void didUpdateWidget(covariant PoseOverlayFast oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.latest != widget.latest) {
      oldWidget.latest.removeListener(_onPoseFrame);
      widget.latest.addListener(_onPoseFrame);
      _onPoseFrame();
    }
  }

  void _onPoseFrame() {
    if (!widget.useHoldLastForPose) return;
    final f = widget.latest.value;
    if (_hasPoseData(f)) {
      _poseHoldFrame = f;
      _poseHoldTs = DateTime.now();
    }
  }

  @override
  void dispose() {
    widget.latest.removeListener(_onPoseFrame);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cap = Theme.of(context).extension<CaptureTheme>();
    final landmarksColor = cap?.landmarks ?? AppColors.landmarks;

    final repaint = widget.face == null
        ? widget.latest
        : Listenable.merge(<Listenable>[widget.latest, widget.face!]);

    return CustomPaint(
      painter: _PoseOverlayFastPainter(
        latest: widget.latest,
        mirror: widget.mirror,
        fit: widget.fit,
        showPoints: widget.showPoints,
        showBones: widget.showBones,
        showFace: widget.showFace,
        face: widget.face,
        useHoldLastForPose: widget.useHoldLastForPose,
        getPoseHoldFrame: () => _poseHoldFrame,
        isPoseHoldFresh: () => _poseHoldFresh,
        landmarksColor: landmarksColor,
      ),
      size: Size.infinite,
      isComplex: true,
      willChange: true,
      foregroundPainter: null,
    );
  }
}

class _PoseOverlayFastPainter extends CustomPainter {
  _PoseOverlayFastPainter({
    required this.latest,
    required this.mirror,
    required this.fit,
    required this.showPoints,
    required this.showBones,
    required this.showFace,
    required this.useHoldLastForPose,
    required this.getPoseHoldFrame,
    required this.isPoseHoldFresh,
    required this.landmarksColor,
    this.face,
  }) : super(
          repaint: face == null
              ? latest
              : Listenable.merge(<Listenable>[latest, face!]),
        );

  final ValueListenable<PoseFrame?> latest;
  final ValueListenable<LmkState>? face;
  final bool mirror;
  final BoxFit fit;
  final bool showPoints;
  final bool showBones;
  final bool showFace;
  final bool useHoldLastForPose;

  // Hold-last plano
  final PoseFrame? Function() getPoseHoldFrame;
  final bool Function() isPoseHoldFresh;

  final Color landmarksColor;

  // MediaPipe Pose (índices)
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

  bool _hasPoseData(PoseFrame? frame) {
    if (frame == null) return false;
    if (frame.packedPositions != null &&
        frame.packedRanges != null &&
        frame.packedRanges!.isNotEmpty) {
      return true;
    }
    if (frame.posesPxFlat != null && frame.posesPxFlat!.isNotEmpty) return true;
    if (frame.posesPx != null && frame.posesPx!.isNotEmpty) return true;
    return false;
  }

  @override
  void paint(Canvas canvas, Size size) {
    PoseFrame? frame = latest.value;
    if (!_hasPoseData(frame) && useHoldLastForPose && isPoseHoldFresh()) {
      frame = getPoseHoldFrame();
    }

    final LmkState? faceState = face?.value;

    Size? imgSize = frame?.imageSize;
    if ((imgSize == null || imgSize.width <= 0 || imgSize.height <= 0) &&
        faceState?.imageSize != null &&
        faceState!.imageSize!.width > 0 &&
        faceState.imageSize!.height > 0) {
      imgSize = faceState.imageSize;
    }

    if (imgSize == null || imgSize.width <= 0 || imgSize.height <= 0) {
      return;
    }

    final double fw = imgSize.width.toDouble();
    final double fh = imgSize.height.toDouble();
    if (fw <= 0 || fh <= 0) return;

    final double scaleW = size.width / fw;
    final double scaleH = size.height / fh;
    final double s = (fit == BoxFit.cover)
        ? (scaleW > scaleH ? scaleW : scaleH)
        : (scaleW < scaleH ? scaleW : scaleH);

    final double drawW = fw * s;
    final double drawH = fh * s;
    final double offX = (size.width - drawW) / 2.0;
    final double offY = (size.height - drawH) / 2.0;

    double mapX(double x) {
      final double local = x * s + offX;
      return mirror ? (size.width - local) : local;
    }

    double mapY(double y) => y * s + offY;

    final Paint bonePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = false
      ..color = landmarksColor;

    final Paint ptsPaint = Paint()
      ..style = PaintingStyle.fill
      ..isAntiAlias = false
      ..color = landmarksColor;

    final Paint facePaint = Paint()
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke
      ..isAntiAlias = false
      ..color = Colors.white;

    final Path bones = Path();
    final Path dots = Path();
    bool hasBonePath = false;
    bool hasDotPath = false;
    const double r = 2.5;

    if (frame != null) {
      final Float32List? packedPos = frame.packedPositions;
      final Int32List? packedRanges = frame.packedRanges;
      final bool hasPacked =
          packedPos != null && packedRanges != null && packedRanges.isNotEmpty;
      final List<Float32List>? flats = frame.posesPxFlat;
      final List<List<Offset>>? posesPx = frame.posesPx;

      if (hasPacked) {
        for (int i = 0; i + 1 < packedRanges!.length; i += 2) {
          final int startPt = packedRanges[i];
          final int countPt = packedRanges[i + 1];
          if (countPt <= 0) continue;

          if (showBones) {
            for (final e in _edges) {
              final int a = e[0], b = e[1];
              if (a >= countPt || b >= countPt) continue;
              final int idxA = (startPt + a) << 1;
              final int idxB = (startPt + b) << 1;
              if (idxA + 1 >= packedPos!.length ||
                  idxB + 1 >= packedPos.length) {
                continue;
              }
              final double ax = mapX(packedPos[idxA]);
              final double ay = mapY(packedPos[idxA + 1]);
              final double bx = mapX(packedPos[idxB]);
              final double by = mapY(packedPos[idxB + 1]);
              bones.moveTo(ax, ay);
              bones.lineTo(bx, by);
              hasBonePath = true;
            }
          }

          if (showPoints) {
            final int startF = startPt << 1;
            final int endF = startF + (countPt << 1);
            for (int idx = startF;
                idx + 1 < endF && idx + 1 < packedPos!.length;
                idx += 2) {
              final double cx = mapX(packedPos[idx]);
              final double cy = mapY(packedPos[idx + 1]);
              dots.addOval(Rect.fromCircle(center: Offset(cx, cy), radius: r));
              hasDotPath = true;
            }
          }
        }
      } else if (flats != null && flats.isNotEmpty) {
        for (final Float32List p in flats) {
          if (showBones) {
            for (final e in _edges) {
              final int i0 = e[0] * 2;
              final int i1 = e[1] * 2;
              if (p.length <= i0 + 1 || p.length <= i1 + 1) continue;
              final double ax = mapX(p[i0]);
              final double ay = mapY(p[i0 + 1]);
              final double bx = mapX(p[i1]);
              final double by = mapY(p[i1 + 1]);
              bones.moveTo(ax, ay);
              bones.lineTo(bx, by);
              hasBonePath = true;
            }
          }
          if (showPoints) {
            for (int i = 0; i + 1 < p.length; i += 2) {
              final double cx = mapX(p[i]);
              final double cy = mapY(p[i + 1]);
              dots.addOval(Rect.fromCircle(center: Offset(cx, cy), radius: r));
              hasDotPath = true;
            }
          }
        }
      } else if (posesPx != null && posesPx.isNotEmpty) {
        for (final pose in posesPx) {
          if (showBones) {
            for (final e in _edges) {
              final int a = e[0], b = e[1];
              if (a >= pose.length || b >= pose.length) continue;
              final Offset pa = pose[a];
              final Offset pb = pose[b];
              bones.moveTo(mapX(pa.dx), mapY(pa.dy));
              bones.lineTo(mapX(pb.dx), mapY(pb.dy));
              hasBonePath = true;
            }
          }
          if (showPoints) {
            for (final pt in pose) {
              dots.addOval(
                Rect.fromCircle(center: Offset(mapX(pt.dx), mapY(pt.dy)), radius: r),
              );
              hasDotPath = true;
            }
          }
        }
      }
    }

    if (showBones && hasBonePath) {
      canvas.drawPath(bones, bonePaint);
    }
    if (showPoints && hasDotPath) {
      canvas.drawPath(dots, ptsPaint);
    }

    if (showFace && faceState != null && faceState.isFresh) {
      final Float32List? facePackedPos = faceState.packedPositions;
      final Int32List? facePackedRanges = faceState.packedRanges;
      final bool hasFacePacked = facePackedPos != null &&
          facePackedRanges != null &&
          facePackedRanges.isNotEmpty;
      final List<List<Offset>>? facesLegacy = faceState.last;
      final List<Float32List>? facesFlat = faceState.lastFlat;

      const double faceR = 3.0;

      if (hasFacePacked) {
        for (int i = 0; i + 1 < facePackedRanges!.length; i += 2) {
          final int startPt = facePackedRanges[i];
          final int countPt = facePackedRanges[i + 1];
          final int startF = startPt << 1;
          final int endF = startF + (countPt << 1);
          for (int idx = startF;
              idx + 1 < endF && idx + 1 < facePackedPos!.length;
              idx += 2) {
            final double cx = mapX(facePackedPos[idx]);
            final double cy = mapY(facePackedPos[idx + 1]);
            canvas.drawCircle(Offset(cx, cy), faceR, facePaint);
          }
        }
      } else if (facesFlat != null && facesFlat.isNotEmpty) {
        for (final fFlat in facesFlat) {
          for (int i = 0; i + 1 < fFlat.length; i += 2) {
            final double cx = mapX(fFlat[i]);
            final double cy = mapY(fFlat[i + 1]);
            canvas.drawCircle(Offset(cx, cy), faceR, facePaint);
          }
        }
      } else if (facesLegacy != null && facesLegacy.isNotEmpty) {
        for (final pts in facesLegacy) {
          for (final pt in pts) {
            canvas.drawCircle(Offset(mapX(pt.dx), mapY(pt.dy)), faceR, facePaint);
          }
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _PoseOverlayFastPainter old) =>
      old.mirror != mirror ||
      old.fit != fit ||
      old.showPoints != showPoints ||
      old.showBones != showBones ||
      old.showFace != showFace ||
      old.useHoldLastForPose != useHoldLastForPose ||
      old.latest != latest ||
      old.face != face ||
      old.landmarksColor != landmarksColor;
}
