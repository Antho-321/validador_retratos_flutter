// lib/apps/asistente_retratos/domain/metrics/pose_geometry.dart

import 'dart:math' as math;
import 'dart:ui' show Offset, Size;
import 'package:flutter/painting.dart' show BoxFit;
import 'metrics.dart' show PoseLms3DPoint;

/// 🔁 Mapea puntos del espacio de imagen (px) al canvas, respetando BoxFit y mirror.
/// (Extraído desde PortraitValidator para reutilizarlo también aquí y en el validador)
List<Offset> mapImagePointsToCanvas({
  required List<Offset> points,
  required Size imageSize,
  required Size canvasSize,
  required bool mirror,
  BoxFit fit = BoxFit.cover,
}) {
  final iw = imageSize.width;
  final ih = imageSize.height;
  final cw = canvasSize.width;
  final ch = canvasSize.height;

  double scale, dx, dy, sw, sh;

  double _min(double a, double b) => (a < b) ? a : b;
  double _max(double a, double b) => (a > b) ? a : b;

  switch (fit) {
    case BoxFit.contain:
      scale = _min(cw / iw, ch / ih);
      sw = iw * scale;
      sh = ih * scale;
      dx = (cw - sw) / 2.0;
      dy = (ch - sh) / 2.0;
      break;
    case BoxFit.cover:
      scale = _max(cw / iw, ch / ih);
      sw = iw * scale;
      sh = ih * scale;
      dx = (cw - sw) / 2.0;
      dy = (ch - sh) / 2.0;
      break;
    case BoxFit.fill:
      final sx = cw / iw;
      final sy = ch / ih;
      return points.map((p) {
        final xScaled = p.dx * (mirror ? -sx : sx);
        final xPos = mirror ? (cw + xScaled) : xScaled;
        final yPos = p.dy * sy;
        return Offset(xPos, yPos);
      }).toList();
    default:
      scale = _min(cw / iw, ch / ih);
      sw = iw * scale;
      sh = ih * scale;
      dx = (cw - sw) / 2.0;
      dy = (ch - sh) / 2.0;
      break;
  }

  return points.map((p) {
    final xScaled = p.dx * scale;
    final yScaled = p.dy * scale;
    final xFit = mirror ? (sw - xScaled) : xScaled;
    return Offset(dx + xFit, dy + yScaled);
  }).toList();
}

double? calcularAnguloHombros(
  List<Offset> puntosPose, {
  int idxHombroIzq = 11,
  int idxHombroDer = 12,
}) {
  final maxIndex = math.max(idxHombroIzq, idxHombroDer);
  if (puntosPose.length > maxIndex) {
    final izq = puntosPose[idxHombroIzq];
    final der = puntosPose[idxHombroDer];
    final dy = izq.dy - der.dy;
    final dx = izq.dx - der.dx;
    return math.atan2(dy, dx) * 180.0 / math.pi; // (-180..180]
  }
  return null;
}

typedef _Axis2 = ({double dx, double dz});

bool _isLandmarkReliable(
  PoseLms3DPoint p, {
  double? minVisibility,
  double? minPresence,
}) {
  if (minVisibility != null) {
    final vis = p.visibility;
    if (vis == null || vis < minVisibility) return false;
  }
  if (minPresence != null) {
    final pres = p.presence;
    if (pres == null || pres < minPresence) return false;
  }
  return true;
}

_Axis2? _axisFromPair(
  List<PoseLms3DPoint> poseLandmarks3D,
  int idxLeft,
  int idxRight,
  double xToPx,
  double zToPx, {
  required double minAxisPx,
  double? minVisibility,
  double? minPresence,
}) {
  final maxIndex = math.max(idxLeft, idxRight);
  if (poseLandmarks3D.length <= maxIndex) return null;

  final left = poseLandmarks3D[idxLeft];
  final right = poseLandmarks3D[idxRight];
  if (!_isLandmarkReliable(
        left,
        minVisibility: minVisibility,
        minPresence: minPresence,
      ) ||
      !_isLandmarkReliable(
        right,
        minVisibility: minVisibility,
        minPresence: minPresence,
      )) {
    return null;
  }

  final dx = (right.x - left.x) * xToPx;
  final dz = (right.z - left.z) * zToPx;
  if (!dx.isFinite || !dz.isFinite) return null;

  final minAxisSq = minAxisPx * minAxisPx;
  if ((dx * dx + dz * dz) < minAxisSq) return null;

  return (dx: dx, dz: dz);
}

