// capture_downloader_io.dart
import 'dart:io' show File, Platform;
import 'dart:typed_data';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:file_saver/file_saver.dart';                  // iOS picker
import 'package:media_store_plus/media_store_plus.dart';      // Android MediaStore
import 'package:path_provider/path_provider.dart';            // temp file
import 'package:permission_handler/permission_handler.dart';

/// Save bytes into **Downloads** automatically on Android (no picker).
/// - Android: MediaStore → Downloads (scoped storage safe).
/// - iOS: shows Files “Save to…” sheet (no true auto-Downloads on iOS).
Future<bool> saveCaptured(
  List<int> bytes, {
  String filename = 'retrato.png',
}) async {
  final data = Uint8List.fromList(bytes);

  // Normalize name + extension
  final dot = filename.lastIndexOf('.');
  final String name = (dot > 0) ? filename.substring(0, dot) : filename;
  final String ext  = (dot > 0 ? filename.substring(dot + 1) : 'png').toLowerCase();

  if (Platform.isAndroid) {
    // Initialize MediaStore
    await MediaStore.ensureInitialized();

    // Optional: put files under "Downloads/<appFolder>/"
    // If you want plain "Downloads/" root, leave relativePath = FilePath.root below.
    MediaStore.appFolder = "AsistenteRetratos";

    final sdk = (await DeviceInfoPlugin().androidInfo).version.sdkInt;

    // Legacy permission (Android 10 and below) for shared storage
    if (sdk <= 29) {
      final st = await Permission.storage.request();
      if (!st.isGranted) {
        throw StateError('PERMISSION_DENIED: storage (SDK <= 29)');
      }
    }

    // Write to a temp file first (MediaStore API takes a file path)
    final tmpDir = await getTemporaryDirectory();
    final tmpPath = '${tmpDir.path}/$name.$ext';
    await File(tmpPath).writeAsBytes(data, flush: true);

    // Save directly into the public Downloads collection (no UI)
    final ms = MediaStore();
    final info = await ms.saveFile(
      tempFilePath: tmpPath,
      dirType: DirType.download,
      dirName: DirName.download,
      // Use FilePath.root to place directly under "Downloads/"
      // Or provide a subfolder path: 'AsistenteRetratos' to use "Downloads/AsistenteRetratos/"
      relativePath: FilePath.root,
    );

    if (info != null && info.isSuccessful) return true;
    throw StateError('MediaStore save failed: $info');
  }

  if (Platform.isIOS) {
    // iOS cannot auto-save to a public "Downloads" silently.
    // Present Files sheet so user picks a location.
    final saved = await FileSaver.instance.saveAs(
      name: name,
      bytes: data,
      ext: ext,                    // note: `ext` is the correct named arg for this version
      mimeType: _mimeFromExt(ext),
    );
    if (saved != null && saved.toString().isNotEmpty) return true;
    throw StateError('FileSaver failed on iOS');
  }

  throw UnsupportedError('saveCaptured not implemented for this platform');
}

MimeType _mimeFromExt(String ext) {
  switch (ext.toLowerCase()) {
    case 'png':  return MimeType.png;
    case 'jpg':
    case 'jpeg': return MimeType.jpeg;
    case 'pdf':  return MimeType.pdf;
    default:     return MimeType.other;
  }
}