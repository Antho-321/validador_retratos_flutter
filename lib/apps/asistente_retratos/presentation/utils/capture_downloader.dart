import 'dart:typed_data';

import 'capture_downloader_stub.dart'
    if (dart.library.html) 'capture_downloader_web.dart' as impl;

Future<bool> saveCapturedPortrait(
  Uint8List bytes, {
  String filename = 'retrato.png',
}) {
  return impl.saveCaptured(bytes, filename: filename);
}
