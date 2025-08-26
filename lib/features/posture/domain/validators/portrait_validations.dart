// lib/features/posture/domain/validators/portrait_validations.dart
import 'dart:ui' show Offset, Size;
import 'package:flutter/widgets.dart' show BoxFit;

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

  /// UI ring progress:
  /// - while face isn't inside oval -> equals fractionInsideOval
  /// - once face is inside oval     -> equals combined head progress (yaw/pitch[/roll])
  final double ovalProgress;

  /// Overall gate for capture/countdown
  final bool allChecksOk;
}

/// Stateless validator you can keep as a field (e.g., `const PortraitValidator()`).
class PortraitValidator {
  const PortraitValidator();

  /// Main entry point. Give it the raw *image-space* landmarks (px) plus the
  /// image size and the *current* canvas size/mirroring/fit used by your preview.
  PortraitValidationReport evaluate({
    required List<Offset> landmarksImg, // image-space points (px)
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
        ovalProgress: 0.0,
        allChecksOk: false,
      );
    }

    // ── Face-in-oval (in canvas space, respecting fit/mirror) ────────────────
    final mapped = _mapImagePointsToCanvas(
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

    // ── Head orientation (yaw & pitch & roll in image space) ────────────────
    double yawDeg = 0.0, pitchDeg = 0.0, rollDeg = 0.0;
    bool yawOk = false, pitchOk = false, rollOk = false;
    double yawProgress = enableYaw ? 0.0 : 1.0;
    double pitchProgress = enablePitch ? 0.0 : 1.0;
    double rollProgress = enableRoll ? 0.0 : 1.0;

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

      // Roll (mirror flips sign). New rule: OK only if |roll| ≥ deadband.
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

    // UI ring: face progress until it passes; then combine head progress.
    double headProgress = 1.0;
    final parts = <double>[];
    if (enableYaw) parts.add(yawProgress);
    if (enablePitch) parts.add(pitchProgress);
    if (enableRoll) parts.add(rollProgress);
    if (parts.isNotEmpty) {
      headProgress = parts.reduce(_min);
    }
    final ringProgress = faceOk ? headProgress : fracInside;

    final allOk = faceOk &&
        (!enableYaw || yawOk) &&
        (!enablePitch || pitchOk) &&
        (!enableRoll || rollOk);

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
      ovalProgress: ringProgress,
      allChecksOk: allOk,
    );
  }

  /// Map image-space (px) points to canvas-space, respecting BoxFit + mirror.
  List<Offset> _mapImagePointsToCanvas({
    required List<Offset> points,
    required Size imageSize,
    required Size canvasSize,
    required bool mirror,
    required BoxFit fit,
  }) {
    final iw = imageSize.width;
    final ih = imageSize.height;
    final cw = canvasSize.width;
    final ch = canvasSize.height;

    double scale, dx, dy, sw, sh;

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

  double _min(double a, double b) => (a < b) ? a : b;
  double _max(double a, double b) => (a > b) ? a : b;
}
