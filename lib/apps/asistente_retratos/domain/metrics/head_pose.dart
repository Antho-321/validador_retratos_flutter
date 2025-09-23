// lib/apps/asistente_retratos/domain/validators/yaw_pitch_roll.dart
import 'dart:math' as math;
import 'dart:ui' show Offset;

/// Optional: if you don't already have this helper in your codebase.
Offset _pxFromIdx(dynamic fl, int idx, int imgW, int imgH) {
  // Soporta lista de Offset (píxeles) o landmarks normalizados .x/.y
  final e = (fl is List) ? fl[idx] : fl.landmark[idx];
  if (e is Offset) return e; // ya está en píxeles
  return Offset((e.x as double) * imgW, (e.y as double) * imgH);
}

/// Indices (same as your Python)
const int NOSE_TIP = 1;      // alt: 4
const int CHIN = 152;
const int EYE_OUTER_R = 33;
const int EYE_OUTER_L = 263;
const int MOUTH_CORNER_R = 61;
const int MOUTH_CORNER_L = 291;

/// Return type (Dart 3 record). If you prefer, change to a class or List<double>.
({double yaw, double pitch, double roll}) yawPitchRollFromFaceMesh(
  dynamic fl,
  int imgH,
  int imgW, {
  List<List<double>>? cameraMatrix, // unused in weak perspective
  List<double>? distCoeffs,         // unused in weak perspective
}) {
  // ---- 2D image points from landmarks (pixels) ----
  final pNose  = _pxFromIdx(fl, NOSE_TIP,       imgW, imgH);
  final pChin  = _pxFromIdx(fl, CHIN,           imgW, imgH);
  final pER    = _pxFromIdx(fl, EYE_OUTER_R,    imgW, imgH);
  final pEL    = _pxFromIdx(fl, EYE_OUTER_L,    imgW, imgH);
  final pMR    = _pxFromIdx(fl, MOUTH_CORNER_R, imgW, imgH);
  final pML    = _pxFromIdx(fl, MOUTH_CORNER_L, imgW, imgH);

  final imagePts = <Offset>[pNose, pChin, pER, pEL, pMR, pML];

  // ---- 3D model points (same units as Python, scale cancels out in rotation) ----
  final modelPts = <List<double>>[
    [   0.0,    0.0,    0.0],   // nose
    [   0.0, -330.0,  -65.0],   // chin
    [ 165.0,  170.0, -135.0],   // right eye outer
    [-165.0,  170.0, -135.0],   // left eye outer
    [ 150.0, -150.0, -125.0],   // mouth right
    [-150.0, -150.0, -125.0],   // mouth left
  ];

  // ---- Build least-squares system under scaled-orthographic projection:
  // x_i = a·X_i + tx,  y_i = b·X_i + ty
  // Unknowns w = [a1,a2,a3, tx,  b1,b2,b3, ty] (8 vars)
  final n = imagePts.length;
  final A = List.generate(2 * n, (_) => List.filled(8, 0.0));
  final b = List.filled(2 * n, 0.0);

  for (var i = 0; i < n; i++) {
    final X = modelPts[i];
    final xi = imagePts[i].dx;
    final yi = imagePts[i].dy;

    // Row for x
    A[2 * i][0] = X[0];  // a1 * X
    A[2 * i][1] = X[1];  // a2 * Y
    A[2 * i][2] = X[2];  // a3 * Z
    A[2 * i][3] = 1.0;   // tx
    // zeros for b..., ty already 0
    b[2 * i] = xi;

    // Row for y
    A[2 * i + 1][4] = X[0]; // b1 * X
    A[2 * i + 1][5] = X[1]; // b2 * Y
    A[2 * i + 1][6] = X[2]; // b3 * Z
    A[2 * i + 1][7] = 1.0;  // ty
    b[2 * i + 1] = yi;
  }

  // Solve normal equations: (A^T A) w = A^T b
  final AT = _transpose(A);
  final ATA = _mulMat(AT, A);     // 8x8
  final ATb = _mulMatVec(AT, b);  // 8

  final w = _solveLinearSystem(ATA, ATb);
  if (w == null) {
    return (yaw: double.nan, pitch: double.nan, roll: double.nan);
  }

  // Extract a = s * r1 (first row of rotation), b = s * r2 (second row), tx, ty.
  final a = <double>[w[0], w[1], w[2]];
  final tx = w[3];
  final b2 = <double>[w[4], w[5], w[6]];
  final ty = w[7];

  // Orthonormalize (Gram–Schmidt) and recover scale s
  double _norm3(List<double> v) =>
      math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);

  final sa = _norm3(a);
  final sb = _norm3(b2);
  final s = (sa + sb) * 0.5;
  if (s <= 1e-9) {
    return (yaw: double.nan, pitch: double.nan, roll: double.nan);
  }

  // r1, r2 (normalized)
  var r1 = [a[0] / s, a[1] / s, a[2] / s];
  var r2 = [b2[0] / s, b2[1] / s, b2[2] / s];

  // Make r1, r2 orthonormal: r2 = normalize(r2 - (r2·r1) r1)
  final dot12 = r1[0] * r2[0] + r1[1] * r2[1] + r1[2] * r2[2];
  r2 = [r2[0] - dot12 * r1[0], r2[1] - dot12 * r1[1], r2[2] - dot12 * r1[2]];
  final nr2 = _norm3(r2);
  if (nr2 <= 1e-9) {
    return (yaw: double.nan, pitch: double.nan, roll: double.nan);
  }
  r2 = [r2[0] / nr2, r2[1] / nr2, r2[2] / nr2];

  // r3 = r1 × r2
  final r3 = [
    r1[1] * r2[2] - r1[2] * r2[1],
    r1[2] * r2[0] - r1[0] * r2[2],
    r1[0] * r2[1] - r1[1] * r2[0],
  ];

  // Rotation matrix R has rows r1, r2, r3
  final R = [
    [r1[0], r1[1], r1[2]],
    [r2[0], r2[1], r2[2]],
    [r3[0], r3[1], r3[2]],
  ];

  // Extract yaw/pitch/roll (same convention as your Python)
  final sy = math.sqrt(R[0][0] * R[0][0] + R[1][0] * R[1][0]);
  final singular = sy < 1e-6;

  late double pitch, yaw, roll;
  if (!singular) {
    pitch = _rad2deg(math.atan2(R[2][1], R[2][2]));
    yaw   = _rad2deg(math.atan2(-R[2][0], sy));
    roll  = _rad2deg(math.atan2(R[1][0], R[0][0]));
  } else {
    pitch = _rad2deg(math.atan2(-R[1][2], R[1][1]));
    yaw   = _rad2deg(math.atan2(-R[2][0], sy));
    roll  = 0.0;
  }

  return (yaw: yaw, pitch: pitch, roll: roll);
}

