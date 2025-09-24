// lib/apps/asistente_retratos/infrastructure/model/pose_frame.dart

// Modelo de datos usado por el servicio y la UI (sin widgets)
import 'dart:typed_data';
import 'dart:ui' show Offset, Size;

/// Lo que necesitamos para pintar/consumir un frame de pose:
/// - tamaño de la imagen del servidor
/// - poses en coordenadas de píxel:
///    * `posesPx`     → lista de Offsets por persona (legacy)
///    * `posesPxFlat` → Float32List plano [x0,y0,x1,y1,...] por persona (rápido)
class PoseFrame {
  const PoseFrame({
    required this.imageSize,
    this.posesPx,
    this.posesPxFlat,
  }) : assert(
          posesPx != null || posesPxFlat != null,
          'Debes proveer posesPx o posesPxFlat',
        );

  /// (w, h) de la imagen del servidor
  final Size imageSize;

  /// Cada pose: lista de Offsets (px, py). Mantener para compatibilidad.
  final List<List<Offset>>? posesPx;

  /// Cada pose: Float32List plano [x0,y0,x1,y1,...] en píxeles.
  /// Preferido para pintar por rendimiento (cero objetos intermedios).
  final List<Float32List>? posesPxFlat;

  /// Cantidad de personas en el frame.
  int get posesCount => posesPxFlat?.length ?? posesPx?.length ?? 0;

  /// Indica si tenemos la ruta plana optimizada.
  bool get isFlat => posesPxFlat != null;

  PoseFrame copyWith({
    Size? imageSize,
    List<List<Offset>>? posesPx,
    List<Float32List>? posesPxFlat,
  }) {
    return PoseFrame(
      imageSize: imageSize ?? this.imageSize,
      posesPx: posesPx ?? this.posesPx,
      posesPxFlat: posesPxFlat ?? this.posesPxFlat,
    );
  }
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

  // JSON → solo Offsets (ruta legacy); plano queda null.
  return PoseFrame(imageSize: Size(w, h), posesPx: posesPx);
}