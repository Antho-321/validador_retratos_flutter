// capture_downloader_io.dart
import 'dart:io' show File, Platform;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:file_saver/file_saver.dart';                  // iOS picker
import 'package:media_store_plus/media_store_plus.dart';      // Android MediaStore
import 'package:path_provider/path_provider.dart';            // temp file
import 'package:permission_handler/permission_handler.dart';

import 'capture_download_types.dart';

/// Save bytes into **Downloads** automatically on Android (no picker).
/// - Android: MediaStore → Downloads (scoped storage safe).
/// - iOS: shows Files “Save to…” sheet (no true auto-Downloads on iOS).
Future<bool> saveCaptured(
  List<int> bytes, {
  String filename = 'retrato.jpg',
  SaveProgress? onProgress,
}) async {
  final data = Uint8List.fromList(bytes);

  // Normalize name + extension
  final dot = filename.lastIndexOf('.');
  final String name = (dot > 0) ? filename.substring(0, dot) : filename;
  final String ext  = (dot > 0 ? filename.substring(dot + 1) : 'jpg').toLowerCase();

  if (Platform.isAndroid) {
    // Initialize MediaStore
    await MediaStore.ensureInitialized();

    // Optional: put files under "Downloads/<appFolder>/"
    // If you want plain "Downloads/" root, leave relativePath = FilePath.root below.
    MediaStore.appFolder = "AsistenteRetratos";

    final sdk = (await DeviceInfoPlugin().androidInfo).version.sdkInt;

    // Legacy permission (Android 9 and below) for shared storage
    // (Android 10+ uses scoped storage; MediaStore writes don't need this)
    if (sdk <= 28) {
      final st = await Permission.storage.request();
      if (!st.isGranted) {
        throw StateError('PERMISSION_DENIED: storage (SDK <= 28)');
      }
    }

    // Write to a temp file first (MediaStore API takes a file path)
    final tmpDir = await getTemporaryDirectory();
    final tmpPath = '${tmpDir.path}/$name.$ext';
    final tmpFile = File(tmpPath);
    final sink = tmpFile.openWrite();
    const chunkSize = 64 * 1024;
    final total = data.length;
    for (var offset = 0; offset < total; offset += chunkSize) {
      final end = math.min(offset + chunkSize, total);
      sink.add(data.sublist(offset, end));
      onProgress?.call(0.8 * (end / total));
      await Future<void>.delayed(Duration.zero);
    }
    await sink.flush();
    await sink.close();

    onProgress?.call(0.9);

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

    // `SaveInfo.isSuccessful` is `false` when the file is saved as a duplicate
    // (e.g. "file (1).jpg") because the original name couldn't be replaced.
    // That is still a successful save for the user, so treat any non-null
    // `SaveInfo` as success.
    if (info != null) {
      onProgress?.call(1.0);
      return true;
    }
    throw StateError('MediaStore save failed: $info');
  }

  if (Platform.isIOS) {
    // iOS cannot auto-save to a public "Downloads" silently.
    // Present Files sheet so user picks a location.
    onProgress?.call(0.5);
    final saved = await FileSaver.instance.saveAs(
      name: name,
      bytes: data,
      ext: ext,                    // note: `ext` is the correct named arg for this version
      mimeType: _mimeFromExt(ext),
    );
    if (saved != null && saved.toString().isNotEmpty) {
      onProgress?.call(1.0);
      return true;
    }
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
