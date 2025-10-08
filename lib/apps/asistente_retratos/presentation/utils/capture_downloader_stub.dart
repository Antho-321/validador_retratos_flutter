import 'dart:typed_data';

import 'capture_download_types.dart';

Future<bool> saveCaptured(
  Uint8List bytes, {
  required String filename,
  SaveProgress? onProgress,
}) async {
  onProgress?.call(1.0);
  return false;
}
