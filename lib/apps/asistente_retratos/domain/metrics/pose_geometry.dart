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
    if (!izq.dx.isFinite || !izq.dy.isFinite ||
        !der.dx.isFinite || !der.dy.isFinite) {
      return null;
    }
    final dy = izq.dy - der.dy;
    final dx = izq.dx - der.dx;
    return math.atan2(dy, dx) * 180.0 / math.pi; // (-180..180]
  }
  return null;
}

/// Estima el azimut biacromial usando landmarks 3D (hombros 11 y 12).
/// - `zToPx`: factor para llevar ΔZ a “px” (usa tu _zToPxScale o, por defecto, el ancho de imagen).
/// - `mirror`: si la vista está espejada, invierte el signo para UX consistente.
double? estimateAzimutBiacromial3D({
  required List<dynamic>? poseLandmarks3D,
  required double zToPx,
  required bool mirror,
}) {
  if (poseLandmarks3D == null || poseLandmarks3D.length <= 12) return null;

  final ls = poseLandmarks3D[11]; // left shoulder
  final rs = poseLandmarks3D[12]; // right shoulder

  final double? rx = (rs.x as num?)?.toDouble();
  final double? lx = (ls.x as num?)?.toDouble();
  final double? rz = (rs.z as num?)?.toDouble();
  final double? lz = (ls.z as num?)?.toDouble();
  if (rx == null || lx == null || rz == null || lz == null) return null;
  if (rx.isNaN || lx.isNaN || rz.isNaN || lz.isNaN) return null;

  final double dxPx = (rx - lx).abs();
  if (dxPx <= 1e-6) return 0.0;

  final double dzPx = (rz - lz) * zToPx;

  double deg = math.atan2(dzPx, dxPx) * 180.0 / math.pi;
  if (mirror) deg = -deg;
  return deg;
}