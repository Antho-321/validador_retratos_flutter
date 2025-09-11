// lib/apps/asistente_retratos/infrastructure/model/pose_point.dart
class PosePoint {
  final double x;
  final double y;
  final double? z; // opcional si llega 3D
  const PosePoint({required this.x, required this.y, this.z});
}
