// lib/apps/asistente_retratos/presentation/widgets/face_landmarks_painter.dart
import 'dart:typed_data' show Float32List;
import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' show BuildContext, Theme;
import 'package:flutter/foundation.dart' show ValueListenable;

import '../../domain/model/lmk_state.dart';
import '../styles/colors.dart';

/// ─────────────────────────────────────────────────────────────────────────
/// Overlay de cara con hold-last en el State + repaint con Listenable.
/// Se engancha a un ValueListenable<LmkState> (ej: poseService.faceLandmarks).
class FaceOverlayFast extends StatefulWidget {
  const FaceOverlayFast({
    super.key,
    required this.listenable,
    this.mirror = false,
    this.srcSize, // si lo conoces (w,h) del frame fuente
    this.landmarksColor,
  });

  final ValueListenable<LmkState> listenable;
  final bool mirror;
  final Size? srcSize;
  final Color? landmarksColor;

  @override
  State<FaceOverlayFast> createState() => _FaceOverlayFastState();
}

class _FaceOverlayFastState extends State<FaceOverlayFast> {
  late LmkState _toPaint;

  // Hold-last (solo ruta plana)
  List<Float32List>? _holdFlat;
  Size? _holdImgSize;
  DateTime _holdTs = DateTime.fromMillisecondsSinceEpoch(0);

  bool get _holdFresh =>
      DateTime.now().difference(_holdTs) < const Duration(milliseconds: 400);

  void _onData() {
    final v = widget.listenable.value;

    if (v.lastFlat != null && v.lastFlat!.isNotEmpty && v.isFresh) {
      _holdFlat = v.lastFlat;
      _holdTs = v.lastTs ?? _holdTs;
      _holdImgSize = v.imageSize ?? _holdImgSize;
    }

    final flats = (v.lastFlat != null && v.lastFlat!.isNotEmpty && v.isFresh)
        ? v.lastFlat
        : (_holdFresh ? _holdFlat : null);

    _toPaint = LmkState(
      last: null,
      lastFlat: flats,
      imageSize: v.imageSize ?? _holdImgSize,
      lastSeq: v.lastSeq,
      lastTs: _holdFresh ? _holdTs : (v.lastTs ?? _holdTs),
    );

    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _toPaint = widget.listenable.value;

    if (_toPaint.lastFlat != null && _toPaint.lastFlat!.isNotEmpty) {
      _holdFlat = _toPaint.lastFlat;
      _holdTs = _toPaint.lastTs ?? _holdTs;
      _holdImgSize = _toPaint.imageSize;
    }

    widget.listenable.addListener(_onData);
  }

  @override
  void didUpdateWidget(covariant FaceOverlayFast oldWidget) {
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
    final color = widget.landmarksColor ?? cap?.landmarks ?? AppColors.landmarks;

    return CustomPaint(
      isComplex: true,
      willChange: true,
      painter: FacePainter(
        _toPaint,
        mirror: widget.mirror,
        srcSize: widget.srcSize,
        landmarksColor: color,
        repaint: widget.listenable, // repinta solo con nuevos datos
      ),
    );
  }
}

/// ─────────────────────────────────────────────────────────────────────────
/// Painter de cara: solo ruta rápida (Float32List plano). Sin hold-last.
class FacePainter extends CustomPainter {
  FacePainter(
    this.lmk, {
    this.mirror = false,
    this.srcSize,
    this.landmarksColor = AppColors.landmarks,
    Listenable? repaint,
  })  : _paint = Paint()
          ..color = landmarksColor
          ..style = PaintingStyle.stroke
          ..isAntiAlias = false
          ..strokeCap = StrokeCap.round,
        super(repaint: repaint);

  final LmkState lmk;
  final bool mirror;
  final Size? srcSize; // frame (w,h) de origen
  final Color landmarksColor;

  // Reused paint (evita alloc por frame)
  final Paint _paint;

  // Reused path (evita alloc por frame)
  final Path _path = Path();

  static FacePainter themed(
    BuildContext context,
    LmkState lmk, {
    bool mirror = false,
    Size? srcSize,
    Listenable? repaint,
  }) {
    final cap = Theme.of(context).extension<CaptureTheme>();
    final color = cap?.landmarks ?? AppColors.landmarks;
    return FacePainter(
      lmk,
      mirror: mirror,
      srcSize: srcSize,
      landmarksColor: color,
      repaint: repaint,
    );
  }

  @override
  void paint(Canvas c, Size size) {
    final flats = lmk.lastFlat;
    if (flats == null || flats.isEmpty) return;

    // Tamaño fuente en el que están expresados los puntos
    final Size imgSize = srcSize ?? lmk.imageSize ?? size;
    final sw = imgSize.width, sh = imgSize.height;
    if (sw <= 0 || sh <= 0) return;

    // BoxFit.cover transform (scale + center)
    final scaleW = size.width / sw;
    final scaleH = size.height / sh;
    final scale = (scaleW > scaleH) ? scaleW : scaleH;
    final offX = (size.width - sw * scale) / 2.0;
    final offY = (size.height - sh * scale) / 2.0;

    c.save();
    c.translate(offX, offY);
    if (mirror) {
      c.translate(sw * scale, 0);
      c.scale(-scale, scale);
    } else {
      c.scale(scale, scale);
    }

    // grosor ≈ 4px en pantalla (independiente del zoom)
    _paint
      ..color = landmarksColor
      ..strokeWidth = 4.0 / scale;

    // Cruces pequeñas por landmark (dos segmentos por punto)
    _path.reset();
    const double r = 2.0;

    for (final Float32List f in flats) {
      for (int i = 0; i + 1 < f.length; i += 2) {
        final double x = f[i];
        final double y = f[i + 1];
        _path
          ..moveTo(x - r, y)
          ..lineTo(x + r, y)
          ..moveTo(x, y - r)
          ..lineTo(x, y + r);
      }
    }

    c.drawPath(_path, _paint);
    c.restore();
  }

  @override
  bool shouldRepaint(covariant FacePainter old) {
    // Los cambios de datos se propagan vía `repaint`.
    // Aquí solo por cambios de estilo/parámetros.
    return old.mirror != mirror ||
        old.landmarksColor != landmarksColor ||
        old.srcSize != srcSize;
  }
}