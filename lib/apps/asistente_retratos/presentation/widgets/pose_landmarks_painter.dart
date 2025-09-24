// lib/apps/asistente_retratos/presentation/widgets/pose_landmarks_painter.dart
import 'dart:typed_data' show Float32List;
import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' show BuildContext, Theme;
import '../../domain/model/lmk_state.dart';
import '../styles/colors.dart';

/// Conexiones del esqueleto (coinciden con PoseGeom.POSE_CONNECTIONS del servidor)
const List<List<int>> _POSE_EDGES = <List<int>>[
  [0,1],[1,2],[2,3],[3,7],[0,4],[4,5],[5,6],[6,8],[9,10],
  [11,12],[11,13],[13,15],[15,17],[15,19],[15,21],[17,19],
  [12,14],[14,16],[16,18],[16,20],[16,22],[18,20],[11,23],
  [12,24],[23,24],[23,25],[24,26],[25,27],[26,28],[27,29],
  [28,30],[29,31],[30,32],[27,31],[28,32],
];

/// Pintor optimizado SOLO para la ruta rápida (Float32List plano).
/// Reemplaza por completo la ruta legacy (List<Offset>) e incluye hold-last.
class PosePainter extends CustomPainter {
  final LmkState lmk;            // Debe contener pose en lmk.lastFlat
  final bool mirror;
  final Size? srcSize;           // Tamaño del frame (w,h) de origen
  final BoxFit fit;
  final bool showPoints;
  final bool showBones;
  final Color skeletonColor;
  final int _seqSnapshot;

  // Cache hold-last para ruta rápida (no copiamos buffers).
  List<Float32List>? _holdFlat;
  Size? _holdImgSize;
  DateTime _holdTs = DateTime.fromMillisecondsSinceEpoch(0);

  bool get _holdFresh =>
      DateTime.now().difference(_holdTs) < const Duration(milliseconds: 400);

  PosePainter(
    this.lmk, {
    this.mirror = false,
    this.srcSize,
    this.fit = BoxFit.cover,
    this.showPoints = true,
    this.showBones = true,
    this.skeletonColor = AppColors.landmarks, // o AppColors.pose si existe
  }) : _seqSnapshot = lmk.lastSeq;

  /// Variante que toma color desde el Theme (si tu CaptureTheme lo provee).
  static PosePainter themed(
    BuildContext context,
    LmkState lmk, {
    bool mirror = false,
    Size? srcSize,
    BoxFit fit = BoxFit.cover,
    bool showPoints = true,
    bool showBones = true,
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
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    // Datos actuales (solo ruta rápida)
    List<Float32List>? flats = lmk.lastFlat;

    // Tomamos el tamaño fuente si lo conoces; si no, asumimos el del lienzo.
    Size imgSize = srcSize ?? size;

    // Actualizar hold-last si llega data válida
    if (flats != null && flats.isNotEmpty && lmk.isFresh) {
      _holdFlat = flats;           // guardamos referencias, sin copiar
      _holdImgSize = imgSize;
      _holdTs = DateTime.now();
    }

    // Si no hay data actual, usar hold-last reciente
    if ((flats == null || flats.isEmpty) && _holdFresh) {
      flats = _holdFlat;
      imgSize = _holdImgSize ?? imgSize;
    }

    if (flats == null || flats.isEmpty || imgSize.width <= 0 || imgSize.height <= 0) {
      return;
    }

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

    // Pinceles “baratos”
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

    // Construimos Paths para minimizar draw calls
    final Path bones = Path();
    final Path dots  = Path();
    const double r = 2.5;

    for (final Float32List p in flats) {
      if (showBones) {
        final count = p.length >> 1;
        for (final e in _POSE_EDGES) {
          final a = e[0], b = e[1];
          if (a < count && b < count) {
            final i0 = a << 1;
            final i1 = b << 1;
            final ax = mapX(p[i0]);     final ay = mapY(p[i0 + 1]);
            final bx = mapX(p[i1]);     final by = mapY(p[i1 + 1]);
            bones.moveTo(ax, ay);
            bones.lineTo(bx, by);
          }
        }
      }
      if (showPoints) {
        for (int i = 0; i + 1 < p.length; i += 2) {
          final cx = mapX(p[i]); final cy = mapY(p[i + 1]);
          dots.addOval(Rect.fromCircle(center: Offset(cx, cy), radius: r));
        }
      }
    }

    if (showBones) canvas.drawPath(bones, bonePaint);
    if (showPoints) canvas.drawPath(dots, ptsPaint);
  }

  @override
  bool shouldRepaint(covariant PosePainter old) =>
      old._seqSnapshot != _seqSnapshot ||
      old.lmk != lmk ||                     // <- repinta cuando llega un LmkState nuevo
      old.mirror != mirror ||
      old.skeletonColor != skeletonColor ||
      old.srcSize != srcSize ||
      old.fit != fit ||
      old.showPoints != showPoints ||
      old.showBones != showBones;
}
