// lib/apps/asistente_retratos/presentation/widgets/rtc_pose_overlay.dart
import 'dart:typed_data' show Float32List;
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

    final flats = f.posesPxFlat;
    if (flats == null || flats.isEmpty) return; // SOLO ruta rápida

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

    for (final Float32List p in flats) {
      // Huesos
      for (final e in _edges) {
        final i0 = e[0] * 2, i1 = e[1] * 2;
        if (p.length <= i0 + 1 || p.length <= i1 + 1) continue;
        final double axRaw = p[i0], ayRaw = p[i0 + 1];
        final double bxRaw = p[i1], byRaw = p[i1 + 1];
        if (!axRaw.isFinite || !ayRaw.isFinite ||
            !bxRaw.isFinite || !byRaw.isFinite) {
          continue;
        }
        final ax = mapX(axRaw), ay = mapY(ayRaw);
        final bx = mapX(bxRaw), by = mapY(byRaw);
        bones.moveTo(ax, ay);
        bones.lineTo(bx, by);
      }
      // Puntos
      for (int i = 0; i + 1 < p.length; i += 2) {
        final double cxRaw = p[i], cyRaw = p[i + 1];
        if (!cxRaw.isFinite || !cyRaw.isFinite) continue;
        final cx = mapX(cxRaw), cy = mapY(cyRaw);
        dots.addOval(Rect.fromCircle(center: Offset(cx, cy), radius: r));
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
  // Hold-last PLANO (solo para pose)
  List<Float32List>? _poseHoldFlat;
  DateTime _poseHoldTs = DateTime.fromMillisecondsSinceEpoch(0);

  bool get _poseHoldFresh =>
      DateTime.now().difference(_poseHoldTs) < const Duration(milliseconds: 400);

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
    if (f == null) return;

    final flats = f.posesPxFlat;
    if (flats != null && flats.isNotEmpty) {
      // Guardamos la referencia (evitar copiar para ser RT)
      _poseHoldFlat = flats;
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
        getPoseHoldFlat: () => _poseHoldFlat,
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
    required this.getPoseHoldFlat,
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
  final List<Float32List>? Function() getPoseHoldFlat;
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

  @override
  void paint(Canvas canvas, Size size) {
    final f = latest.value;

    // Elegir flats actuales o hold-last
    List<Float32List>? flats = f?.posesPxFlat;
    Size imgSize = f?.imageSize ?? const Size(0, 0);

    if ((flats == null || flats.isEmpty) && useHoldLastForPose && isPoseHoldFresh()) {
      flats = getPoseHoldFlat();
      // imgSize asumimos el mismo del último válido; si necesitas exactitud,
      // también puedes cachear el Size en el State.
    }

    if (flats == null || flats.isEmpty || imgSize.width <= 0 || imgSize.height <= 0) {
      return;
    }

    final fw = imgSize.width.toDouble();
    final fh = imgSize.height.toDouble();

    final scaleW = size.width / fw;
    final scaleH = size.height / fh;
    final s = (fit == BoxFit.cover)
        ? (scaleW > scaleH ? scaleW : scaleH)
        : (scaleW < scaleH ? scaleW : scaleH);

    final drawW = fw * s;
    final drawH = fh * s;
    final offX = (size.width - drawW) / 2.0;
    final offY = (size.height - drawH) / 2.0;

    final bonePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = false
      ..color = landmarksColor;

    final ptsPaint = Paint()
      ..style = PaintingStyle.fill
      ..isAntiAlias = false
      ..color = landmarksColor;

    final facePaint = Paint()
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke
      ..isAntiAlias = false
      ..color = Colors.white;

    double mapX(double x) {
      final local = x * s + offX;
      return mirror ? (size.width - local) : local;
    }
    double mapY(double y) => y * s + offY;

    canvas.save();
    // (el mapeo ya contempla el mirror al calcular mapX)
    // Si prefieres matriz de espejo completa, podrías usar translate+scale.

    // 1) Pose SOLO-flat
    final Path bones = Path();
    final Path dots  = Path();
    const double r = 2.5;

    for (final Float32List p in flats) {
      if (showBones) {
        for (final e in _edges) {
          final i0 = e[0] * 2, i1 = e[1] * 2;
          if (p.length <= i0 + 1 || p.length <= i1 + 1) continue;
          final double axRaw = p[i0], ayRaw = p[i0 + 1];
          final double bxRaw = p[i1], byRaw = p[i1 + 1];
          if (!axRaw.isFinite || !ayRaw.isFinite ||
              !bxRaw.isFinite || !byRaw.isFinite) {
            continue;
          }
          final ax = mapX(axRaw), ay = mapY(ayRaw);
          final bx = mapX(bxRaw), by = mapY(byRaw);
          bones.moveTo(ax, ay);
          bones.lineTo(bx, by);
        }
      }
      if (showPoints) {
        for (int i = 0; i + 1 < p.length; i += 2) {
          final double cxRaw = p[i], cyRaw = p[i + 1];
          if (!cxRaw.isFinite || !cyRaw.isFinite) continue;
          final cx = mapX(cxRaw), cy = mapY(cyRaw);
          dots.addOval(Rect.fromCircle(center: Offset(cx, cy), radius: r));
        }
      }
    }
    if (showBones) canvas.drawPath(bones, bonePaint);
    if (showPoints) canvas.drawPath(dots, ptsPaint);

    // 2) Cara (opcional) — sigue usando LmkState (Offsets)
    if (showFace && face != null) {
      final lmk = face!.value;
      final faces = lmk.last;
      if (faces != null && lmk.isFresh) {
        for (final pts in faces) {
          if (pts.isEmpty) continue;
          canvas.drawPoints(PointMode.points, pts, facePaint);
        }
      }
    }

    canvas.restore();
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
