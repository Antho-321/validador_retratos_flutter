import 'dart:typed_data';

import 'capture_download_types.dart';
import 'capture_downloader_stub.dart'
    if (dart.library.html) 'capture_downloader_web.dart'
    if (dart.library.io) 'capture_downloader_io.dart' as impl;

Future<bool> saveCapturedPortrait(
  Uint8List bytes, {
  String filename = 'retrato.jpg',
  SaveProgress? onProgress,
}) {
  onProgress?.call(0.0);
  return impl.saveCaptured(
    bytes,
    filename: filename,
    onProgress: onProgress,
  );
}
