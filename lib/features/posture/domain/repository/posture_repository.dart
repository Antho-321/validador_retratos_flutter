// lib/features/posture/domain/repository/posture_repository.dart
import 'dart:typed_data';

abstract class PostureRepository {
  Future<void> start();               // inicia (init + connect)
  Future<void> stop();                // cierra
  Stream<bool> onStreamAlive();       // emite true cuando llegan frames
  Future<void> processFrame(Uint8List frameBytes); // si lo necesitas, si no, quítalo
}
