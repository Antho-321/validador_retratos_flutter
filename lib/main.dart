// lib/main.dart
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'features/posture/services/posture_camera_service.dart';
import 'features/posture/presentation/posture_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final cameras = await availableCameras();

  final camService = PostureCameraService();
  await camService.init(cameras);

  runApp(PostureValidationApp(cameraService: camService));
}

class PostureValidationApp extends StatelessWidget {
  const PostureValidationApp({super.key, required this.cameraService});
  final PostureCameraService cameraService;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: PostureScreen(cameraService: cameraService),
    );
  }
}
