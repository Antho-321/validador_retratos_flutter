// lib/apps/asistente_retratos/presentation/widgets/rtc_pose_overlay.dart
import 'dart:typed_data' show Float32List, Int32List;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show ValueListenable, Listenable, debugPrint, kDebugMode;

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

const List<int> _kPoseEdgeIdx = <int>[
  11, 12,
  11, 13, 13, 15,
  12, 14, 14, 16,
  23, 24,
  23, 25, 25, 27,
  24, 26, 26, 28,
];

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

  static const bool _showBones = true;
  static const bool _showPoints = true;

  final _PoseBufferSet _poseBuffers = _PoseBufferSet(_kPoseEdgeIdx);

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

    final double strokeScale = s <= 0 ? 1.0 : (1.0 / s);

    final Paint pt = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 5.0 * strokeScale
      ..color = landmarksColor
      ..isAntiAlias = false;

    final Paint line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0 * strokeScale
      ..strokeCap = StrokeCap.round
      ..color = landmarksColor
      ..isAntiAlias = false;

    _poseBuffers.reset();

    void paintPacked(Float32List positions, Int32List ranges) {
      for (int i = 0; i + 1 < ranges.length; i += 2) {
        final int startPt = ranges[i];
        final int countPt = ranges[i + 1];
        _poseBuffers.appendPacked(
          positions,
          startPt,
          countPt,
          addPoints: _showPoints,
          addLines: _showBones,
        );
      }
    }

    if (hasPacked) {
      paintPacked(packedPos!, packedRanges!);
    } else if (flats != null && flats.isNotEmpty) {
      for (final Float32List p in flats) {
        _poseBuffers.appendFlat(
          p,
          addPoints: _showPoints,
          addLines: _showBones,
        );
      }
    } else if (posesPx != null && posesPx.isNotEmpty) {
      for (final pose in posesPx) {
        _poseBuffers.appendOffsets(
          pose,
          addPoints: _showPoints,
          addLines: _showBones,
        );
      }
    }

    canvas.save();
    if (mirror) {
      canvas.translate(size.width - offX, offY);
      canvas.scale(-s, s);
    } else {
      canvas.translate(offX, offY);
      canvas.scale(s, s);
    }

    final Float32List? lineView = _showBones ? _poseBuffers.linesView() : null;
    if (lineView != null) {
      canvas.drawRawPoints(PointMode.lines, lineView, line);
    }

    final Float32List? pointView = _showPoints ? _poseBuffers.pointsView() : null;
    if (pointView != null) {
      canvas.drawRawPoints(PointMode.points, pointView, pt);
    }

    canvas.restore();
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

  Duration _poseHoldAge() => DateTime.now().difference(_poseHoldTs);

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
    final prevHold = _poseHoldFrame;
    if (_hasPoseData(f)) {
      _poseHoldFrame = f;
      _poseHoldTs = DateTime.now();
      if (kDebugMode) {
        final packed = f?.packedPositions?.length ?? 0;
        final flats = f?.posesPxFlat?.length ?? 0;
        debugPrint(
          '[PoseOverlayFast] new hold frame stored (packed=$packed, flats=$flats)',
        );
      }
    }
    if (kDebugMode && !_hasPoseData(f) && prevHold != null) {
      final ageMs = _poseHoldAge().inMilliseconds;
      debugPrint(
        '[PoseOverlayFast] live frame without pose data; hold age=${ageMs}ms (fresh=${_poseHoldFresh})',
      );
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
        poseHoldAge: _poseHoldAge,
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
    this.poseHoldAge,
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
  final Duration Function()? poseHoldAge;

  final Color landmarksColor;

  final _PoseBufferSet _poseBuffers = _PoseBufferSet(_kPoseEdgeIdx);
  final _PointBuffer _facePoints = _PointBuffer();

  bool _lastUsedHold = false;

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
    bool usedHold = false;
    if (!_hasPoseData(frame) && useHoldLastForPose && isPoseHoldFresh()) {
      frame = getPoseHoldFrame();
      usedHold = frame != null;
    }

    if (kDebugMode && usedHold != _lastUsedHold) {
      final age = poseHoldAge?.call();
      final ageMs = age?.inMilliseconds;
      debugPrint('[PoseOverlayFast] ${usedHold ? 'reusing hold frame' : 'using live frame'}'
          '${usedHold && ageMs != null ? ' (age=${ageMs}ms)' : ''}');
      _lastUsedHold = usedHold;
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

    final double strokeScale = s <= 0 ? 1.0 : (1.0 / s);

    final Paint bonePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0 * strokeScale
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = false
      ..color = landmarksColor;

    final Paint ptsPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 5.0 * strokeScale
      ..isAntiAlias = false
      ..color = landmarksColor;

    final Paint facePaint = Paint()
      ..strokeWidth = 6.0 * strokeScale
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke
      ..isAntiAlias = false
      ..color = Colors.white;

    _poseBuffers.reset();

    if (frame != null) {
      final Float32List? packedPos = frame.packedPositions;
      final Int32List? packedRanges = frame.packedRanges;
      final bool hasPacked =
          packedPos != null && packedRanges != null && packedRanges.isNotEmpty;
      final List<Float32List>? flats = frame.posesPxFlat;
      final List<List<Offset>>? posesPx = frame.posesPx;

      if (hasPacked) {
        for (int i = 0; i + 1 < packedRanges!.length; i += 2) {
          _poseBuffers.appendPacked(
            packedPos!,
            packedRanges[i],
            packedRanges[i + 1],
            addPoints: showPoints,
            addLines: showBones,
          );
        }
      } else if (flats != null && flats.isNotEmpty) {
        for (final Float32List p in flats) {
          _poseBuffers.appendFlat(
            p,
            addPoints: showPoints,
            addLines: showBones,
          );
        }
      } else if (posesPx != null && posesPx.isNotEmpty) {
        for (final pose in posesPx) {
          _poseBuffers.appendOffsets(
            pose,
            addPoints: showPoints,
            addLines: showBones,
          );
        }
      }
    }

    final Float32List? lineView =
        showBones ? _poseBuffers.linesView() : null;
    final Float32List? pointView =
        showPoints ? _poseBuffers.pointsView() : null;

    Float32List? faceView;
    if (showFace && faceState != null && faceState.isFresh) {
      final Float32List? facePackedPos = faceState.packedPositions;
      final Int32List? facePackedRanges = faceState.packedRanges;
      final bool hasFacePacked = facePackedPos != null &&
          facePackedRanges != null &&
          facePackedRanges.isNotEmpty;
      final List<List<Offset>>? facesLegacy = faceState.last;
      final List<Float32List>? facesFlat = faceState.lastFlat;

      _facePoints.reset();

      if (hasFacePacked) {
        for (int i = 0; i + 1 < facePackedRanges!.length; i += 2) {
          _facePoints.appendPacked(
            facePackedPos!,
            facePackedRanges[i],
            facePackedRanges[i + 1],
          );
        }
      } else if (facesFlat != null && facesFlat.isNotEmpty) {
        for (final Float32List fFlat in facesFlat) {
          _facePoints.appendFlat(fFlat);
        }
      } else if (facesLegacy != null && facesLegacy.isNotEmpty) {
        for (final pts in facesLegacy) {
          _facePoints.appendOffsets(pts);
        }
      }

      faceView = _facePoints.view();
    }

    if (lineView == null && pointView == null && faceView == null) {
      return;
    }

    canvas.save();
    if (mirror) {
      canvas.translate(size.width - offX, offY);
      canvas.scale(-s, s);
    } else {
      canvas.translate(offX, offY);
      canvas.scale(s, s);
    }

    if (lineView != null) {
      canvas.drawRawPoints(PointMode.lines, lineView, bonePaint);
    }

    if (pointView != null) {
      canvas.drawRawPoints(PointMode.points, pointView, ptsPaint);
    }

    if (faceView != null) {
      canvas.drawRawPoints(PointMode.points, faceView, facePaint);
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

class _PoseBufferSet {
  _PoseBufferSet(this._edges);

  final List<int> _edges;
  late final int _maxSegments = _edges.length ~/ 2;

  Float32List _pointBuf = Float32List(0);
  Float32List _lineBuf = Float32List(0);
  Float32List _scratch = Float32List(0);
  int _pointFloats = 0;
  int _lineFloats = 0;

  final Map<int, Float32List> _pointViews = <int, Float32List>{};
  final Map<int, Float32List> _lineViews = <int, Float32List>{};

  void reset() {
    _pointFloats = 0;
    _lineFloats = 0;
  }

  void _ensurePointCapacity(int floats) {
    if (_pointBuf.length >= floats) return;
    _pointBuf = Float32List(floats);
    _pointViews.clear();
  }

  void _ensureLineCapacity(int floats) {
    if (_lineBuf.length >= floats) return;
    _lineBuf = Float32List(floats);
    _lineViews.clear();
  }

  Float32List _ensureScratch(int floats) {
    if (_scratch.length >= floats) return _scratch;
    _scratch = Float32List(floats);
    return _scratch;
  }

  void appendPacked(
    Float32List src,
    int startPt,
    int countPt, {
    required bool addPoints,
    required bool addLines,
  }) {
    if (countPt <= 0) return;
    final int startF = startPt << 1;
    if (startF >= src.length) return;
    int endF = startF + (countPt << 1);
    if (endF > src.length) endF = src.length;
    final int floats = endF - startF;
    if (floats <= 0) return;
    final int availablePts = floats >> 1;
    if (availablePts <= 0) return;

    if (addPoints) {
      _ensurePointCapacity(_pointFloats + floats);
      _pointBuf.setRange(_pointFloats, _pointFloats + floats, src, startF);
      _pointFloats += floats;
    }

    if (addLines) {
      _ensureLineCapacity(_lineFloats + _maxSegments * 4);
      for (int e = 0; e < _edges.length; e += 2) {
        final int a = _edges[e];
        final int b = _edges[e + 1];
        if (a >= availablePts || b >= availablePts) continue;
        final int idxA = startF + (a << 1);
        final int idxB = startF + (b << 1);
        if (idxA + 1 >= endF || idxB + 1 >= endF) continue;
        _lineBuf[_lineFloats++] = src[idxA];
        _lineBuf[_lineFloats++] = src[idxA + 1];
        _lineBuf[_lineFloats++] = src[idxB];
        _lineBuf[_lineFloats++] = src[idxB + 1];
      }
    }
  }

  void appendFlat(
    Float32List flat, {
    required bool addPoints,
    required bool addLines,
  }) {
    if (flat.isEmpty) return;
    appendPacked(flat, 0, flat.length >> 1, addPoints: addPoints, addLines: addLines);
  }

  void appendOffsets(
    List<Offset> pose, {
    required bool addPoints,
    required bool addLines,
  }) {
    if (pose.isEmpty) return;
    final int floats = pose.length << 1;
    final Float32List scratch = _ensureScratch(floats);
    int k = 0;
    for (final Offset pt in pose) {
      scratch[k++] = pt.dx;
      scratch[k++] = pt.dy;
    }
    appendPacked(scratch, 0, pose.length, addPoints: addPoints, addLines: addLines);
  }

  Float32List? pointsView() {
    if (_pointFloats == 0) return null;
    return _pointViews[_pointFloats] ??=
        Float32List.view(_pointBuf.buffer, 0, _pointFloats);
  }

  Float32List? linesView() {
    if (_lineFloats == 0) return null;
    return _lineViews[_lineFloats] ??=
        Float32List.view(_lineBuf.buffer, 0, _lineFloats);
  }
}

class _PointBuffer {
  Float32List _buf = Float32List(0);
  Float32List _scratch = Float32List(0);
  int _floats = 0;
  final Map<int, Float32List> _views = <int, Float32List>{};

  void reset() {
    _floats = 0;
  }

  void _ensureCapacity(int floats) {
    if (_buf.length >= floats) return;
    _buf = Float32List(floats);
    _views.clear();
  }

  Float32List _ensureScratch(int floats) {
    if (_scratch.length >= floats) return _scratch;
    _scratch = Float32List(floats);
    return _scratch;
  }

  void appendPacked(Float32List src, int startPt, int countPt) {
    if (countPt <= 0) return;
    final int startF = startPt << 1;
    if (startF >= src.length) return;
    int endF = startF + (countPt << 1);
    if (endF > src.length) endF = src.length;
    final int floats = endF - startF;
    if (floats <= 0) return;
    _ensureCapacity(_floats + floats);
    _buf.setRange(_floats, _floats + floats, src, startF);
    _floats += floats;
  }

  void appendFlat(Float32List flat) {
    if (flat.isEmpty) return;
    _ensureCapacity(_floats + flat.length);
    _buf.setRange(_floats, _floats + flat.length, flat);
    _floats += flat.length;
  }

  void appendOffsets(List<Offset> pts) {
    if (pts.isEmpty) return;
    final int floats = pts.length << 1;
    final Float32List scratch = _ensureScratch(floats);
    int k = 0;
    for (final Offset pt in pts) {
      scratch[k++] = pt.dx;
      scratch[k++] = pt.dy;
    }
    appendPacked(scratch, 0, pts.length);
  }

  Float32List? view() {
    if (_floats == 0) return null;
    return _views[_floats] ??= Float32List.view(_buf.buffer, 0, _floats);
  }
}
