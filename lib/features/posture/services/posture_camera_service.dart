// lib/features/posture/services/posture_camera_service.dart
import 'package:camera/camera.dart';
import 'package:flutter/services.dart';

class PostureCameraService {
  static const MethodChannel _cameraChannel =
      MethodChannel('posture_camera/config');

  late final CameraController controller;

  Future<void> init(List<CameraDescription> cameras) async {
    final front = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );

    controller = CameraController(
      front,
      ResolutionPreset.high,
      enableAudio: false,
    );

    await controller.initialize();
    await _configureCameraMirroring(front.lensDirection == CameraLensDirection.front);
  }

  Future<void> _configureCameraMirroring(bool isFront) async {
    if (!isFront) return;
    try {
      await _cameraChannel.invokeMethod('setMirrorMode', {
        'enable': false, // vista natural (sin espejo)
        'cameraId': controller.description.name,
      });
      // ignore: avoid_print
      print('Camera mirroring configured successfully');
    } catch (e) {
      // ignore: avoid_print
      print('Failed to configure camera mirroring: $e');
      // Fallback en UI si quieres (Transform), aquí no hace falta.
    }
  }

  void dispose() {
    controller.dispose();
  }
}
