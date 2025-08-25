// lib/features/posture/domain/validators/portrait_validations.dart
import 'dart:ui' show Offset, Size;
import 'package:flutter/widgets.dart' show BoxFit;

import '../../core/face_oval_geometry.dart' show faceOvalRectFor;
import 'yaw_pitch_roll.dart' show yawPitchRollFromFaceMesh;

/// Report of all portrait checks (expand as you add rules).
class PortraitValidationReport {
  const PortraitValidationReport({
    required this.faceInOval,
    required this.fractionInsideOval,
    required this.yawOk,
    required this.yawDeg,
    required this.yawProgress,
    required this.ovalProgress,
    required this.allChecksOk,
  });

  /// Face-in-oval rule
  final bool faceInOval;
  final double fractionInsideOval; // 0..1 smooth fraction

  /// Yaw rule
  final bool yawOk;
  final double yawDeg;             // signed degrees (after mirror correction)
  final double yawProgress;        // 0..1 (1 = perfect, 0 = worst)

  /// UI ring progress:
  /// - while face isn't inside oval -> equals fractionInsideOval
  /// - once face is inside oval     -> equals yawProgress
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

    // ── Yaw (computed in image space; mirror flip affects sign) ─────────────
    double yawDeg = 0.0;
    bool yawOk = false;
    double yawProgress = 0.0;

    if (enableYaw && faceOk) {
      // Use your existing estimator; it expects H/W ints (as in your page).
      final imgW = imageSize.width.toInt();
      final imgH = imageSize.height.toInt();
      final ypr = yawPitchRollFromFaceMesh(landmarksImg, imgH, imgW);
      yawDeg = ypr.yaw;
      if (mirror) yawDeg = -yawDeg; // front camera UX

      // Pass/fail + progress
      if (yawDeg.abs() <= yawDeadbandDeg) {
        yawOk = true;
        yawProgress = 1.0;
      } else {
        final off = (yawDeg.abs() - yawDeadbandDeg).clamp(0.0, yawMaxOffDeg);
        yawProgress = (1.0 - (off / yawMaxOffDeg)).clamp(0.0, 1.0);
      }
    }

    // UI ring: first rule’s progress until face passes; then yaw progress.
    final ringProgress = faceOk ? yawProgress : fracInside;

    final allOk = faceOk && (!enableYaw || yawOk);

    return PortraitValidationReport(
      faceInOval: faceOk,
      fractionInsideOval: fracInside,
      yawOk: yawOk,
      yawDeg: yawDeg,
      yawProgress: yawProgress,
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
