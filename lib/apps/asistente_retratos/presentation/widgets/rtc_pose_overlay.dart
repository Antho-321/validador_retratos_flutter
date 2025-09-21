// lib/apps/asistente_retratos/presentation/widgets/rtc_pose_overlay.dart
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show ValueListenable, Listenable;

import '../../infrastructure/model/pose_frame.dart' show PoseFrame;
import '../../domain/model/lmk_state.dart' show LmkState;
import '../styles/colors.dart'; // AppColors & CaptureTheme

/// Overlay clásico que recibe un PoseFrame concreto.
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
    // Toma el color desde el tema si existe; si no, usa el alias de la paleta.
    final cap = Theme.of(context).extension<CaptureTheme>();
    final landmarksColor = cap?.landmarks ?? AppColors.landmarks;

    return CustomPaint(
      painter: _PoseOverlayPainter(
        frame,
        mirror: mirror,
        fit: fit,
        landmarksColor: landmarksColor, // ⬅️ nuevo
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
    required this.landmarksColor, // ⬅️ nuevo
  });

  final PoseFrame? frame;
  final bool mirror;
  final BoxFit fit;
  final Color landmarksColor; // ⬅️ nuevo

  @override
  void paint(Canvas canvas, Size size) {
    final f = frame;
    if (f == null) return;

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
      ..color = landmarksColor; // ← reemplaza limeAccent

    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..color = landmarksColor; // ← reemplaza limeAccent

    double mapX(double x) {
      final local = x * s + offX;
      return mirror ? (size.width - local) : local;
    }

    double mapY(double y) => y * s + offY;

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
      old.frame != frame ||
      old.mirror != mirror ||
      old.fit != fit ||
      old.landmarksColor != landmarksColor; // ⬅️ compara el color
}

/// Overlay rápido: pinta pose y, opcionalmente, landmarks de cara (LmkState).
/// Incluye HOLD-LAST para POSE usando un LmkState interno para evitar parpadeos.
class PoseOverlayFast extends StatefulWidget {
  const PoseOverlayFast({
    super.key,
    required this.latest,
    this.face,                 // opcional (cara)
    this.mirror = false,
    this.fit = BoxFit.cover,
    this.showPoints = true,
    this.showBones = true,
    this.showFace = false,     // por defecto no dibuja la cara
    this.useHoldLastForPose = true, // ⬅️ evita parpadeo de pose cuando hay frames vacíos
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
  // Cache “hold-last” para pose (2D)
  final LmkState _poseHold = LmkState();

  @override
  void initState() {
    super.initState();
    // Mantén actualizado el hold-last con el último frame NO vacío.
    widget.latest.addListener(_onPoseFrame);
  }

  @override
  void didUpdateWidget(covariant PoseOverlayFast oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.latest != widget.latest) {
      oldWidget.latest.removeListener(_onPoseFrame);
      widget.latest.addListener(_onPoseFrame);
      // refresca el cache con el valor actual del nuevo listenable
      _onPoseFrame();
    }
  }

  void _onPoseFrame() {
    if (!widget.useHoldLastForPose) return;
    final f = widget.latest.value;
    if (f == null) return;

    // Si el frame trae landmarks válidos, actualiza el hold-last
    if (f.posesPx.isNotEmpty && f.posesPx.first.isNotEmpty) {
      _poseHold
        ..last = f.posesPx
        ..lastSeq = _poseHold.lastSeq + 1   // cascada con asignación
        ..lastTs = DateTime.now();
      // No hace falta setState; el repintado lo dispara 'latest'
    }
  }

  @override
  void dispose() {
    widget.latest.removeListener(_onPoseFrame);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Toma el color desde el tema si existe; si no, usa el alias de la paleta.
    final cap = Theme.of(context).extension<CaptureTheme>();
    final landmarksColor = cap?.landmarks ?? AppColors.landmarks;

    // Listenables que deben gatillar repaints (pose y opcionalmente cara)
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
        // getters hacia el cache hold-last; el painter los consulta en cada paint
        getPoseHold: () => _poseHold,
        useHoldLastForPose: widget.useHoldLastForPose,
        landmarksColor: landmarksColor, // ⬅️ nuevo
      ),
      size: Size.infinite,
      isComplex: true,
      willChange: true,
      // El repaint real lo controla el painter con `repaint: ...`
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
    required this.getPoseHold,
    required this.landmarksColor, // ⬅️ nuevo
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

  // Proveedor del cache hold-last (vive en el State, persiste entre rebuilds)
  final LmkState Function() getPoseHold;

  // Color para landmarks/huesos/puntos
  final Color landmarksColor; // ⬅️ nuevo

  // Huesos (MediaPipe Pose)
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

  final List<Offset> _linePts = <Offset>[];

  @override
  void paint(Canvas canvas, Size size) {
    final f = latest.value;

    // Decide qué landmarks de pose usar: actuales o “hold-last”
    List<List<Offset>>? poses;
    Size imgSize = const Size(0, 0);

    if (f != null) {
      imgSize = Size(f.imageSize.width.toDouble(), f.imageSize.height.toDouble());
      if (f.posesPx.isNotEmpty && f.posesPx.first.isNotEmpty) {
        poses = f.posesPx;
      }
    }

    if (poses == null && useHoldLastForPose) {
      final hold = getPoseHold();
      if (hold.last != null && hold.isFresh) {
        poses = hold.last;
        // cuando usamos hold-last, asumimos mismo sistema de coords del frame
      }
    }

    if (poses == null || imgSize.width <= 0 || imgSize.height <= 0) return;

    // Escalado/offset como antes
    final fw = imgSize.width;
    final fh = imgSize.height;
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
      ..color = landmarksColor; // ← reemplaza limeAccent

    final ptsPaint = Paint()
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke
      ..isAntiAlias = false
      ..color = landmarksColor; // ← reemplaza limeAccent

    final facePaint = Paint()
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke
      ..isAntiAlias = false
      ..color = Colors.white;

    canvas.save();
    if (mirror) {
      canvas.translate(size.width - offX, offY);
      canvas.scale(-s, s);
    } else {
      canvas.translate(offX, offY);
      canvas.scale(s, s);
    }

    // 1) Pose
    for (final pose in poses) {
      if (pose.isEmpty) continue;

      if (showBones) {
        _linePts.clear();
        for (final e in _edges) {
          if (pose.length <= e[0] || pose.length <= e[1]) continue;
          _linePts..add(pose[e[0]])..add(pose[e[1]]);
        }
        if (_linePts.isNotEmpty) {
          canvas.drawPoints(PointMode.lines, _linePts, bonePaint);
        }
      }
      if (showPoints) {
        canvas.drawPoints(PointMode.points, pose, ptsPaint);
      }
    }

    // 2) Cara (opcional)
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
      old.landmarksColor != landmarksColor; // ⬅️ compara el color
}
