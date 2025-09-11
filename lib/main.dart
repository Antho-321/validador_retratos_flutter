// lib/main.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';

import 'apps/guia_retrato/dependencias_posture.dart';
import 'apps/guia_retrato/domain/service/pose_capture_service.dart';
import 'apps/guia_retrato/presentation/pages/pose_capture_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

  // Flags por entorno (puedes hardcodear si quieres)
  const bool validationsEnabled = bool.fromEnvironment(
    'POSE_VALIDATIONS',
    defaultValue: true,
  );

  final offerUrl = const String.fromEnvironment(
    'POSE_WEBRTC_URL',
    defaultValue: 'http://192.168.100.5:8000/webrtc/offer',
  );

  // 1) Registrar dependencias (pasa la config del servicio aquí)
  registrarDependenciasPosture(
    offerUri: Uri.parse(offerUrl),
    logEverything: false,
  );

  // 2) Obtener el servicio por contrato e iniciarlo
  final poseService = GetIt.I<PoseCaptureService>();
  await poseService.init();
  unawaited(poseService.connect());

  // 3) Lanzar la app
  runApp(PoseApp(
    service: poseService,
    validationsEnabled: validationsEnabled,
  ));
}

class PoseApp extends StatefulWidget {
  const PoseApp({
    super.key,
    required this.service,
    required this.validationsEnabled,
  });

  final PoseCaptureService service;   // ← usa el contrato, no la implementación
  final bool validationsEnabled;

  @override
  State<PoseApp> createState() => _PoseAppState();
}

class _PoseAppState extends State<PoseApp> {
  @override
  void dispose() {
    widget.service.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: PoseCapturePage(
        poseService: widget.service,          // ← la página debe aceptar el contrato
        validationsEnabled: widget.validationsEnabled,
      ),
    );
  }
}
