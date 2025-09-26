// lib/.../landmarks_painter.dart
import 'dart:typed_data' show Float32List;
import 'dart:ui' as ui show PointMode;
import 'package:flutter/widgets.dart';

import '../../domain/model/lmk_state.dart';
import '../../infrastructure/services/pose_webrtc_service_imp.dart';

// ===== Pose "lite" (hombros–brazos y caderas–piernas) ======================
const int LS = 11, RS = 12, LE = 13, RE = 14, LW = 15, RW = 16;
const int LH = 23, RH = 24, LK = 25, RK = 26, LA = 27, RA = 28;

const List<List<int>> _POSE_EDGES = [
  [LS, RS],
  [LS, LE], [LE, LW],
  [RS, RE], [RE, RW],
  [LH, RH],
  [LH, LK], [LK, LA],
  [RH, RK], [RK, RA],
];

enum FaceStyle { cross, points }

class LandmarksPainter extends CustomPainter {
  LandmarksPainter(
    this.service, {
    this.mirror = false,
    this.srcSize,
    this.fit = BoxFit.cover,
    this.showPoseBones = true,
    this.showPosePoints = true,
    this.showFacePoints = true,
    this.faceStyle = FaceStyle.cross,
    Color? color,
  })  : _line = Paint()
          ..style = PaintingStyle.stroke
          ..isAntiAlias = false
          ..strokeCap = StrokeCap.round
          ..color = color ?? const Color(0xFFFFFFFF),
        _dots = Paint()
          ..style = PaintingStyle.stroke
          ..isAntiAlias = false
          ..strokeCap = StrokeCap.round
          ..color = color ?? const Color(0xFFFFFFFF),
        super(repaint: service.overlayTick);

  // Fuente de datos
  final PoseWebrtcServiceImp service;

  // Opciones de presentación
  final bool mirror;
  final Size? srcSize;          // tamaño nativo del frame si lo conoces
  final BoxFit fit;             // cover/contain
  final bool showPoseBones;
  final bool showPosePoints;
  final bool showFacePoints;
  final FaceStyle faceStyle;

  // Pinturas reutilizables
  final Paint _line;
  final Paint _dots;

  // Cache y buffers reutilizables
  // Pose
  final List<List<int>> _edges = _POSE_EDGES;
  Float32List _poseLineBuf = Float32List(0);
  int _poseLineFloats = 0;
  int _lastPoseSeq = -1;

  // Face
  Float32List _faceCrossBuf = Float32List(0); // para cruces
  int _faceCrossFloats = 0;
  int _lastFaceSeq = -1;

  // Transform
  Size? _lastCanvasSize, _lastImgSize;
  bool? _lastMirror;
  BoxFit? _lastFit;
  double _scale = 1, _offX = 0, _offY = 0;

  // Util: prepara transform según fit/espacio
  void _updateTransform(Size canvas, Size img) {
    if (_lastCanvasSize == canvas &&
        _lastImgSize == img &&
        _lastMirror == mirror &&
        _lastFit == fit) return;

    final sw = img.width, sh = img.height;
    final sx = canvas.width / sw;
    final sy = canvas.height / sh;
    _scale = (fit == BoxFit.cover) ? (sx > sy ? sx : sy) : (sx < sy ? sx : sy);
    _offX = (canvas.width - sw * _scale) / 2.0;
    _offY = (canvas.height - sh * _scale) / 2.0;

    _lastCanvasSize = canvas;
    _lastImgSize = img;
    _lastMirror = mirror;
    _lastFit = fit;
  }

  // ====== Pose helpers ======================================================

  // Llena _poseLineBuf a partir de un Float32List de puntos (x,y normalizados o en px).
  void _fillPoseLines(final Float32List pts, final int seq) {
    if (seq == _lastPoseSeq) return;

    final count = pts.length >> 1;
    // Cuenta segmentos válidos
    int segs = 0;
    for (final e in _edges) {
      final a = e[0], b = e[1];
      if (a < count && b < count) segs++;
    }
    final needed = segs * 4; // x0,y0,x1,y1
    if (_poseLineBuf.length < needed) _poseLineBuf = Float32List(needed);

    int k = 0;
    for (final e in _edges) {
      final a = e[0], b = e[1];
      if (a < count && b < count) {
        final i0 = a << 1, i1 = b << 1;
        _poseLineBuf[k++] = pts[i0];
        _poseLineBuf[k++] = pts[i0 + 1];
        _poseLineBuf[k++] = pts[i1];
        _poseLineBuf[k++] = pts[i1 + 1];
      }
    }
    _poseLineFloats = k;
    _lastPoseSeq = seq;
  }

