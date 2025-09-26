// lib/apps/asistente_retratos/presentation/widgets/pose_landmarks_painter.dart
import 'dart:typed_data' show Float32List;
import 'dart:ui' as ui show PointMode; // ← for ui.PointMode
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

/// Overlay de pose que NO hace rebuild por frame; el painter escucha cambios.
class PoseOverlayFast extends StatelessWidget {
  const PoseOverlayFast({
    super.key,
    required this.listenable,
    this.mirror = false,
    this.srcSize,
    this.fit = BoxFit.cover,
    this.showPoints = true,
    this.showBones = true,
    this.skeletonColor,
  });

  final ValueListenable<LmkState> listenable;
  final bool mirror;
  final Size? srcSize;
  final BoxFit fit;
  final bool showPoints;
  final bool showBones;
  final Color? skeletonColor;

  @override
  Widget build(BuildContext context) {
    final cap = Theme.of(context).extension<CaptureTheme>();
    final color = skeletonColor ?? cap?.landmarks ?? AppColors.landmarks;

    return RepaintBoundary(
      child: CustomPaint(
        painter: _PosePainterFast(
          listenable: listenable,
          mirror: mirror,
          srcSize: srcSize,
          fit: fit,
          showPoints: showPoints,
          showBones: showBones,
          color: color,
        ),
      ),
    );
  }
}

/// Painter optimizado: hold-last interno, buffers reutilizables y drawRawPoints.
class _PosePainterFast extends CustomPainter {
  _PosePainterFast({
    required this.listenable,
    required this.mirror,
    required this.srcSize,
    required this.fit,
    required this.showPoints,
    required this.showBones,
    required this.color,
  })  : _bonePaint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..isAntiAlias = false
          ..color = color,
        _ptPaint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..isAntiAlias = false
          ..color = color,
        super(repaint: listenable);

  final ValueListenable<LmkState> listenable;
  final bool mirror;
  final Size? srcSize;
  final BoxFit fit;
  final bool showPoints;
  final bool showBones;
  final Color color;

  final Paint _bonePaint;
  final Paint _ptPaint;

  // ── Hold-last cache ─────────────────────────────────────────────────────
  List<Float32List>? _holdFlat;
  Size? _holdImgSize;
  DateTime _holdTs = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _freshWindow = Duration(milliseconds: 400);

  // ── Buffers reutilizables ───────────────────────────────────────────────
  Float32List _lineBuf = Float32List(0);
  int _lineFloatCount = 0;

  Float32List _ptBuf = Float32List(0);
  int _ptFloatCount = 0;

  // Cache de transformaciones
  Size? _lastCanvasSize;
  Size? _lastImgSize;
  bool? _lastMirror;
  BoxFit? _lastFit;
  double _scale = 1.0, _offX = 0.0, _offY = 0.0;

