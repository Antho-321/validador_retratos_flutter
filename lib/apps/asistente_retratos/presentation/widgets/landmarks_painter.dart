// lib/.../landmarks_painter.dart
import 'dart:typed_data' show Float32List;
import 'dart:ui' as ui show PointMode;
import 'package:flutter/widgets.dart';

import '../../domain/model/lmk_state.dart';
import '../../infrastructure/services/pose_webrtc_service_imp.dart';

// ===== Pose "lite" (hombros–brazos y caderas–piernas) ======================
const int LS = 11, RS = 12, LE = 13, RE = 14, LW = 15, RW = 16;
const int LH = 23, RH = 24, LK = 25, RK = 26, LA = 27, RA = 28;

// Lista plana de índices (pares consecutivos forman segmentos)
const List<int> _POSE_EDGE_IDX = <int>[
  LS, RS,
  LS, LE,  LE, LW,
  RS, RE,  RE, RW,
  LH, RH,
  LH, LK,  LK, LA,
  RH, RK,  RK, RA,
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
          ..strokeCap = StrokeCap.round // cambia a .butt si te vale visualmente
          ..color = color ?? const Color(0xFFFFFFFF),
        _dots = Paint()
          ..style = PaintingStyle.stroke
          ..isAntiAlias = false
          ..strokeCap = StrokeCap.round // cambia a .butt si te vale
          ..color = color ?? const Color(0xFFFFFFFF),
        super(repaint: service.overlayTick) {
    _ensurePoseCapacity();
  }

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

  // ================== Cache y buffers reutilizables =========================
  // Pose (líneas)
  late final int _maxPoseLineFloats = (_POSE_EDGE_IDX.length ~/ 2) * 4; // x0,y0,x1,y1 por segmento
  Float32List _poseLineBuf = Float32List(0);
  int _poseLineFloats = 0;
  int _lastPoseSeq = -1;

  // Face (cruces y puntos)
  Float32List _faceCrossBuf = Float32List(0);
  int _faceCrossFloats = 0;
  double _lastCrossR = -1;
  int _lastFaceSeq = -1;

  Float32List _facePointBuf = Float32List(0);
  int _facePointFloats = 0;

  // Transform
  Size? _lastCanvasSize, _lastImgSize;
  bool? _lastMirror;
  BoxFit? _lastFit;
  double _scale = 1, _offX = 0, _offY = 0;

  // =========================== Transform ====================================
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

  // ============================ Pose helpers ================================
  void _ensurePoseCapacity() {
    if (_poseLineBuf.length < _maxPoseLineFloats) {
      _poseLineBuf = Float32List(_maxPoseLineFloats);
    }
  }

  // Llena _poseLineBuf desde pts (Float32List: x0,y0,x1,y1, ...).
  void _fillPoseLines(final Float32List pts, final int seq) {
    if (seq == _lastPoseSeq && _poseLineFloats != 0) return;

    _ensurePoseCapacity();
    final count = pts.length >> 1; // número de puntos (x,y)
    int k = 0;
    for (int e = 0; e < _POSE_EDGE_IDX.length; e += 2) {
      final int a = _POSE_EDGE_IDX[e];
      final int b = _POSE_EDGE_IDX[e + 1];
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

  // ============================ Face helpers ================================
  // Cruces de tamaño fijo en pantalla (r en px de pantalla, p.ej. 2/_scale)
  void _fillFaceCrosses(final List<Float32List> faces, final double r, final int faceSeq) {
    final bool needsUpdate = (faceSeq != _lastFaceSeq) || (_faceCrossFloats == 0) || (r != _lastCrossR);
    if (!needsUpdate) return;

    // 8 floats por landmark (dos segmentos por cruz)
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
    _lastCrossR = r;
  }

  // Empaqueta todos los puntos de todas las caras en un único buffer
  void _fillFacePoints(final List<Float32List> faces, final int faceSeq) {
    if (faceSeq == _lastFaceSeq && _facePointFloats != 0) return;

    int needed = 0;
    for (final f in faces) needed += f.length;
    if (_facePointBuf.length < needed) _facePointBuf = Float32List(needed);

    int k = 0;
    for (final f in faces) {
      _facePointBuf.setRange(k, k + f.length, f);
      k += f.length;
    }
    _facePointFloats = k;
    _lastFaceSeq = faceSeq;
  }

  // =============================== Paint ====================================
  @override
  void paint(Canvas c, Size size) {
    // Estados actuales (ideal: ya tipados en el modelo)
    final LmkState poseS = service.poseLmk.value;
    final LmkState faceS = service.faceLmk.value;

    // Tamaño fuente (frame → face → canvas)
    final Size imgSize = srcSize ?? poseS.imageSize ?? faceS.imageSize ?? size;
    if (imgSize.width <= 0 || imgSize.height <= 0) return;

    _updateTransform(size, imgSize);

    // Grosores ~constantes en pantalla
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
    final Float32List? poseFlat = _extractPoseFlat(poseS.lastFlat);
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
    final List<Float32List>? faces = _extractFaces(faceS.lastFlat);
    if (showFacePoints && faces != null && faces.isNotEmpty) {
      if (faceStyle == FaceStyle.points) {
        _fillFacePoints(faces, faceS.lastSeq);
        if (_facePointFloats > 0) {
          final view = Float32List.view(_facePointBuf.buffer, 0, _facePointFloats);
          c.drawRawPoints(ui.PointMode.points, view, _dots);
        }
      } else {
        final double r = 2.0 / _scale; // radio fijo en pantalla
        _fillFaceCrosses(faces, r, faceS.lastSeq);
        if (_faceCrossFloats > 0) {
          final view = Float32List.view(_faceCrossBuf.buffer, 0, _faceCrossFloats);
          c.drawRawPoints(ui.PointMode.lines, view, _line);
        }
      }
    }

    c.restore();
  }

  // =========================== Util casting ================================
  // Mantiene el branching fuera del path caliente del pintado principal.
  Float32List? _extractPoseFlat(Object? src) {
    if (src is Float32List) return src;
    if (src is List && src.isNotEmpty) {
      final first = src.first;
      if (first is Float32List) return first;
    }
    return null;
    // Ideal: que poseS.lastFlat ya sea Float32List? en el modelo/servicio.
  }

  List<Float32List>? _extractFaces(Object? src) {
    if (src is List<Float32List>) return src;
    if (src == null) return null;
    // Si llega en otro formato, evita allocs: no lo fuerces aquí.
    return const <Float32List>[];
    // Ideal: que faceS.lastFlat ya sea List<Float32List>? en el modelo/servicio.
  }

  // ============================ Repaint rule ===============================
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