// ───────────────────────────── helpers ─────────────────────────────

double _rad2deg(double r) => r * (180.0 / math.pi);

List<List<T>> _transpose<T>(List<List<T>> m) {
  final rows = m.length;
  final cols = m[0].length;
  return List.generate(cols, (j) => List.generate(rows, (i) => m[i][j]));
}

List<List<double>> _mulMat(List<List<double>> A, List<List<double>> B) {
  final r = A.length, k = A[0].length, c = B[0].length;
  final out = List.generate(r, (_) => List.filled(c, 0.0));
  for (var i = 0; i < r; i++) {
    for (var j = 0; j < c; j++) {
      var s = 0.0;
      for (var t = 0; t < k; t++) {
        s += A[i][t] * B[t][j];
      }
      out[i][j] = s;
    }
  }
  return out;
}

List<double> _mulMatVec(List<List<double>> A, List<double> v) {
  final r = A.length, c = A[0].length;
  final out = List.filled(r, 0.0);
  for (var i = 0; i < r; i++) {
    var s = 0.0;
    for (var j = 0; j < c; j++) {
      s += A[i][j] * v[j];
    }
    out[i] = s;
  }
  return out;
}

/// Solve M x = y for square M (Gauss–Jordan with partial pivoting).
List<double>? _solveLinearSystem(List<List<double>> M, List<double> y) {
  final n = M.length;
  // Augment [M | y]
  final A = List.generate(n, (i) => [...M[i], y[i]]);
  for (var col = 0; col < n; col++) {
    // Pivot
    var pivot = col;
    var maxAbs = A[col][col].abs();
    for (var r = col + 1; r < n; r++) {
      final v = A[r][col].abs();
      if (v > maxAbs) {
        maxAbs = v;
        pivot = r;
      }
    }
    if (maxAbs < 1e-12) return null; // singular

    // Swap
    if (pivot != col) {
      final tmp = A[col];
      A[col] = A[pivot];
      A[pivot] = tmp;
    }

    // Normalize pivot row
    final pivVal = A[col][col];
    for (var j = col; j <= n; j++) {
      A[col][j] /= pivVal;
    }

    // Eliminate
    for (var r = 0; r < n; r++) {
      if (r == col) continue;
      final factor = A[r][col];
      if (factor == 0) continue;
      for (var j = col; j <= n; j++) {
        A[r][j] -= factor * A[col][j];
      }
    }
  }

  // Extract solution
  return List.generate(n, (i) => A[i][n]);
}
