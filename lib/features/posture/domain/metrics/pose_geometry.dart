// lib/features/posture/domain/metrics/pose_geometry.dart
import 'dart:math' as math;
import 'dart:ui' show Offset;

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
