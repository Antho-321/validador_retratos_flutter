// lib/apps/asistente_retratos/domain/entity/validation_profile.dart

/// Public sense for gates in the domain layer (no underscores → not private).
enum GateSense { insideIsOk, outsideIsOk }

/// Configuración de gating por eje (enter/exit bands, dwell, etc.)
/// Ahora también incluye `maxOffDeg` para mapear progreso en validadores tipo `checkAngle`.
class GateConfig {
  final double baseDeadband;
  final double tighten;
  final double hysteresis;
  final Duration dwell;
  final double extraRelaxAfterFirst;
  final GateSense sense;

  /// Límite de “exceso” (en grados) donde el progreso cae a 0 en `checkAngle`.
  /// - Yaw/Pitch/Shoulders suelen usar ~20°.
  /// - Roll puede usar 100° si mantienes tu regla especial (aunque no lo uses).
  final double maxOffDeg;

  const GateConfig({
    required this.baseDeadband,
    this.tighten = 0.2,
    this.hysteresis = 0.2,
    this.dwell = const Duration(milliseconds: 1000),
    this.extraRelaxAfterFirst = 0.2,
    this.sense = GateSense.insideIsOk,
    this.maxOffDeg = 20.0, // ← default razonable para la mayoría
  });
}

/// Works for [lo, hi] ranges like azimut/shoulders.
class Band {
  final double lo;
  final double hi;
  const Band(this.lo, this.hi);
}

/// Config específica de “rostro dentro del óvalo” (para el anillo UI).
class FaceConfig {
  /// Fracción mínima de puntos dentro del óvalo para considerar “OK”.
  /// (0..1). 1.0 = todos los puntos dentro.
  final double minFractionInside;

  /// Tolerancia numérica para la prueba elíptica.
  final double eps;

  const FaceConfig({
    this.minFractionInside = 1.0,
    this.eps = 1e-6,
  });
}

/// Ajustes de UX no críticos (no son umbrales de validación).
class UiTuning {
  final double rollMaxDpsDuringDwell;
  final Duration hudMinInterval;

  // ⬇️ NUEVO: deadzones solo-UI para hints/animaciones
  final double yawHintDeadzoneDeg;
  final double pitchHintDeadzoneDeg;
  final double rollHintDeadzoneDeg;
  final double shouldersHintDeadzoneDeg;
  final double azimutHintDeadzoneDeg;

  const UiTuning({
    this.rollMaxDpsDuringDwell = 15.0,
    this.hudMinInterval = const Duration(milliseconds: 66),
    this.yawHintDeadzoneDeg = 0.15,
    this.pitchHintDeadzoneDeg = 0.15,
    this.rollHintDeadzoneDeg = 0.30,
    this.shouldersHintDeadzoneDeg = 0.20,
    this.azimutHintDeadzoneDeg = 0.30,
  });
}


class ValidationProfile {
  // Face-in-oval
  final FaceConfig face;

  // Head gates
  final GateConfig yaw, pitch, roll;

  // Shoulders & torso (rangos + sus gates)
  final Band shouldersBand, azimutBand;
  final GateConfig shouldersGate, azimutGate;

  // UX tuning (no cambia la lógica de validación)
  final UiTuning ui;

  const ValidationProfile({
    required this.face,
    required this.yaw,
    required this.pitch,
    required this.roll,
    required this.shouldersBand,
    required this.shouldersGate,
    required this.azimutBand,
    required this.azimutGate,
    this.ui = const UiTuning(),
  });

  static const defaultProfile = ValidationProfile(
    face: FaceConfig(
      minFractionInside: 1.0,
      eps: 1e-6,
    ),

    // Head
    yaw: GateConfig(
      baseDeadband: 1.6,
      tighten: 1,
      hysteresis: 1.5,
      maxOffDeg: 20.0,
    ),
    pitch: GateConfig(
      baseDeadband: 1.6,
      tighten: 1,
      hysteresis: 1.5,
      maxOffDeg: 20.0,
    ),
    roll: GateConfig(
      baseDeadband: 1.7,
      tighten: 0.4,
      hysteresis: 0.3,
      maxOffDeg: 100.0, // no crítico si tu regla de roll no lo usa
    ),

    // Shoulders
    shouldersBand: Band(-2.22, 2.30),
    shouldersGate: GateConfig(
      baseDeadband: 0.0,
      tighten: 0.7,
      hysteresis: 0.8,
      maxOffDeg: 20.0,
    ),

    // Torso azimut
    azimutBand: Band(-0.02, 0.02),
    azimutGate: GateConfig(
      baseDeadband: 0.0,
      tighten: 0.015,
      hysteresis: 0.009,
      maxOffDeg: 20.0, // (no usado por ahora, pero queda centralizado)
    ),

    // UX
    ui: UiTuning(
      rollMaxDpsDuringDwell: 15.0,
      hudMinInterval: Duration(milliseconds: 66),
    ),
  );
}
