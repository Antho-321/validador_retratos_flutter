// lib/features/posture/utils/geometry.dart
//
// Geometry helpers for the portrait validator:
// - Polygon containment with edge tolerance
// - Landmark-in-oval check using a sampled oval polygon
// - Projection of normalized video points to canvas space with BoxFit & mirroring
//
// Usage (examples):
//   final inside = areLandmarksWithinFaceOval(ovalPts, faceLandmarks);
//   final pt = projectNormalizedToCanvas(
//     norm01: Offset(nx, ny),
//     srcVideoSize: const Size(640, 480),
//     canvasSize: sizeFromLayoutBuilder,
//     fit: BoxFit.cover,
//     mirror: true,
//   );
//   final pts = projectNormalizedListToCanvas(
//     norm01List: landmarks01,
//     srcVideoSize: const Size(640, 480),
//     canvasSize: sizeFromLayoutBuilder,
//     fit: BoxFit.cover,
//     mirror: true,
//   );

import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;
import 'package:flutter/widgets.dart' show BoxFit;

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

/// High-level check specialized for "face landmarks inside oval".
/// Expects [ovalPolygon] in the same canvas space as [landmarks].
bool areLandmarksWithinFaceOval(
  List<Offset>? ovalPolygon,
  List<Offset>? landmarks, {
  double eps = 1e-6,
  bool allowOnEdge = true,
  double minFractionInside = 1, // tune to your tolerance (e.g., 0.85–0.95)
  bool verbose = false,
}) {
  if (ovalPolygon == null ||
      landmarks == null ||
      ovalPolygon.length < 3 ||
      landmarks.isEmpty) {
    if (verbose) {
      // ignore: avoid_print
      print('[geom] invalid args: oval=${ovalPolygon?.length}, lm=${landmarks?.length}');
    }
    return false;
  }
  final frac = fractionInsidePolygon(
    ovalPolygon,
    landmarks,
    eps: eps,
    allowOnEdge: allowOnEdge,
  );
  if (verbose) {
    // ignore: avoid_print
    print('[geom] landmarks inside oval: ${(frac * 100).toStringAsFixed(1)}% '
        '(need ${(minFractionInside * 100).toStringAsFixed(0)}%)');
  }
  return frac >= minFractionInside;
}

 // ─────────────────────────────────────────────────────────────────────
  // Image-space → canvas-space mapping (matches rtc_pose_overlay.dart)
  // ─────────────────────────────────────────────────────────────────────

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