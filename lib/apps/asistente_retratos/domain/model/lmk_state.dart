// lib/apps/asistente_retratos/domain/model/lmk_state.dart
import 'dart:typed_data' show Float32List;
import 'dart:ui' show Offset;

/// Estado ligero para landmarks de cara publicado a la UI.
/// Mantiene tanto la ruta legacy (Offsets) como la rápida (Float32List planos).
class LmkState {
  /// Landmarks como lista de Offsets por cara (ruta legacy).
  List<List<Offset>>? last;

  /// Landmarks como Float32List plano por cara [x0,y0,x1,y1,...] (ruta rápida).
  List<Float32List>? lastFlat;

  /// Último número de secuencia recibido (PO/PD).
  int lastSeq;

  /// Marca de tiempo del último update.
  DateTime lastTs;

  LmkState({
    this.last,
    this.lastFlat,
    this.lastSeq = -1,
    DateTime? lastTs,
  }) : lastTs = lastTs ?? DateTime.fromMillisecondsSinceEpoch(0);

  bool get isFresh =>
      DateTime.now().difference(lastTs) < const Duration(milliseconds: 400);
}
