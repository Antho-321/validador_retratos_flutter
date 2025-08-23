// lib/features/posture/utils/geometry.dart
//
// Geometry helpers for the portrait validator:
// - (Legacy) Polygon containment with edge tolerance
// - FAST landmark-in-oval check using an analytic ellipse in IMAGE space
// - Projection of image-space points to canvas space with BoxFit & mirroring
//
// Usage (examples):
//   final ok = areLandmarksWithinFaceOval(
//     landmarksImg: faceLandmarksInImagePx,
//     imageSize: const Size(640, 480),
//     canvasSize: sizeFromLayoutBuilder,
//     mirror: true,
//     fit: BoxFit.cover,
//     minFractionInside: 0.95,
//   );
//
//   final ptsOnCanvas = mapImagePointsToCanvas(
//     faceLandmarksInImagePx,
//     const Size(640, 480),
//     sizeFromLayoutBuilder,
//     mirror: true,
//     fit: BoxFit.cover,
//   );

import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;
import 'package:flutter/widgets.dart' show BoxFit;

/// ─────────────────────────────────────────────────────────────────────────
/// Optional polygon utilities (kept for other uses / debugging)
/// ─────────────────────────────────────────────────────────────────────────

/// Axis-aligned bounding box for a polygon.
Rect polygonAabb(List<Offset> poly) {
  var minX = double.infinity, minY = double.infinity;
  var maxX = -double.infinity, maxY = -double.infinity;
  for (final p in poly) {
    if (p.dx < minX) minX = p.dx;
    if (p.dy < minY) minY = p.dy;
    if (p.dx > maxX) maxX = p.dx;
    if (p.dy > maxY) maxY = p.dy;
  }
  return Rect.fromLTRB(minX, minY, maxX, maxY);
}

/// Returns true if point `p` lies on segment AB within tolerance `eps`.
bool _pointOnSegment(Offset p, Offset a, Offset b, {double eps = 1e-6}) {
  final cross = (p.dy - a.dy) * (b.dx - a.dx) - (p.dx - a.dx) * (b.dy - a.dy);
  if (cross.abs() > eps) return false;
  final dot = (p.dx - a.dx) * (b.dx - a.dx) + (p.dy - a.dy) * (b.dy - a.dy);
  if (dot < -eps) return false;
  final segLen2 =
      (b.dx - a.dx) * (b.dx - a.dx) + (b.dy - a.dy) * (b.dy - a.dy);
  if (dot - segLen2 > eps) return false;
  return true;
}

/// Even–odd ray casting test with optional edge-inclusion.
bool polygonContainsPoint(
  Offset p,
  List<Offset> poly, {
  double eps = 1e-6,
  bool allowOnEdge = true,
}) {
  // Quick AABB reject
  final bb = polygonAabb(poly);
  if (!bb.inflate(eps).contains(p)) return false;

  // Edge test first to avoid ambiguous parity on vertices
  for (var i = 0; i < poly.length; i++) {
    final a = poly[i];
    final b = poly[(i + 1) % poly.length];
    if (_pointOnSegment(p, a, b, eps: eps)) {
      return allowOnEdge;
    }
  }

  // Ray cast to +X
  var inside = false;
  for (var i = 0, j = poly.length - 1; i < poly.length; j = i, i++) {
    var xi = poly[i].dx, yi = poly[i].dy;
    var xj = poly[j].dx, yj = poly[j].dy;

    // Nudge horizontal edges to avoid degeneracy
    if ((yi - p.dy).abs() < eps) yi += eps;
    if ((yj - p.dy).abs() < eps) yj += eps;

    final intersect = ((yi > p.dy) != (yj > p.dy)) &&
        (p.dx <
            (xj - xi) * (p.dy - yi) / ((yj - yi) == 0 ? eps : (yj - yi)) + xi);
    if (intersect) inside = !inside;
  }
  return inside;
}

/// Returns the fraction of points in [points] that lie inside [polygon].
double fractionInsidePolygon(
  List<Offset> polygon,
  List<Offset> points, {
  double eps = 1e-6,
  bool allowOnEdge = true,
}) {
  if (polygon.length < 3 || points.isEmpty) return 0.0;
  var inside = 0;
  for (final p in points) {
    if (polygonContainsPoint(p, polygon, eps: eps, allowOnEdge: allowOnEdge)) {
      inside++;
    }
  }
  return inside / points.length;
}

/// ─────────────────────────────────────────────────────────────────────────
/// FAST ellipse test in IMAGE space (no polygon, no per-frame list allocs)
/// NOTE: Name kept as `areLandmarksWithinFaceOval` per request.
/// ─────────────────────────────────────────────────────────────────────────

/// These MUST match the oval geometry used by your HUD painter.
const double _kOvalWFrac = 0.56;
const double _kOvalHFrac = 0.42;
const double _kOvalCxFrac = 0.50;
const double _kOvalCyFrac = 0.41;

