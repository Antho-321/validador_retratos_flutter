// lib/features/posture/infrastructure/model/pose_frame.dart

// Modelo de datos usado por el servicio y la UI (sin widgets)
import 'dart:ui' show Offset, Size;

/// Lo que necesitamos para pintar/consumir un frame de pose:
/// - tamaño de la imagen del servidor
/// - poses en coordenadas de píxel (lista de 33 Offsets por persona)
class PoseFrame {
  const PoseFrame({
    required this.imageSize,
    required this.posesPx,
  });

  final Size imageSize;               // (w, h) de la imagen del servidor
  final List<List<Offset>> posesPx;   // cada pose: lista de Offsets (px, py)
}

/// Convierte el JSON del servidor a PoseFrame.
/// Espera: {"poses":[[{"x":..,"y":..,"px":..,"py":..}, ...], ...],
///          "image_size":{"w":W,"h":H}}
PoseFrame? poseFrameFromMap(Map<String, dynamic>? m) {
  if (m == null) return null;
  final img = m['image_size'] as Map<String, dynamic>?;
  if (img == null) return null;

  final w = (img['w'] as num).toDouble();
  final h = (img['h'] as num).toDouble();

  final rawPoses = (m['poses'] as List?) ?? const [];
  final posesPx = <List<Offset>>[];

  for (final p in rawPoses) {
    final pts = <Offset>[];
    for (final lm in (p as List)) {
      final map = (lm as Map<String, dynamic>);
      // Preferimos px/py; si no están, calculamos desde x,y normalizados
      final px = (map['px'] ?? ((map['x'] as num?) ?? 0) * w) as num;
      final py = (map['py'] ?? ((map['y'] as num?) ?? 0) * h) as num;
      pts.add(Offset(px.toDouble(), py.toDouble()));
    }
    posesPx.add(pts);
  }

  return PoseFrame(imageSize: Size(w, h), posesPx: posesPx);
}
