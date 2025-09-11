// lib/apps/asistente_retratos/domain/validators/portrait_validations.dart
import 'dart:ui' show Offset, Size;
import 'package:flutter/widgets.dart' show BoxFit;

import '../metrics/pose_geometry.dart' as geom;
import '../../core/face_oval_geometry.dart' show faceOvalRectFor;
import 'yaw_pitch_roll.dart' show yawPitchRollFromFaceMesh;

/// Result type reused for yaw/pitch/roll checks.
class AngleCheck {
  final bool ok;
  final double progress; // 0..1
  final double offDeg;   // exceso sobre el deadband
  const AngleCheck({required this.ok, required this.progress, required this.offDeg});
}

/// Generic angle validator used for yaw/pitch/roll.
/// - If [enabled] is false -> ok=true, progress=1.0, off=0.
/// - If |deg| <= deadband   -> ok=true, progress=1.0, off=0.
/// - Otherwise              -> ok=false, progress decae linealmente hasta 0 en [maxOffDeg].
AngleCheck checkAngle({
  required bool enabled,
  required double deg,          // ángulo firmado (p.ej., yaw/pitch/roll)
  required double deadbandDeg,  // tolerancia
  required double maxOffDeg,    // cuánto exceso consideras “100% mal”
}) {
  if (!enabled) return const AngleCheck(ok: true, progress: 1.0, offDeg: 0.0);

  final abs = deg.abs();
  if (abs <= deadbandDeg) {
    return const AngleCheck(ok: true, progress: 1.0, offDeg: 0.0);
  }
  final off = (abs - deadbandDeg).clamp(0.0, maxOffDeg).toDouble();
  final progress = (1.0 - (off / maxOffDeg)).clamp(0.0, 1.0).toDouble();
  return AngleCheck(ok: false, progress: progress, offDeg: off);
}

/// Result para validar pertenencia a un rango [lo, hi] con progreso.
class BandCheck {
  final bool ok;
  final double progress; // 0..1
  final double offDeg;   // exceso respecto al borde más cercano
  const BandCheck({required this.ok, required this.progress, required this.offDeg});
}

/// Progreso lineal: 1.0 dentro del rango; fuera decae a 0 con maxOffDeg.
BandCheck checkBand({
  required bool enabled,
  required double value,
  required double lo,
  required double hi,
  required double maxOffDeg,
}) {
  if (!enabled) return const BandCheck(ok: true, progress: 1.0, offDeg: 0.0);
  if (value >= lo && value <= hi) {
    return const BandCheck(ok: true, progress: 1.0, offDeg: 0.0);
    }
  final d = (value < lo) ? (lo - value) : (value - hi); // distancia al borde
  final off = d.clamp(0.0, maxOffDeg).toDouble();
  final progress = (1.0 - (off / maxOffDeg)).clamp(0.0, 1.0).toDouble();
  return BandCheck(ok: false, progress: progress, offDeg: off);
}

/// Report of all portrait checks (expand as you add rules).
class PortraitValidationReport {
  const PortraitValidationReport({
    required this.faceInOval,
    required this.fractionInsideOval,

    // Yaw
    required this.yawOk,
    required this.yawDeg,
    required this.yawProgress,

    // Pitch
    required this.pitchOk,
    required this.pitchDeg,
    required this.pitchProgress,

    // Roll
    required this.rollOk,
    required this.rollDeg,
    required this.rollProgress,

    // Shoulders (tilt)
    required this.shouldersOk,
    required this.shouldersDeg,
    required this.shouldersProgress,

    // Azimut (torso)
    required this.azimutOk,
    required this.azimutDeg,
    required this.azimutProgress,

    // UI ring & overall
    required this.ovalProgress,
    required this.allChecksOk,
  });

  /// Face-in-oval rule
  final bool faceInOval;
  final double fractionInsideOval; // 0..1 smooth fraction

  /// Yaw rule
  final bool yawOk;
  final double yawDeg;        // signed degrees (after mirror correction)
  final double yawProgress;   // 0..1 (1 = perfect, 0 = worst)

  /// Pitch rule
  final bool pitchOk;
  final double pitchDeg;      // signed degrees (mirror does NOT flip pitch)
  final double pitchProgress; // 0..1 (1 = perfect, 0 = worst)

  /// Roll rule
  final bool rollOk;
  final double rollDeg;       // signed degrees (mirror flips roll)
  final double rollProgress;  // 0..1

  /// Shoulders tilt rule
  final bool shouldersOk;
  final double shouldersDeg;       // (-90..90]
  final double shouldersProgress;  // 0..1

  /// Azimut (torso)
  final bool azimutOk;
  final double azimutDeg;
  final double azimutProgress;

