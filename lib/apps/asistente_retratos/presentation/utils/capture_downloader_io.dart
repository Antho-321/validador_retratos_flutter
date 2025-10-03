import 'dart:typed_data';
import 'dart:io' show Platform;

import 'package:image_gallery_saver_plus/image_gallery_saver_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';

/// Save image bytes to the system gallery (Android/iOS).
Future<bool> saveCaptured(
  List<int> bytes, {
  String filename = 'retrato.png',
}) async {
  // ── iOS: request add-only permission ───────────────────────────────────────
  if (Platform.isIOS) {
    final st = await Permission.photosAddOnly.request();
    if (!st.isGranted) {
      throw StateError('NSPhotoLibraryAddUsageDescription / permission denied');
    }
  }

  // ── Android: request legacy storage ONLY on SDK <= 28 ─────────────────────
  if (Platform.isAndroid) {
    final info = await DeviceInfoPlugin().androidInfo;
    if (info.version.sdkInt <= 28) {
      final st = await Permission.storage.request();
      if (!st.isGranted) {
        throw StateError('PERMISSION_DENIED: storage (SDK <= 28)');
      }
    }
    // On SDK >= 29, no explicit permission needed for saving via MediaStore.
  }

  // ── Save to gallery ────────────────────────────────────────────────────────
  final name = filename.toLowerCase().endsWith('.png')
      ? filename.substring(0, filename.length - 4)
      : filename;

  final res = await ImageGallerySaverPlus.saveImage(
    Uint8List.fromList(bytes),
    name: name,
    quality: 100,
    isReturnImagePathOfIOS: true,
  );

  final ok = (res is Map) && (res['isSuccess'] == true || res['success'] == true);
  if (!ok) throw StateError('ImageGallerySaver failed: $res');
  return true;
}