_Axis2? _fusedTorsoAxis(
  List<PoseLms3DPoint> poseLandmarks3D,
  double xToPx,
  double zToPx, {
  required double shoulderWeight,
  required double hipWeight,
  required double minAxisPx,
  double? minVisibility,
  double? minPresence,
}) {
  final shoulders = _axisFromPair(
    poseLandmarks3D,
    11,
    12,
    xToPx,
    zToPx,
    minAxisPx: minAxisPx,
    minVisibility: minVisibility,
    minPresence: minPresence,
  );
  if (shoulders == null) return null;

  final hips = _axisFromPair(
    poseLandmarks3D,
    23,
    24,
    xToPx,
    zToPx,
    minAxisPx: minAxisPx,
    minVisibility: minVisibility,
    minPresence: minPresence,
  );

  double wS = shoulderWeight;
  double wH = (hips == null) ? 0.0 : hipWeight;
  final sum = wS + wH;
  if (sum <= 0) return null;
  wS /= sum;
  wH /= sum;

  final dx = shoulders.dx * wS + (hips?.dx ?? 0.0) * wH;
  final dz = shoulders.dz * wS + (hips?.dz ?? 0.0) * wH;
  return (dx: dx, dz: dz);
}

double _azimuthDegFromAxis(
  _Axis2 axis, {
  bool invertZ = false,
}) {
  final dz = invertZ ? -axis.dz : axis.dz;
  return math.atan2(dz, axis.dx) * 180.0 / math.pi;
}

/// Estima el azimut biacromial usando landmarks 3D (hombros 11 y 12).
/// - `xToPx`: factor para llevar ΔX a "px" (e.g., imageWidth si x es normalizado).
/// - `zToPx`: factor para llevar ΔZ a "px" (e.g., imageWidth si z está en "image-width units").
/// - `mirror`: si la vista está espejada, invierte el signo para UX consistente.
/// - `invertZ`: toggle para invertir eje Z después de calibración real.
double? estimateAzimutBiacromial3D({
  required List<PoseLms3DPoint>? poseLandmarks3D,
  required double xToPx,
  required double zToPx,
  required bool mirror,
  bool invertZ = false,
  double minAxisPx = 1.0,
  double? minVisibility,
  double? minPresence,
}) {
  if (poseLandmarks3D == null) return null;

  final axis = _axisFromPair(
    poseLandmarks3D,
    11,
    12,
    xToPx,
    zToPx,
    minAxisPx: minAxisPx,
    minVisibility: minVisibility,
    minPresence: minPresence,
  );
  if (axis == null) return null;

  double deg = _azimuthDegFromAxis(axis, invertZ: invertZ);
  if (mirror) deg = -deg;
  return deg;
}

/// Estima el azimut del torso usando un eje fusionado hombros+hips (11/12 + 23/24).
/// - `shoulderWeight`/`hipWeight`: ponderación del eje de hombros y cadera.
/// - `minVisibility`/`minPresence`: si se proveen, filtran frames de baja confianza.
double? estimateAzimutTorso3D({
  required List<PoseLms3DPoint>? poseLandmarks3D,
  required double xToPx,
  required double zToPx,
  required bool mirror,
  bool invertZ = false,
  double shoulderWeight = 0.7,
  double hipWeight = 0.3,
  double minAxisPx = 1.0,
  double? minVisibility,
  double? minPresence,
}) {
  if (poseLandmarks3D == null) return null;

  final axis = _fusedTorsoAxis(
    poseLandmarks3D,
    xToPx,
    zToPx,
    shoulderWeight: shoulderWeight,
    hipWeight: hipWeight,
    minAxisPx: minAxisPx,
    minVisibility: minVisibility,
    minPresence: minPresence,
  );
  if (axis == null) return null;

  double deg = _azimuthDegFromAxis(axis, invertZ: invertZ);
  if (mirror) deg = -deg;
  return deg;
}

/// Normaliza el ángulo de azimut para que 0° represente "mirando a la cámara".
/// 
/// El cálculo raw de `estimateAzimutBiacromial3D`/`estimateAzimutTorso3D` devuelve valores cerca de ±180°
/// cuando el usuario mira a la cámara (hombros paralelos al plano de la imagen).
/// Esta función convierte ese valor a una desviación desde 180°:
/// - 0° = perfectamente de frente a la cámara
/// - valores positivos = torso girado hacia un lado
/// - valores negativos = torso girado hacia el otro lado
/// 
/// El resultado está en el rango (-180°, 180°] y luego se escala x1000 (mdeg).
double normalizeAzimutTo180(double rawAzimutDeg) {
  // Envolver a (-180, 180] relativo a 180°
  double delta = rawAzimutDeg - 180.0;
  // Normalizar a (-180, 180]
  while (delta > 180.0) delta -= 360.0;
  while (delta <= -180.0) delta += 360.0;
  return delta * 1000.0;
}