  // ====== Face helpers ======================================================

  // Genera cruces de tamaño fijo en pantalla (2 px de radio)
  void _fillFaceCrosses(final List<Float32List> faces, final double r, final int faceSeq) {
    if (faceSeq == _lastFaceSeq && _faceCrossFloats > 0) return;

    // Calcula floats requeridos (8 por landmark)
    int floats = 0;
    for (final f in faces) floats += (f.length >> 1) * 8;
    if (_faceCrossBuf.length < floats) _faceCrossBuf = Float32List(floats);

    int k = 0;
    for (final f in faces) {
      for (int i = 0; i + 1 < f.length; i += 2) {
        final x = f[i], y = f[i + 1];
        // horiz
        _faceCrossBuf[k++] = x - r; _faceCrossBuf[k++] = y;
        _faceCrossBuf[k++] = x + r; _faceCrossBuf[k++] = y;
        // vert
        _faceCrossBuf[k++] = x;     _faceCrossBuf[k++] = y - r;
        _faceCrossBuf[k++] = x;     _faceCrossBuf[k++] = y + r;
      }
    }
    _faceCrossFloats = k;
    _lastFaceSeq = faceSeq;
  }

  @override
  void paint(Canvas c, Size size) {
    // Lee estados actuales (o “hold” si tu LmkState ya lo maneja internamente)
    final LmkState poseS = service.poseLmk.value;
    final LmkState faceS = service.faceLmk.value;

    // Determina el tamaño fuente (usa el del frame si viene, o el canvas)
    final Size imgSize = srcSize ?? poseS.imageSize ?? faceS.imageSize ?? size;
    if (imgSize.width <= 0 || imgSize.height <= 0) return;

    _updateTransform(size, imgSize);

    // Ajusta grosores aprox. fijos en pantalla
    _line.strokeWidth = 2.0 / _scale;
    _dots.strokeWidth = 4.0 / _scale;

    c.save();
    c.translate(_offX, _offY);
    if (mirror) {
      c.translate(imgSize.width * _scale, 0);
      c.scale(-_scale, _scale);
    } else {
      c.scale(_scale, _scale);
    }

    // ================= POSE =================
    // Asumimos que poseS.lastFlat es un Float32List? con un solo esqueleto.
    // Si en tu implementación es List<Float32List>, toma el primero.
    final Float32List? poseFlat = (poseS.lastFlat is Float32List)
        ? (poseS.lastFlat as Float32List?)
        : (poseS.lastFlat is List && (poseS.lastFlat as List).isNotEmpty
            ? (poseS.lastFlat as List).first as Float32List
            : null);

    if (poseFlat != null) {
      _fillPoseLines(poseFlat, poseS.lastSeq);
      if (showPoseBones && _poseLineFloats > 0) {
        final view = Float32List.view(_poseLineBuf.buffer, 0, _poseLineFloats);
        c.drawRawPoints(ui.PointMode.lines, view, _line);
      }
      if (showPosePoints) {
        c.drawRawPoints(ui.PointMode.points, poseFlat, _dots);
      }
    }

    // ================= FACE =================
    // Múltiples caras: esperamos List<Float32List> en faceS.lastFlat
    final List<Float32List>? faces = (faceS.lastFlat is List<Float32List>)
        ? faceS.lastFlat as List<Float32List>
        : (faceS.lastFlat == null ? null : <Float32List>[]);

    if (showFacePoints && faces != null && faces.isNotEmpty) {
      if (faceStyle == FaceStyle.points) {
        // Dibuja cada set de puntos directamente
        for (final f in faces) {
          c.drawRawPoints(ui.PointMode.points, f, _dots);
        }
      } else {
        // Cruces pequeñas por landmark (radio fijo en pantalla)
        final double r = 2.0 / _scale;
        _fillFaceCrosses(faces, r, faceS.lastSeq);
        if (_faceCrossFloats > 0) {
          final view = Float32List.view(_faceCrossBuf.buffer, 0, _faceCrossFloats);
          c.drawRawPoints(ui.PointMode.lines, view, _line);
        }
      }
    }

    c.restore();
  }

  @override
  bool shouldRepaint(covariant LandmarksPainter old) {
    return old.mirror != mirror ||
        old.srcSize != srcSize ||
        old.fit != fit ||
        old.showPoseBones != showPoseBones ||
        old.showPosePoints != showPosePoints ||
        old.showFacePoints != showFacePoints ||
        old.faceStyle != faceStyle ||
        !identical(old.service, service);
  }
}