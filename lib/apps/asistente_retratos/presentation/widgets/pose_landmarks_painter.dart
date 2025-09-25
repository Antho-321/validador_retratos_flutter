// lib/apps/asistente_retratos/presentation/widgets/pose_landmarks_painter.dart
import 'dart:typed_data' show Float32List;
import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' show BuildContext, Theme;
import 'package:flutter/foundation.dart' show ValueListenable;
import '../../domain/model/lmk_state.dart';
import '../styles/colors.dart';

/// Subconjunto “lite” de MediaPipe Pose (hombros–brazos y caderas–piernas).
const int LS = 11, RS = 12, LE = 13, RE = 14, LW = 15, RW = 16;
const int LH = 23, RH = 24, LK = 25, RK = 26, LA = 27, RA = 28;

const List<List<int>> _POSE_EDGES = <List<int>>[
  [LS, RS],
  [LS, LE], [LE, LW],
  [RS, RE], [RE, RW],
  [LH, RH],
  [LH, LK], [LK, LA],
  [RH, RK], [RK, RA],
];

/// ─────────────────────────────────────────────────────────────────────────
/// Overlay con hold-last en el State y hints al engine.
/// Se engancha al ValueListenable<LmkState> que trae datos de pose.
class PoseOverlayFast extends StatefulWidget {
  const PoseOverlayFast({
    super.key,
    required this.listenable,        // p.ej. poseService.poseLandmarks
    this.mirror = false,
    this.srcSize,                    // si lo conoces: tamaño frame origen
    this.fit = BoxFit.cover,
    this.showPoints = true,
    this.showBones = true,
    this.skeletonColor,              // si null, toma de Theme/AppColors
  });

  final ValueListenable<LmkState> listenable;
  final bool mirror;
  final Size? srcSize;
  final BoxFit fit;
  final bool showPoints;
  final bool showBones;
  final Color? skeletonColor;

  @override
  State<PoseOverlayFast> createState() => _PoseOverlayFastState();
}

class _PoseOverlayFastState extends State<PoseOverlayFast> {
  // Snapshot que realmente pintaremos (con hold-last ya aplicado).
  late LmkState _toPaint;

  // Parámetros del hold-last
  List<Float32List>? _holdFlat;
  Size? _holdImgSize; // ← mantener tamaño de imagen del frame
  DateTime _holdTs = DateTime.fromMillisecondsSinceEpoch(0);

  bool get _holdFresh =>
      DateTime.now().difference(_holdTs) < const Duration(milliseconds: 400);

  void _onData() {
    final v = widget.listenable.value;

    // Si llega data válida y fresca, refrescamos el hold
    if (v.lastFlat != null && v.lastFlat!.isNotEmpty && v.isFresh) {
      _holdFlat = v.lastFlat;
      _holdTs   = v.lastTs ?? _holdTs;                 // evitar null
      _holdImgSize = v.imageSize ?? _holdImgSize;      // guardar imageSize
    }

    // Construimos el snapshot a pintar: actual o hold-last
    final flats = (v.lastFlat != null && v.lastFlat!.isNotEmpty && v.isFresh)
        ? v.lastFlat
        : (_holdFresh ? _holdFlat : null);

    _toPaint = LmkState(
      last: null,
      lastFlat: flats,
      imageSize: (v.imageSize ?? _holdImgSize),        // ← pasar imageSize
      lastSeq: v.lastSeq,
      lastTs:  _holdFresh ? _holdTs : (v.lastTs ?? _holdTs),
    );

    // Necesitamos rebuild para pasar el nuevo snapshot al painter
    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _toPaint = widget.listenable.value;

    // Iniciar hold si ya hay algo
    if (_toPaint.lastFlat != null && _toPaint.lastFlat!.isNotEmpty) {
      _holdFlat = _toPaint.lastFlat;
      _holdTs   = _toPaint.lastTs ?? _holdTs;
      _holdImgSize = _toPaint.imageSize;               // inicializa si ya vino
    }

    widget.listenable.addListener(_onData);
  }

  @override
  void didUpdateWidget(covariant PoseOverlayFast oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.listenable, widget.listenable)) {
      oldWidget.listenable.removeListener(_onData);
      widget.listenable.addListener(_onData);
      _onData();
    }
  }

  @override
  void dispose() {
    widget.listenable.removeListener(_onData);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cap = Theme.of(context).extension<CaptureTheme>();
    final color = widget.skeletonColor ?? cap?.landmarks ?? AppColors.landmarks;

    return CustomPaint(
      isComplex: true,     // hint: paths complejos
      willChange: true,    // hint: cambia con frecuencia
      painter: PosePainter(
        _toPaint,
        mirror: widget.mirror,
        srcSize: widget.srcSize,
        fit: widget.fit,
        showPoints: widget.showPoints,
        showBones: widget.showBones,
        skeletonColor: color,
        // repintar cuando el listenable cambie
        repaint: widget.listenable,
      ),
    );
  }
}

