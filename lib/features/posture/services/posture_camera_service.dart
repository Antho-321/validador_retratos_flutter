// lib/features/posture/services/posture_camera_service.dart
import 'package:camera/camera.dart';

class PostureCameraService {
  late final CameraController controller;

  Future<void> init(List<CameraDescription> cameras) async {
    // Prefer front camera if available
    final CameraDescription camera = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );

    controller = CameraController(
      camera,
      ResolutionPreset.low,                    // keep it light
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );

    await controller.initialize();

    // Optional: narrower FPS range helps older phones
    // ignore: avoid_print
    print('Camera initialized: ${controller.description.name}');
  }

  Future<void> dispose() async {
    if (controller.value.isStreamingImages) {
      await controller.stopImageStream();
    }
    await controller.dispose();
  }
}
