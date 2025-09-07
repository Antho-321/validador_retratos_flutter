// lib/main.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'features/posture/services/pose_webrtc_service.dart';
import 'features/posture/presentation/pages/pose_capture_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

  // ⇣ Nuevo: flag global (puedes cambiarlo por env var o hardcodear)
  const bool validationsEnabled = bool.fromEnvironment(
    'POSE_VALIDATIONS',
    defaultValue: true, // pon false para desactivar validaciones
  );

  final offerUrl = const String.fromEnvironment(
    'POSE_WEBRTC_URL',
    defaultValue: 'http://192.168.100.5:8000/webrtc/offer',
    //defaultValue: 'http://192.168.1.103:8000/webrtc/offer',
  );

  final poseService = PoseWebRTCService(
    offerUri: Uri.parse(offerUrl),
    facingMode: 'user',
    idealWidth: 640,
    idealHeight: 480,
    idealFps: 15,
    logEverything: false,
  );

  await poseService.init();
  unawaited(poseService.connect());

  runApp(PoseApp(
    poseService: poseService,
    validationsEnabled: validationsEnabled, // ⇐ pásalo
  ));
}

class PoseApp extends StatefulWidget {
  const PoseApp({
    super.key,
    required this.poseService,
    required this.validationsEnabled,
  });

  final PoseWebRTCService poseService;
  final bool validationsEnabled; // ⇠ nuevo

  @override
  State<PoseApp> createState() => _PoseAppState();
}

class _PoseAppState extends State<PoseApp> {
  @override
  void dispose() {
    widget.poseService.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: PoseCapturePage(
        poseService: widget.poseService,
        validationsEnabled: widget.validationsEnabled, // ⇐ pásalo a la página
      ),
    );
  }
}
