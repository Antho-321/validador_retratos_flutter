// Lightweight 3D point for pose landmarks. `z` may be null on XY-only packets.
class PosePoint {
  final double x, y;
  final double? z;
  const PosePoint(this.x, this.y, [this.z]);
}
