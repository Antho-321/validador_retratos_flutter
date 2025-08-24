// lib/features/posture/domain/validators/portrait_validations.dart
import 'dart:ui' show Offset, Size;
import 'package:flutter/widgets.dart' show BoxFit;

import '../../core/face_oval_geometry.dart' show faceOvalRectFor;

/// Report of all portrait checks (add more fields as you add rules).
class PortraitValidationReport {
  const PortraitValidationReport({
    required this.faceInOval,
    required this.fractionInsideOval,
    required this.ovalProgress,
  });

  /// Final pass/fail for the face-in-oval rule (gated by [minFractionInside]).
  final bool faceInOval;

  /// 0..1 fraction of landmarks that lie inside the oval (smooth signal).
  final double fractionInsideOval;

  /// 0..1 progress value for the UI ring. For now equals [fractionInsideOval],
  /// but you can change it to be a weighted mix of multiple rules later.
  final double ovalProgress;
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
    double minFractionInside = 1.0,     // 1.0 = all points inside to pass
    double eps = 1e-6,                  // numeric tolerance
  }) {
    if (landmarksImg.isEmpty ||
        imageSize.width <= 0 ||
        imageSize.height <= 0 ||
        canvasSize.width <= 0 ||
        canvasSize.height <= 0) {
      return const PortraitValidationReport(
        faceInOval: false,
        fractionInsideOval: 0.0,
        ovalProgress: 0.0,
      );
    }

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
      // Ellipse implicit equation: (x^2 / rx^2) + (y^2 / ry^2) <= 1
      final v = (dx * dx) / (rx2 + eps) + (dy * dy) / (ry2 + eps);
      if (v <= 1.0 + eps) inside++;
    }

    final fracInside = inside / mapped.length;
    final pass = fracInside >= (minFractionInside.clamp(0.0, 1.0));
    // UI progress — smooth fraction today; later you can blend multiple rules.
    final progress = fracInside.clamp(0.0, 1.0);

    return PortraitValidationReport(
      faceInOval: pass,
      fractionInsideOval: fracInside,
      ovalProgress: progress,
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
        // Non-uniform scaling (aspect ratio changed).
        final sx = cw / iw;
        final sy = ch / ih;
        return points.map((p) {
          final xScaled = p.dx * (mirror ? -sx : sx);
          final xPos = mirror ? (cw + xScaled) : xScaled;
          final yPos = p.dy * sy;
          return Offset(xPos, yPos);
        }).toList();

      // For simplicity, treat other modes as "contain".
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