  /// UI ring progress:
  /// - while face isn't inside oval -> equals fractionInsideOval
  /// - once face is inside oval     -> equals combined progress (yaw/pitch/roll + shoulders + azimut)
  final double ovalProgress;

  /// Overall gate for capture/countdown
  final bool allChecksOk;
}

/// Stateless validator you can keep as a field (e.g., `const PortraitValidator()`).
class PortraitValidator {
  const PortraitValidator();

  /// Main entry point. Give it the raw image-space landmarks (px) plus the
  /// image size and the current canvas size/mirroring/fit used by your preview.
  PortraitValidationReport evaluate({
    required List<Offset> landmarksImg, // face landmarks in image-space (px)
    required Size imageSize,            // from your frame
    required Size canvasSize,           // from LayoutBuilder
    bool mirror = true,                 // must match RTCVideoView.mirror
    BoxFit fit = BoxFit.cover,          // must match RTCVideoView.objectFit

    // Face-in-oval rule
    double minFractionInside = 1.0,     // 1.0 = all points inside to pass
    double eps = 1e-6,                  // numeric tolerance

    // Yaw rule parameters (degrees)
    bool enableYaw = true,
    double yawDeadbandDeg = 2.0,        // OK cone: [-2°, +2°]
    double yawMaxOffDeg = 20.0,         // where progress bottoms out

    // Pitch rule parameters (degrees)
    bool enablePitch = true,
    double pitchDeadbandDeg = 2.0,      // OK cone: [-2°, +2°]
    double pitchMaxOffDeg = 20.0,       // where progress bottoms out

    // Roll rule parameters (degrees)
    bool enableRoll = true,
    double rollDeadbandDeg = 175,       // caller can override (e.g., 2.2)
    double rollMaxOffDeg = 100.0,       // kept for API symmetry (unused in new rule)

    // Shoulders tilt parameters (degrees)
    List<Offset>? poseLandmarksImg,     // full-body/upper-body pose landmarks (image-space)
    bool enableShoulders = false,
    double shouldersDeadbandDeg = 5.0,  // allow up to ±5°
    double shouldersMaxOffDeg = 20.0,   // where progress bottoms out

    // Azimut (torso) — progreso por banda [lo, hi]
    bool enableAzimut = false,
    double? azimutDeg,                  // ángulo firmado ya estimado (3D)
    double azimutBandLo = 0.0,
    double azimutBandHi = 0.0,
    double azimutMaxOffDeg = 20.0,
  }) {
    if (landmarksImg.isEmpty ||
        imageSize.width <= 0 ||
        imageSize.height <= 0 ||
        canvasSize.width <= 0 ||
        canvasSize.height <= 0) {
      return const PortraitValidationReport(
        faceInOval: false,
        fractionInsideOval: 0.0,
        yawOk: false,
        yawDeg: 0.0,
        yawProgress: 0.0,
        pitchOk: false,
        pitchDeg: 0.0,
        pitchProgress: 0.0,
        rollOk: false,
        rollDeg: 0.0,
        rollProgress: 0.0,
        shouldersOk: false,
        shouldersDeg: 0.0,
        shouldersProgress: 0.0,
        azimutOk: false,
        azimutDeg: 0.0,
        azimutProgress: 0.0,
        ovalProgress: 0.0,
        allChecksOk: false,
      );
    }

    // Face-in-oval (in canvas space, respecting fit/mirror)
    final mapped = geom.mapImagePointsToCanvas(
      points: landmarksImg,
      imageSize: imageSize,
      canvasSize: canvasSize,
      mirror: mirror,
      fit: fit,
    );

    final oval = faceOvalRectFor(canvasSize);
    final rx = oval.width / 2.0;
    final ry = oval.height / 2.0;
    final cx = oval.center.dx;
    final cy = oval.center.dy;
    final rx2 = rx * rx;
    final ry2 = ry * ry;

    int inside = 0;
    for (final p in mapped) {
      final dx = p.dx - cx;
      final dy = p.dy - cy;
      final v = (dx * dx) / (rx2 + eps) + (dy * dy) / (ry2 + eps);
      if (v <= 1.0 + eps) inside++;
    }
    final fracInside = inside / mapped.length;
    final faceOk = fracInside >= (minFractionInside.clamp(0.0, 1.0));

    // Head orientation (yaw & pitch & roll in image space)
    double yawDeg = 0.0, pitchDeg = 0.0, rollDeg = 0.0;
    bool yawOk = false, pitchOk = false, rollOk = false;
    double yawProgress = enableYaw ? 0.0 : 1.0;
    double pitchProgress = enablePitch ? 0.0 : 1.0;
    double rollProgress = enableRoll ? 0.0 : 1.0;

    // Shoulders (tilt)
    bool shouldersOk = false;
    double shouldersDeg = 0.0;
    double shouldersProgress = enableShoulders ? 0.0 : 1.0;

    // Azimut (torso)
    bool azimutOk = false;
    double azimutDegVal = 0.0;
    double azimutProgress = enableAzimut ? 0.0 : 1.0;

    if (faceOk && (enableYaw || enablePitch || enableRoll)) {
      // Use your estimator once; it expects H/W ints (as in your page).
      final imgW = imageSize.width.toInt();
      final imgH = imageSize.height.toInt();
      final ypr = yawPitchRollFromFaceMesh(landmarksImg, imgH, imgW);

      // Yaw (mirror flips sign for front camera UX)
      if (enableYaw) {
        yawDeg = ypr.yaw;
        final res = checkAngle(
          enabled: true,
          deg: yawDeg,
          deadbandDeg: yawDeadbandDeg,
          maxOffDeg: yawMaxOffDeg,
        );
        yawOk = res.ok;
        yawProgress = res.progress;
      }

      // Pitch (do not flip sign on mirror)
      if (enablePitch) {
        pitchDeg = ypr.pitch;
        final res = checkAngle(
          enabled: true,
          deg: pitchDeg,
          deadbandDeg: pitchDeadbandDeg,
          maxOffDeg: pitchMaxOffDeg,
        );
        pitchOk = res.ok;
        pitchProgress = res.progress;
      }

      // Roll (mirror flips sign). New rule: OK only if |roll| >= deadband.
      if (enableRoll) {
        rollDeg = ypr.roll;
        final absRoll = rollDeg.abs();

        // OK region: outside the deadband (we want a minimal tilt)
        if (absRoll >= rollDeadbandDeg) {
          rollOk = true;
          rollProgress = 1.0;
        } else {
          // Not OK: too straight. Progress grows linearly up to the deadband.
          rollOk = false;
          rollProgress = (absRoll / rollDeadbandDeg).clamp(0.0, 1.0);
        }
      }
    }

    // Shoulders tilt (independent from head ring; contributes to ring and allChecksOk)
    if (faceOk && enableShoulders && (poseLandmarksImg != null)) {
      final ang = geom.calcularAnguloHombros(poseLandmarksImg);
      if (ang != null) {
        shouldersDeg = _normalizeTilt90(ang);
        final res = checkAngle(
          enabled: true,
          deg: shouldersDeg,
          deadbandDeg: shouldersDeadbandDeg,
          maxOffDeg: shouldersMaxOffDeg,
        );
        shouldersOk = res.ok;
        shouldersProgress = res.progress;
      }
    }

    // Azimut progress with band [lo, hi]
    if (faceOk && enableAzimut && azimutDeg != null) {
      azimutDegVal = azimutDeg!;
      final bz = checkBand(
        enabled: true,
        value: azimutDegVal,
        lo: azimutBandLo,
        hi: azimutBandHi,
        maxOffDeg: azimutMaxOffDeg,
      );
      azimutOk = bz.ok;
      azimutProgress = bz.progress;
    }

    // UI ring: face progress until it passes; then combine progress of all enabled checks.
    double combinedProgress = 1.0;
    final parts = <double>[];
    if (enableYaw) parts.add(yawProgress);
    if (enablePitch) parts.add(pitchProgress);
    if (enableRoll) parts.add(rollProgress);
    if (enableShoulders) parts.add(shouldersProgress);
    if (enableAzimut) parts.add(azimutProgress);
    if (parts.isNotEmpty) {
      combinedProgress = parts.reduce(_min);
    }
    final ringProgress = faceOk ? combinedProgress : fracInside;

    final allOk = faceOk &&
        (!enableYaw || yawOk) &&
        (!enablePitch || pitchOk) &&
        (!enableRoll || rollOk) &&
        (!enableShoulders || shouldersOk) &&
        (!enableAzimut || azimutOk);

    return PortraitValidationReport(
      faceInOval: faceOk,
      fractionInsideOval: fracInside,
      yawOk: yawOk,
      yawDeg: yawDeg,
      yawProgress: yawProgress,
      pitchOk: pitchOk,
      pitchDeg: pitchDeg,
      pitchProgress: pitchProgress,
      rollOk: rollOk,
      rollDeg: rollDeg,
      rollProgress: rollProgress,
      shouldersOk: shouldersOk,
      shouldersDeg: shouldersDeg,
      shouldersProgress: shouldersProgress,
      azimutOk: azimutOk,
      azimutDeg: azimutDegVal,
      azimutProgress: azimutProgress,
      ovalProgress: ringProgress,
      allChecksOk: allOk,
    );
  }

  double _normalizeTilt90(double a) {
    double x = a;
    if (x > 90.0) x -= 180.0;
    if (x <= -90.0) x += 180.0;
    return x; // (-90..90]
  }

  double _min(double a, double b) => (a < b) ? a : b;
  double _max(double a, double b) => (a > b) ? a : b;
}