/// ─────────────────────────────────────────────────────────────────────────
/// Pintor optimizado SOLO para la ruta rápida (Float32List plano).
/// Sin hold-last (ahora vive en el State). Repinta vía `repaint`.
class PosePainter extends CustomPainter {
  PosePainter(
    this.lmk, {
    this.mirror = false,
    this.srcSize,
    this.fit = BoxFit.cover,
    this.showPoints = true,
    this.showBones = true,
    this.skeletonColor = AppColors.landmarks,
    Listenable? repaint,
  }) : super(repaint: repaint);

  final LmkState lmk;            // Debe traer pose en lmk.lastFlat (px)
  final bool mirror;
  final Size? srcSize;           // Tamaño del frame (w,h) de origen
  final BoxFit fit;
  final bool showPoints;
  final bool showBones;
  final Color skeletonColor;

  @override
  void paint(Canvas canvas, Size size) {
    final flats = lmk.lastFlat;
    if (flats == null || flats.isEmpty) return;

    // Usa el tamaño fuente del State si está, luego srcSize, y por último el lienzo.
    final Size imgSize = srcSize ?? lmk.imageSize ?? size; // ← clave para evitar corrimientos
    if (imgSize.width <= 0 || imgSize.height <= 0) return;

    final fw = imgSize.width.toDouble();
    final fh = imgSize.height.toDouble();

    // Escalado tipo BoxFit
    final scaleW = size.width / fw;
    final scaleH = size.height / fh;
    final s = (fit == BoxFit.cover)
        ? (scaleW > scaleH ? scaleW : scaleH)
        : (scaleW < scaleH ? scaleW : scaleH);

    final drawW = fw * s;
    final drawH = fh * s;
    final offX = (size.width - drawW) / 2.0;
    final offY = (size.height - drawH) / 2.0;

    final Paint bonePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = false
      ..color = skeletonColor;

    final Paint ptsPaint = Paint()
      ..style = PaintingStyle.fill
      ..isAntiAlias = false
      ..color = skeletonColor;

    double mapX(double x) {
      final local = x * s + offX;
      return mirror ? (size.width - local) : local;
    }
    double mapY(double y) => y * s + offY;

    final Path bones = Path();
    final Path dots = Path();
    const double r = 2.5;

    for (final Float32List p in flats) {
      if (showBones) {
        final count = p.length >> 1;
        for (final e in _POSE_EDGES) {
          final a = e[0], b = e[1];
          if (a < count && b < count) {
            final i0 = a << 1, i1 = b << 1;
            final double axRaw = p[i0];
            final double ayRaw = p[i0 + 1];
            final double bxRaw = p[i1];
            final double byRaw = p[i1 + 1];
            if (!axRaw.isFinite || !ayRaw.isFinite ||
                !bxRaw.isFinite || !byRaw.isFinite) {
              continue;
            }
            final ax = mapX(axRaw);
            final ay = mapY(ayRaw);
            final bx = mapX(bxRaw);
            final by = mapY(byRaw);
            bones.moveTo(ax, ay);
            bones.lineTo(bx, by);
          }
        }
      }
      if (showPoints) {
        for (int i = 0; i + 1 < p.length; i += 2) {
          final double xRaw = p[i];
          final double yRaw = p[i + 1];
          if (!xRaw.isFinite || !yRaw.isFinite) continue;
          final cx = mapX(xRaw); final cy = mapY(yRaw);
          dots.addOval(Rect.fromCircle(center: Offset(cx, cy), radius: r));
        }
      }
    }

    if (showBones) canvas.drawPath(bones, bonePaint);
    if (showPoints) canvas.drawPath(dots, ptsPaint);
  }

  @override
  bool shouldRepaint(covariant PosePainter old) {
    // El repintado por datos lo gestiona `repaint` (Listenable).
    // Aquí solo repintamos por cambios de configuración/estilo.
    return old.mirror != mirror ||
        old.skeletonColor != skeletonColor ||
        old.srcSize != srcSize ||
        old.fit != fit ||
        old.showPoints != showPoints ||
        old.showBones != showBones;
  }

  /// Variante “temable” (opcional).
  static PosePainter themed(
    BuildContext context,
    LmkState lmk, {
    bool mirror = false,
    Size? srcSize,
    BoxFit fit = BoxFit.cover,
    bool showPoints = true,
    bool showBones = true,
    Listenable? repaint,
  }) {
    final cap = Theme.of(context).extension<CaptureTheme>();
    final color = cap?.landmarks ?? AppColors.landmarks;
    return PosePainter(
      lmk,
      mirror: mirror,
      srcSize: srcSize,
      fit: fit,
      showPoints: showPoints,
      showBones: showBones,
      skeletonColor: color,
      repaint: repaint,
    );
  }
}
