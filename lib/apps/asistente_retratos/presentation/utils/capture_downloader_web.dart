// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:typed_data';

import 'capture_download_types.dart';

Future<bool> saveCaptured(
  Uint8List bytes, {
  required String filename,
  SaveProgress? onProgress,
}) async {
  onProgress?.call(0.25);

  final blob = html.Blob([bytes]);
  final url = html.Url.createObjectUrlFromBlob(blob);
  final anchor = html.AnchorElement(href: url)
    ..download = filename
    ..style.display = 'none';
  html.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
  html.Url.revokeObjectUrl(url);

  onProgress?.call(1.0);
  return true;
}
