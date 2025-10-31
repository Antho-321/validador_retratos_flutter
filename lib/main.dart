// lib/main.dart
import 'dart:async';
import 'dart:ui' show PlatformDispatcher; // ⬅️ para PlatformDispatcher.instance.onError
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart'; // ⬅️ para FlutterError, debugPrint, etc.
import 'package:get_it/get_it.dart';

import 'apps/asistente_retratos/dependencias_posture.dart';
import 'apps/asistente_retratos/domain/service/pose_capture_service.dart';
import 'apps/asistente_retratos/presentation/pages/pose_capture_page.dart';
import 'apps/asistente_retratos/presentation/styles/theme.dart';

// Habilitar/Deshabilitar dibujo de landmarks (solo rendering, NO procesamiento)
const drawLandmarks = true;

Future<void> main() async {
  // ── Ganchos globales de errores de Flutter y plataforma ────────────────────
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.dumpErrorToConsole(details);
    final st = details.stack ?? StackTrace.current;
    Zone.current.handleUncaughtError(details.exception, st);
  };

  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    // ignore: avoid_print
    print('🌍 Uncaught (platform): $error\n$stack');
    return true; // evita crash en release si procede
  };

  // ── Zona protegida: todo tu bootstrap corre aquí ───────────────────────────
  await runZonedGuarded<Future<void>>(() async {
    WidgetsFlutterBinding.ensureInitialized();
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    // Flags por entorno (puedes hardcodear si quieres)
    const bool validationsEnabled = true;
    // ip casa: 192.168.100.7
    // ip DDTI: 172.16.14.238
    const offerUrl = 'http://192.168.100.7:8000/webrtc/offer';

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
  }, (Object error, StackTrace stack) {
    // ignore: avoid_print
    print('🌍 Uncaught (zone): $error\n$stack');
  });
}

class PoseApp extends StatefulWidget {
  const PoseApp({
    super.key,
    required this.service,
    required this.validationsEnabled,
  });

  final PoseCaptureService service;
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
      theme: AsistenteTheme.light,
      darkTheme: AsistenteTheme.dark,
      themeMode: ThemeMode.dark,
      home: PoseCapturePage(
        poseService: widget.service,
        validationsEnabled: widget.validationsEnabled,
        drawLandmarks: drawLandmarks,
      ),
    );
  }
}
