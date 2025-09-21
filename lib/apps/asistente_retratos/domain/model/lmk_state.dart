// lib/apps/asistente_retratos/domain/model/lmk_state.dart
import 'dart:ui' show Offset;

class LmkState {
  List<List<Offset>>? last;   // mutable para poder hacer hold-last sin recrear objeto
  int lastSeq;                // mutable (se actualiza en cada PD/PO)
  DateTime lastTs;            // mutable (marca de tiempo del último update)

  LmkState({
    this.last,
    this.lastSeq = -1,
    DateTime? lastTs,
  }) : lastTs = lastTs ?? DateTime.fromMillisecondsSinceEpoch(0);

  bool get isFresh =>
      DateTime.now().difference(lastTs) < const Duration(milliseconds: 400);
}