  @override
  void paint(Canvas c, Size size) {
    final v = listenable.value;
    final now = DateTime.now();

    // Actualiza hold-last si hay datos frescos válidos
    if (v.lastFlat != null && v.lastFlat!.isNotEmpty && v.isFresh) {
      _holdFlat = v.lastFlat;
      _holdImgSize = v.imageSize ?? _holdImgSize;
      _holdTs = v.lastTs ?? _holdTs; // ← nullable-safe
    }

    // Selección de datos (nuevo vs hold-last)
    final bool holdFresh = now.difference(_holdTs) < _freshWindow;
    final List<Float32List>? flats = (v.lastFlat != null &&
            v.lastFlat!.isNotEmpty &&
            v.isFresh)
        ? v.lastFlat
        : (holdFresh ? _holdFlat : null);

    if (flats == null || flats.isEmpty) return;

    // Tamaño fuente
    final Size imgSize = srcSize ?? v.imageSize ?? _holdImgSize ?? size;
    if (imgSize.width <= 0 || imgSize.height <= 0) return;

    // Transform
    if (_lastCanvasSize != size ||
        _lastImgSize != imgSize ||
        _lastMirror != mirror ||
        _lastFit != fit) {
      final sw = imgSize.width, sh = imgSize.height;
      final scaleW = size.width / sw;
      final scaleH = size.height / sh;
      _scale = (fit == BoxFit.cover)
          ? ((scaleW > scaleH) ? scaleW : scaleH)
          : ((scaleW < scaleH) ? scaleW : scaleH);
      _offX = (size.width - sw * _scale) / 2.0;
      _offY = (size.height - sh * _scale) / 2.0;

      _lastCanvasSize = size;
      _lastImgSize = imgSize;
      _lastMirror = mirror;
      _lastFit = fit;
    }

    _bonePaint
      ..color = color
      ..strokeWidth = 2.0 / _scale;
    _ptPaint
      ..color = color
      ..strokeWidth = 5.0 / _scale; // diámetro ~5 px

    c.save();
    c.translate(_offX, _offY);
    if (mirror) {
      c.translate(imgSize.width * _scale, 0);
      c.scale(-_scale, _scale);
    } else {
      c.scale(_scale, _scale);
    }

    // ── LÍNEAS (huesos) ───────────────────────────────────────────────────
    if (showBones) {
      int segments = 0;
      for (final p in flats) {
        final count = p.length >> 1;
        for (final e in _POSE_EDGES) {
          if (e[0] < count && e[1] < count) segments++;
        }
      }
      final neededLineFloats = segments * 4; // (x0,y0,x1,y1)
      if (_lineBuf.length < neededLineFloats) {
        _lineBuf = Float32List(neededLineFloats);
      }

      int k = 0;
      for (final p in flats) {
        final count = p.length >> 1;
        for (final e in _POSE_EDGES) {
          final a = e[0], b = e[1];
          if (a < count && b < count) {
            final i0 = a << 1, i1 = b << 1;
            _lineBuf[k++] = p[i0];
            _lineBuf[k++] = p[i0 + 1];
            _lineBuf[k++] = p[i1];
            _lineBuf[k++] = p[i1 + 1];
          }
        }
      }
      _lineFloatCount = k;

      if (_lineFloatCount > 0) {
        final linesToDraw = (_lineBuf.length == _lineFloatCount)
            ? _lineBuf
            : Float32List.view(_lineBuf.buffer, 0, _lineFloatCount);
        c.drawRawPoints(ui.PointMode.lines, linesToDraw, _bonePaint);
      }
    } else {
      _lineFloatCount = 0;
    }

    // ── PUNTOS (articulaciones) ───────────────────────────────────────────
    if (showPoints) {
      int totalPts = 0;
      for (final p in flats) {
        totalPts += (p.length >> 1);
      }
      final neededPtFloats = totalPts * 2; // (x,y)
      if (_ptBuf.length < neededPtFloats) {
        _ptBuf = Float32List(neededPtFloats);
      }

      int k = 0;
      for (final p in flats) {
        for (int i = 0; i + 1 < p.length; i += 2) {
          _ptBuf[k++] = p[i];
          _ptBuf[k++] = p[i + 1];
        }
      }
      _ptFloatCount = k;

      if (_ptFloatCount > 0) {
        final ptsToDraw = (_ptBuf.length == _ptFloatCount)
            ? _ptBuf
            : Float32List.view(_ptBuf.buffer, 0, _ptFloatCount);
        c.drawRawPoints(ui.PointMode.points, ptsToDraw, _ptPaint);
      }
    } else {
      _ptFloatCount = 0;
    }

    c.restore();
  }

  @override
  bool shouldRepaint(covariant _PosePainterFast old) {
    return old.mirror != mirror ||
        old.color != color ||
        old.srcSize != srcSize ||
        old.fit != fit ||
        old.showPoints != showPoints ||
        old.showBones != showBones ||
        !identical(old.listenable, listenable);
  }

  static _PosePainterFast themed(
    BuildContext context, {
    required ValueListenable<LmkState> listenable,
    bool mirror = false,
    Size? srcSize,
    BoxFit fit = BoxFit.cover,
    bool showPoints = true,
    bool showBones = true,
  }) {
    final cap = Theme.of(context).extension<CaptureTheme>();
    final color = cap?.landmarks ?? AppColors.landmarks;
    return _PosePainterFast(
      listenable: listenable,
      mirror: mirror,
      srcSize: srcSize,
      fit: fit,
      showPoints: showPoints,
      showBones: showBones,
      color: color,
    );
  }
}