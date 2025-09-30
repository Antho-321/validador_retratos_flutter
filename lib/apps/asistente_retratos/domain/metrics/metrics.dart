// lib/apps/asistente_retratos/domain/metrics/metrics.dart
import 'dart:ui' show Offset, Size;
import 'package:flutter/painting.dart' show BoxFit;

/// ─────────────────────────────────────────────────────────────────────
/// Metric infra
/// ─────────────────────────────────────────────────────────────────────

typedef MetricFn = double? Function(FrameInputs i);

class MetricKey {
  final String id; // e.g., 'yaw.abs', 'roll.err180', 'eyes.ear'
  const MetricKey(this.id);
}

class MetricRegistry {
  final Map<String, MetricFn> _providers = {};
  final Map<String, double?> _cache = {};

  void register(MetricKey key, MetricFn fn) => _providers[key.id] = fn;

  /// Genérico para permitir llamadas como `get<double?>(...)` o sin genérico.
  T? get<T extends num>(MetricKey key, FrameInputs i) {
    final v = _cache.putIfAbsent(key.id, () => _providers[key.id]?.call(i));
    return v as T?;
  }

  void clear() => _cache.clear();
}

/// ─────────────────────────────────────────────────────────────────────
/// Minimal inputs you already have (face landmarks, pose, sizes, mirror…)
/// ─────────────────────────────────────────────────────────────────────

typedef PoseLms3DPoint = ({double x, double y, double z});

class FrameInputs {
  FrameInputs({
    required this.now,
    required this.landmarksImg,
    required this.poseLandmarksImg,
    required this.poseLandmarks3D,
    required this.imageSize,
    required this.canvasSize,
    required this.mirror,
    required this.fit,
  });

  final DateTime now;
  final List<Offset>? landmarksImg;
  final List<Offset>? poseLandmarksImg;
  final List<PoseLms3DPoint>? poseLandmarks3D;
  final Size imageSize, canvasSize;
  final bool mirror;
  final BoxFit fit;
}

/// ─────────────────────────────────────────────────────────────────────
/// Metric keys (usadas por reglas: yaw/pitch/roll/shoulders/azimut…)
/// ─────────────────────────────────────────────────────────────────────

class MetricKeys {
  // Cabeza
  static const yawSigned = MetricKey('yaw.signed');      // yaw firmado en °
  static const pitchSigned = MetricKey('pitch.signed');  // pitch firmado en °
  static const rollSigned = MetricKey('roll.signed');    // roll firmado en °
  static const yawAbs   = MetricKey('yaw.abs');        // |yaw| en ° (abs)
  static const pitchAbs = MetricKey('pitch.abs');      // |pitch| en ° (abs)
  static const rollErr  = MetricKey('roll.err180');    // distancia a 180° (°)

  // Torso / Hombros
  static const shouldersSigned = MetricKey('shoulders.signed'); // deg firmado
  static const azimutSigned    = MetricKey('azimut.signed');    // deg firmado

}
