// lib/apps/asistente_retratos/domain/model/lmk_state.dart
import 'dart:typed_data' show Float32List;
import 'dart:ui' show Offset, Size;

/// Estado ligero para landmarks (cara/pose) publicado a la UI.
/// Mantiene tanto la ruta legacy (Offsets) como la rápida (Float32List planos).
class LmkState {
  /// Lista "legado": por persona/cara => lista de Offsets (x,y) en px.
  final List<List<Offset>>? last;

  /// Ruta rápida: por persona/cara => Float32List [x0,y0,x1,y1,...] en px.
  final List<Float32List>? lastFlat;

  /// Tamaño de la imagen/origen en el que están expresados los puntos.
  final Size? imageSize;

  /// Secuencia del paquete (para shouldRepaint).
  final int lastSeq;

  /// Marca de tiempo del último update (para `isFresh`).
  final DateTime? lastTs;

  const LmkState({
    this.last,
    this.lastFlat,
    this.imageSize,
    this.lastSeq = 0,
    this.lastTs,
  });

  /// Estado vacío.
  factory LmkState.empty() => const LmkState(last: null, lastFlat: null);

  /// Construye desde Float32List por persona/cara.
  factory LmkState.fromFlat(
    List<Float32List> peoplePx, {
    int? lastSeq,
    Size? imageSize,
  }) {
    return LmkState(
      last: null,
      lastFlat: List<Float32List>.unmodifiable(peoplePx),
      imageSize: imageSize,
      lastSeq: lastSeq ?? 0,
      lastTs: DateTime.now(),
    );
  }

  /// Construye desde lista de Offsets por persona/cara.
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
      imageSize: imageSize,
      lastSeq: lastSeq ?? 0,
      lastTs: DateTime.now(),
    );
  }

  /// Heurística de frescura para evitar parpadeos en la UI.
  bool get isFresh {
    if (lastTs == null) return false;
    final dt = DateTime.now().difference(lastTs!);
    return dt.inMilliseconds <= 600; // ajusta el umbral a tu gusto
  }
}