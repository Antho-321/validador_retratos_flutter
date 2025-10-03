// capture_downloader_io.dart
import 'dart:io' show File, Platform;
import 'dart:typed_data';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:file_saver/file_saver.dart';
import 'package:permission_handler/permission_handler.dart';

/// Save bytes into **Downloads**.
/// - Android ≥29: uses MediaStore → Downloads via `file_saver` (no extra permission).
/// - Android ≤28: asks legacy storage; tries `file_saver`, else writes to /storage/emulated/0/Download.
/// - iOS: shows the Files “Save to…” sheet.
Future<bool> saveCaptured(
  List<int> bytes, {
  String filename = 'retrato.png',
}) async {
  final Uint8List data = Uint8List.fromList(bytes);

  // Normalize name + extension
  final dot = filename.lastIndexOf('.');
  final String name = (dot > 0) ? filename.substring(0, dot) : filename;
  final String ext = (dot > 0 ? filename.substring(dot + 1) : 'png').toLowerCase();

  if (Platform.isAndroid) {
    final sdk = (await DeviceInfoPlugin().androidInfo).version.sdkInt;

    if (sdk <= 28) {
      // Android 9 and below: need legacy storage permission for public Downloads
      final st = await Permission.storage.request();
      if (!st.isGranted) {
        throw StateError('PERMISSION_DENIED: storage (SDK <= 28)');
      }

      // Try FileSaver first
      final saved = await FileSaver.instance.saveAs(
        name: name,
        bytes: data,
        ext: ext, // <-- use `ext`, not `fileExtension`
        mimeType: _mimeFromExt(ext),
      );
      if (saved != null && saved.toString().isNotEmpty) return true;

      // Fallback: write directly to the public Downloads directory
      const downloads = '/storage/emulated/0/Download';
      final f = File('$downloads/$name.$ext');
      await f.writeAsBytes(data, flush: true);
      return true;
    } else {
      // Android 10+ via MediaStore → Downloads (no extra permission)
      final saved = await FileSaver.instance.saveAs(
        name: name,
        bytes: data,
        ext: ext, // <-- use `ext`
        mimeType: _mimeFromExt(ext),
      );
      if (saved != null && saved.toString().isNotEmpty) return true;
      throw StateError('FileSaver failed on Android >=29');
    }
  }

  if (Platform.isIOS) {
    // Files “Save to…” sheet (user can choose Downloads/iCloud or any folder)
    final saved = await FileSaver.instance.saveAs(
      name: name,
      bytes: data,
      ext: ext, // <-- use `ext`
      mimeType: _mimeFromExt(ext),
    );
    if (saved != null && saved.toString().isNotEmpty) return true;
    throw StateError('FileSaver failed on iOS');
  }

  throw UnsupportedError('saveCaptured not implemented for this platform');
}

MimeType _mimeFromExt(String ext) {
  switch (ext.toLowerCase()) {
    case 'png':
      return MimeType.png;
    case 'jpg':
    case 'jpeg':
      return MimeType.jpeg;
    case 'pdf':
      return MimeType.pdf;
    default:
      return MimeType.other;
  }
}