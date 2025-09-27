// lib/apps/asistente_retratos/domain/model/lmk_state.dart
import 'dart:typed_data' show Float32List, Int32List;
import 'dart:ui' show Offset, Size;

/// Estado ligero para landmarks (cara/pose) publicado a la UI.
/// Mantiene tanto la ruta legacy (Offsets) como la rápida (Float32List planos).
/// Ahora soporta un eje Z opcional (por persona como Float32List separado).
class LmkState {
  /// Lista "legado": por persona/cara => lista de Offsets (x,y) en px.
  final List<List<Offset>>? last;

  /// Ruta rápida XY: por persona/cara => Float32List [x0,y0,x1,y1,...] en px.
  final List<Float32List>? lastFlat;

  /// Ruta rápida Z (opcional): por persona/cara => Float32List [z0,z1,...].
  /// Z viene normalizado (p.ej. z_q / (1<<POSE_Z_SHIFT)).
  final List<Float32List>? lastFlatZ;

  /// Tamaño de la imagen/origen en el que están expresados los puntos.
  final Size? imageSize;

  /// Secuencia del paquete (para shouldRepaint).
  final int lastSeq;

  /// Marca de tiempo del último update (para `isFresh`).
  final DateTime? lastTs;

  /// Buffer plano (packed) [x0,y0, x1,y1, ...] compartido entre todas las caras/personas.
  final Float32List? packedPositions;

  /// Rango de puntos por cara/persona en `packedPositions`: [start0, count0, start1, count1, ...].
  final Int32List? packedRanges;

  /// Buffer Z (packed) [z0, z1, ...] si está disponible.
  final Float32List? packedZPositions;

  const LmkState({
    this.last,
    this.lastFlat,
    this.lastFlatZ,
    this.imageSize,
    this.lastSeq = 0,
    this.lastTs,
    this.packedPositions,
    this.packedRanges,
    this.packedZPositions,
  });

  /// Estado vacío.
  factory LmkState.empty() => const LmkState(
        last: null,
        lastFlat: null,
        lastFlatZ: null,
        packedPositions: null,
        packedRanges: null,
        packedZPositions: null,
      );

  /// Construye desde Float32List por persona/cara.
  /// `z` es opcional y debe tener el mismo número de personas y puntos.
  factory LmkState.fromFlat(
    List<Float32List> peoplePx, {
    List<Float32List>? z,
    int? lastSeq,
    Size? imageSize,
  }) {
    return LmkState(
      last: null,
      lastFlat: List<Float32List>.unmodifiable(peoplePx),
      lastFlatZ: z != null ? List<Float32List>.unmodifiable(z) : null,
      imageSize: imageSize,
      lastSeq: lastSeq ?? 0,
      lastTs: DateTime.now(),
      packedPositions: null,
      packedRanges: null,
      packedZPositions: null,
    );
  }

  /// Construye desde lista de Offsets por persona/cara (solo XY).
  factory LmkState.fromLegacy(
    List<List<Offset>> peoplePx, {
    int? lastSeq,
    Size? imageSize,
  }) {
    return LmkState(
      last: peoplePx
          .map((p) => List<Offset>.unmodifiable(p))
          .toList(growable: false),
      lastFlat: null,
      lastFlatZ: null,
      imageSize: imageSize,
      lastSeq: lastSeq ?? 0,
      lastTs: DateTime.now(),
      packedPositions: null,
      packedRanges: null,
      packedZPositions: null,
    );
  }

  /// Construye desde buffers empaquetados.
  factory LmkState.fromPacked({
    required Float32List positions,
    required Int32List ranges,
    Float32List? zPositions,
    required int lastSeq,
    required Size imageSize,
  }) {
    return LmkState(
      last: null,
      lastFlat: null,
      lastFlatZ: null,
      imageSize: imageSize,
      lastSeq: lastSeq,
      lastTs: DateTime.now(),
      packedPositions: positions,
      packedRanges: ranges,
      packedZPositions: zPositions,
    );
  }

  /// Indica si hay canal Z disponible.
  bool get hasZ => (lastFlatZ != null) || (packedZPositions != null);

  /// Heurística de frescura para evitar parpadeos en la UI.
  bool get isFresh {
    if (lastTs == null) return false;
    final dt = DateTime.now().difference(lastTs!);
    return dt.inMilliseconds <= 600; // ajusta el umbral a tu gusto
  }
}
