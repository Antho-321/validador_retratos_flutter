// lib/features/posture/domain/validation_profile.dart

/// Public sense for gates in the domain layer (no underscores → not private).
enum GateSense { insideIsOk, outsideIsOk }

class GateConfig {
  final double baseDeadband;
  final double tighten;
  final double hysteresis;
  final Duration dwell;
  final double extraRelaxAfterFirst;
  final GateSense sense;

  const GateConfig({
    required this.baseDeadband,
    this.tighten = 0.2,
    this.hysteresis = 0.2,
    this.dwell = const Duration(milliseconds: 1000),
    this.extraRelaxAfterFirst = 0.2,
    this.sense = GateSense.insideIsOk,
  });
}

/// Works for [lo, hi] ranges like azimut/shoulders.
class Band {
  final double lo;
  final double hi;
  const Band(this.lo, this.hi);
}

class ValidationProfile {
  // Head
  final GateConfig yaw, pitch, roll;

  // Shoulders & torso (need ranges)
  final Band shouldersBand, azimutBand;
  final GateConfig shouldersGate, azimutGate;

  const ValidationProfile({
    required this.yaw,
    required this.pitch,
    required this.roll,
    required this.shouldersBand,
    required this.shouldersGate,
    required this.azimutBand,
    required this.azimutGate,
  });

  static const defaultProfile = ValidationProfile(
    yaw: GateConfig(baseDeadband: 2.2, tighten: 1.4, hysteresis: 0.2),
    pitch: GateConfig(baseDeadband: 2.2, tighten: 1.4, hysteresis: 0.2),
    roll: GateConfig(baseDeadband: 1.7, tighten: 0.4, hysteresis: 0.3),
    shouldersBand: Band(-2.0, 1.7),
    shouldersGate: GateConfig(baseDeadband: 0.0, tighten: 0.6, hysteresis: 1.0),
    azimutBand: Band(4.5, 11.0),
    azimutGate: GateConfig(baseDeadband: 0.0, tighten: 2.5, hysteresis: 3.0),
  );
}
