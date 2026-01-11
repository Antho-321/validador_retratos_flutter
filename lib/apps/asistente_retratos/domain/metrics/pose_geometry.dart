// lib/apps/asistente_retratos/domain/metrics/pose_geometry.dart

import 'dart:math' as math;
import 'dart:ui' show Offset, Size;
import 'package:flutter/painting.dart' show BoxFit;

/// 🔁 Mapea puntos del espacio de imagen (px) al canvas, respetando BoxFit y mirror.
/// (Extraído desde PortraitValidator para reutilizarlo también aquí y en el validador)
List<Offset> mapImagePointsToCanvas({
  required List<Offset> points,
  required Size imageSize,
  required Size canvasSize,
  required bool mirror,
  BoxFit fit = BoxFit.cover,
}) {
  final iw = imageSize.width;
  final ih = imageSize.height;
  final cw = canvasSize.width;
  final ch = canvasSize.height;

  double scale, dx, dy, sw, sh;

  double _min(double a, double b) => (a < b) ? a : b;
  double _max(double a, double b) => (a > b) ? a : b;

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

double? calcularAnguloHombros(
  List<Offset> puntosPose, {
  int idxHombroIzq = 11,
  int idxHombroDer = 12,
}) {
  final maxIndex = math.max(idxHombroIzq, idxHombroDer);
  if (puntosPose.length > maxIndex) {
    final izq = puntosPose[idxHombroIzq];
    final der = puntosPose[idxHombroDer];
    final dy = izq.dy - der.dy;
    final dx = izq.dx - der.dx;
    return math.atan2(dy, dx) * 180.0 / math.pi; // (-180..180]
  }
  return null;
}

/// Estima el azimut biacromial usando landmarks 3D (hombros 11 y 12).
/// - `xToPx`: factor para llevar ΔX a "px" (e.g., imageWidth si x es normalizado).
/// - `zToPx`: factor para llevar ΔZ a "px" (e.g., imageWidth si z está en "image-width units").
/// - `mirror`: si la vista está espejada, invierte el signo para UX consistente.
/// - `invertZ`: toggle para invertir eje Z después de calibración real.
double? estimateAzimutBiacromial3D({
  required List<dynamic>? poseLandmarks3D,
  required double xToPx,
  required double zToPx,
  required bool mirror,
  bool invertZ = false,
}) {
  if (poseLandmarks3D == null || poseLandmarks3D.length <= 12) return null;

  final ls = poseLandmarks3D[11]; // left shoulder
  final rs = poseLandmarks3D[12]; // right shoulder

  final lx = (ls.x as num?)?.toDouble();
  final rx = (rs.x as num?)?.toDouble();
  final lz = (ls.z as num?)?.toDouble();
  final rz = (rs.z as num?)?.toDouble();
  if (lx == null || rx == null || lz == null || rz == null) return null;

  // Keep units consistent
  double dx = (rx - lx) * xToPx;
  double dz = (rz - lz) * zToPx;
  if (invertZ) dz = -dz;

  const eps = 1e-6;
  double deg;
  if (dx.abs() < eps) {
    deg = (dz >= 0) ? 90.0 : -90.0;
  } else {
    deg = math.atan2(dz, dx) * 180.0 / math.pi;
  }

  if (mirror) deg = -deg;
  return deg;
}

/// Normaliza el ángulo de azimut para que 0° represente "mirando a la cámara".
/// 
/// El cálculo raw de `estimateAzimutBiacromial3D` devuelve valores cerca de ±180°
/// cuando el usuario mira a la cámara (hombros paralelos al plano de la imagen).
/// Esta función convierte ese valor a una desviación desde 180°:
/// - 0° = perfectamente de frente a la cámara
/// - valores positivos = torso girado hacia un lado
/// - valores negativos = torso girado hacia el otro lado
/// 
/// El resultado está en el rango (-180°, 180°].
double normalizeAzimutTo180(double rawAzimutDeg) {
  // Envolver a (-180, 180] relativo a 180°
  double delta = rawAzimutDeg - 180.0;
  // Normalizar a (-180, 180]
  while (delta > 180.0) delta -= 360.0;
  while (delta <= -180.0) delta += 360.0;
  return delta;
}