/// Absolute range to omit for azimut values (after normalization).
const double kAzimutOmitAbs = 0.3;

/// Returns null when |azimut| <= kAzimutOmitAbs to skip near-zero values.
double? omitAzimutDeadzone(double? azimutDeg) {
  if (azimutDeg == null) return null;
  return (azimutDeg.abs() <= kAzimutOmitAbs) ? null : azimutDeg;
}

class AzimutStabilizer {
  AzimutStabilizer({
    this.shoulderWeight = 0.7,
    this.hipWeight = 0.3,
    this.windowSize = 5,
    this.minAxisPx = 1.0,
    this.minVisibility,
    this.minPresence,
    this.decayFractionPerSecond = 0.6,
    this.minDecayPerSecond = 0.0,
    this.freezeOnBadFrames = true,
  })  : assert(windowSize >= 1),
        assert(decayFractionPerSecond >= 0),
        assert(minDecayPerSecond >= 0);

  final double shoulderWeight;
  final double hipWeight;
  final int windowSize;
  final double minAxisPx;
  final double? minVisibility;
  final double? minPresence;
  final double decayFractionPerSecond;
  final double minDecayPerSecond;
  final bool freezeOnBadFrames;

  final List<_Axis2> _axisWindow = <_Axis2>[];
  DateTime? _lastFrameAt;
  DateTime? _lastHoldAt;
  double? _holdValue;
  double? _lastOutput;

  void reset() {
    _axisWindow.clear();
    _lastFrameAt = null;
    _lastHoldAt = null;
    _holdValue = null;
    _lastOutput = null;
  }

  double? update({
    required List<PoseLms3DPoint>? poseLandmarks3D,
    required DateTime now,
    required double xToPx,
    required double zToPx,
    required bool mirror,
    bool invertZ = false,
  }) {
    if (_lastFrameAt != null && now.isAtSameMomentAs(_lastFrameAt!)) {
      return _lastOutput;
    }
    _lastFrameAt = now;

    if (poseLandmarks3D == null) {
      _touchFreeze(now);
      return _lastOutput;
    }

    final axis = _fusedTorsoAxis(
      poseLandmarks3D,
      xToPx,
      zToPx,
      shoulderWeight: shoulderWeight,
      hipWeight: hipWeight,
      minAxisPx: minAxisPx,
      minVisibility: minVisibility,
      minPresence: minPresence,
    );
    if (axis == null) {
      _touchFreeze(now);
      return _lastOutput;
    }

    _axisWindow.add(axis);
    if (_axisWindow.length > windowSize) {
      _axisWindow.removeAt(0);
    }

    final smoothAxis = _medianAxis(_axisWindow);
    double deg = _azimuthDegFromAxis(smoothAxis, invertZ: invertZ);
    if (mirror) deg = -deg;

    final normalized = normalizeAzimutTo180(deg);
    final filtered = _applyPeakHold(normalized, now);
    _lastOutput = filtered;
    return filtered;
  }

  void _touchFreeze(DateTime now) {
    if (freezeOnBadFrames) {
      _lastHoldAt = now;
    }
  }

  double _applyPeakHold(double value, DateTime now) {
    if (_holdValue == null || _lastHoldAt == null) {
      _holdValue = value;
      _lastHoldAt = now;
      return value;
    }

    final dtMs =
        now.difference(_lastHoldAt!).inMilliseconds.clamp(0, 1000);
    final dtSec = dtMs / 1000.0;
    final decayPerSec =
        math.max(minDecayPerSecond, _holdValue!.abs() * decayFractionPerSecond);

    if (value >= 0) {
      if (_holdValue! >= 0) {
        _holdValue = math.max(value, _holdValue! - decayPerSec * dtSec);
      } else {
        _holdValue = value;
      }
    } else {
      if (_holdValue! <= 0) {
        _holdValue = math.min(value, _holdValue! + decayPerSec * dtSec);
      } else {
        _holdValue = value;
      }
    }

    _lastHoldAt = now;
    return _holdValue!;
  }
}

_Axis2 _medianAxis(List<_Axis2> window) {
  if (window.isEmpty) return (dx: 0.0, dz: 0.0);
  if (window.length == 1) return window.first;

  final dxs = window.map((v) => v.dx).toList()..sort();
  final dzs = window.map((v) => v.dz).toList()..sort();
  return (
    dx: _medianFromSorted(dxs),
    dz: _medianFromSorted(dzs),
  );
}

double _medianFromSorted(List<double> values) {
  final mid = values.length ~/ 2;
  if (values.length.isOdd) return values[mid];
  return (values[mid - 1] + values[mid]) / 2.0;
}
