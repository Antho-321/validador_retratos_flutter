// lib/main.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'features/posture/services/pose_webrtc_service.dart';
import 'features/posture/presentation/pages/pose_capture_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Optional: immersive full-screen (keep if you liked it)
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  // Optional: lock portrait for portrait capture flows
  // await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

  final offerUrl = const String.fromEnvironment(
    'POSE_WEBRTC_URL',
    defaultValue: 'http://192.168.100.5:8000/webrtc/offer',
  );

  final poseService = PoseWebRTCService(
    offerUri: Uri.parse(offerUrl),
    facingMode: 'user',
    idealWidth: 640,
    idealHeight: 480,
    idealFps: 15,
    logEverything: false, // keep logs quiet
  );

  await poseService.init();
  unawaited(poseService.connect());

  runApp(PoseApp(poseService: poseService));
}

class PoseApp extends StatefulWidget {
  const PoseApp({super.key, required this.poseService});
  final PoseWebRTCService poseService;

  @override
  State<PoseApp> createState() => _PoseAppState();
}

class _PoseAppState extends State<PoseApp> {
  @override
  void dispose() {
    // ensure we tear everything down
    widget.poseService.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      // Hand off UI to the new page that includes camera, overlay, and HUD
      home: PoseCapturePage(poseService: widget.poseService),
    );
  }
}