/// High-level check specialized for "face landmarks inside oval".
/// Computes the face-oval **in canvas space** (using shared fractions),
/// maps that oval back to **image space**, and tests the landmarks with the
/// analytic ellipse equation. O(N) time, zero per-point allocations.
///
/// Returns `true` if at least [minFractionInside] of points are inside.
bool areLandmarksWithinFaceOval({
  required List<Offset> landmarksImg, // landmarks in IMAGE pixels
  required Size imageSize,
  required Size canvasSize,
  required bool mirror,
  required BoxFit fit, // use SAME fit as your preview/overlay (usually cover)
  double minFractionInside = 1.0, // e.g., 0.90..1.0
  double eps = 1e-6,
  bool verbose = false,
}) {
  if (landmarksImg.isEmpty || imageSize.width <= 0 || imageSize.height <= 0) {
    if (verbose) {
      // ignore: avoid_print
      print('[geom] invalid args: lm=${landmarksImg.length}, '
          'img=${imageSize.width}x${imageSize.height}');
    }
    return false;
  }

  // 1) Canvas-space oval rect (replicates faceOvalRectFor(canvasSize))
  final ovalW = canvasSize.width * _kOvalWFrac;
  final ovalH = canvasSize.height * _kOvalHFrac;
  final ovalCx = canvasSize.width * _kOvalCxFrac;
  final ovalCy = canvasSize.height * _kOvalCyFrac;
  final Rect ovalCanvas = Rect.fromCenter(
    center: Offset(ovalCx, ovalCy),
    width: ovalW,
    height: ovalH,
  );

  // 2) Image <-> Canvas mapping (same math as overlay)
  final fw = imageSize.width;
  final fh = imageSize.height;
  final scaleW = canvasSize.width / fw;
  final scaleH = canvasSize.height / fh;
  final s = (fit == BoxFit.cover)
      ? (scaleW > scaleH ? scaleW : scaleH)
      : (scaleW < scaleH ? scaleW : scaleH);
  final offX = (canvasSize.width - fw * s) / 2.0;
  final offY = (canvasSize.height - fh * s) / 2.0;

  // 3) Map OVAL center/radii back to IMAGE space (inverse transform)
  double invMapX(double xCanvas) {
    final xLocal = mirror ? (canvasSize.width - xCanvas) : xCanvas;
    return (xLocal - offX) / s;
  }

  double invMapY(double yCanvas) => (yCanvas - offY) / s;

  final cxImg = invMapX(ovalCanvas.center.dx);
  final cyImg = invMapY(ovalCanvas.center.dy);
  final rxImg = (ovalCanvas.width / 2.0) / s;
  final ryImg = (ovalCanvas.height / 2.0) / s;

  if (rxImg <= eps || ryImg <= eps) return false;

  // 4) O(N) inside test (ellipse equation)
  int inside = 0;
  final invRx = 1.0 / rxImg;
  final invRy = 1.0 / ryImg;
  for (final p in landmarksImg) {
    final nx = (p.dx - cxImg) * invRx;
    final ny = (p.dy - cyImg) * invRy;
    if (nx * nx + ny * ny <= 1.0 + eps) inside++;
  }

  final frac = inside / landmarksImg.length;
  if (verbose) {
    // ignore: avoid_print
    print('[geom] landmarks inside oval: ${(frac * 100).toStringAsFixed(1)}% '
        '(need ${(minFractionInside * 100).toStringAsFixed(0)}%)');
  }
  return frac >= minFractionInside;
}

/// ─────────────────────────────────────────────────────────────────────
/// Image-space → canvas-space mapping (matches rtc_pose_overlay.dart)
/// ─────────────────────────────────────────────────────────────────────

/// Map a list of image-space points (px in [0..w)×[0..h)) to the on-screen
/// canvas coordinates, using the SAME transform as rtc_pose_overlay.dart.
List<Offset> mapImagePointsToCanvas(
  List<Offset> pts,
  Size imageSize,
  Size canvasSize, {
  required bool mirror,
  required BoxFit fit,
}) {
  final fw = imageSize.width;
  final fh = imageSize.height;
  if (fw <= 0 || fh <= 0 || pts.isEmpty) return const [];

  final scaleW = canvasSize.width / fw;
  final scaleH = canvasSize.height / fh;
  final s = (fit == BoxFit.cover)
      ? (scaleW > scaleH ? scaleW : scaleH)
      : (scaleW < scaleH ? scaleW : scaleH);

  final drawW = fw * s;
  final drawH = fh * s;
  final offX = (canvasSize.width - drawW) / 2.0;
  final offY = (canvasSize.height - drawH) / 2.0;

  return List<Offset>.generate(
    pts.length,
    (i) {
      final p = pts[i];
      final xLocal = p.dx * s + offX;
      final x = mirror ? (canvasSize.width - xLocal) : xLocal;
      final y = p.dy * s + offY;
      return Offset(x, y);
    },
    growable: false,
  );
}
