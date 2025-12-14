// lib/apps/asistente_retratos/infrastructure/model/images_rx.dart
import 'dart:typed_data';

class ImagesRx {
  final String requestId;
  final String format;     // 'png'
  final Uint8List bytes;
  final bool? okHash;      // verificación hash (opcional)
  final bool? okSize;      // verificación tamaño (opcional)

  ImagesRx({
    required this.requestId,
    required this.format,
    required this.bytes,
    this.okHash,
    this.okSize,
  });

  @override
  String toString() =>
      'ImagesRx(requestId=$requestId, fmt=$format, bytes=${bytes.length}, okHash=$okHash, okSize=$okSize)';
}
