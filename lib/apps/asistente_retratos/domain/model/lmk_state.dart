// lib/apps/asistente_retratos/domain/model/lmk_state.dart
import 'dart:typed_data' show Float32List;
import 'dart:ui' show Offset, Size;

/// Estado ligero para landmarks (cara/pose) publicado a la UI.
/// Mantiene tanto la ruta legacy (Offsets) como las rutas rápidas 2D (XY) y 3D (XYZ).
class LmkState {
  /// Lista "legado": por persona/cara => lista de Offsets (x,y) en px.
  final List<List<Offset>>? last;

  /// Ruta rápida 2D: por persona/cara => Float32List [x0,y0,x1,y1,...] en px.
  final List<Float32List>? lastFlat;

  /// Ruta rápida 3D: por persona/cara => Float32List [x0,y0,z0,x1,y1,z1,...].
  /// Nota: X/Y suelen estar en px (o ya escalados); Z depende de la tarea (relativo).
  final List<Float32List>? lastFlat3d;

  /// Tamaño de la imagen/origen en el que están expresados los puntos.
  final Size? imageSize;

  /// Secuencia del paquete (para shouldRepaint).
  final int lastSeq;

  /// Marca de tiempo del último update (para `isFresh`).
  final DateTime? lastTs;

  const LmkState({
    this.last,
    this.lastFlat,
    this.lastFlat3d,
    this.imageSize,
    this.lastSeq = 0,
    this.lastTs,
  });

  /// Estado vacío.
  factory LmkState.empty() => const LmkState(
        last: null,
        lastFlat: null,
        lastFlat3d: null,
        imageSize: null,
        lastSeq: 0,
        lastTs: null,
      );

  /// Construye desde Float32List 2D por persona/cara (XY).
  factory LmkState.fromFlat(
    List<Float32List> peoplePx, {
    int? lastSeq,
    Size? imageSize,
  }) {
    return LmkState(
      last: null,
      lastFlat: List<Float32List>.unmodifiable(peoplePx),
      lastFlat3d: null,
      imageSize: imageSize,
      lastSeq: lastSeq ?? 0,
      lastTs: DateTime.now(),
    );
  }

  /// Construye desde Float32List 3D por persona/cara (XYZ).
  factory LmkState.fromFlat3d(
    List<Float32List> peoplePx3d, {
    int? lastSeq,
    Size? imageSize,
  }) {
    return LmkState(
      last: null,
      lastFlat: null,
      lastFlat3d: List<Float32List>.unmodifiable(peoplePx3d),
      imageSize: imageSize,
      lastSeq: lastSeq ?? 0,
      lastTs: DateTime.now(),
    );
  }

  /// Construye desde lista de Offsets por persona/cara (legacy XY).
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
      lastFlat3d: null,
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

  /// Utilidad para clonar con cambios puntuales (mantiene inmutabilidad).
  LmkState copyWith({
    List<List<Offset>>? last,
    List<Float32List>? lastFlat,
    List<Float32List>? lastFlat3d,
    Size? imageSize,
    int? lastSeq,
    DateTime? lastTs,
    bool clearLast = false,
    bool clearFlat2d = false,
    bool clearFlat3d = false,
  }) {
    return LmkState(
      last: clearLast ? null : (last ?? this.last),
      lastFlat: clearFlat2d ? null : (lastFlat ?? this.lastFlat),
      lastFlat3d: clearFlat3d ? null : (lastFlat3d ?? this.lastFlat3d),
      imageSize: imageSize ?? this.imageSize,
      lastSeq: lastSeq ?? this.lastSeq,
      lastTs: lastTs ?? this.lastTs,
    );
  }
}
