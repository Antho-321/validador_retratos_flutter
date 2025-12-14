// lib/main.dart
import 'dart:async';
import 'dart:ui' show PlatformDispatcher; // ⬅️ para PlatformDispatcher.instance.onError
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'apps/asistente_retratos/dependencias_posture.dart';
import 'apps/asistente_retratos/domain/service/pose_capture_service.dart';
import 'apps/asistente_retratos/infrastructure/model/images_rx.dart';
import 'apps/asistente_retratos/presentation/pages/pose_capture_page.dart';
import 'apps/asistente_retratos/presentation/styles/theme.dart';

// Habilitar/Deshabilitar dibujo de landmarks (solo rendering, NO procesamiento)
const drawLandmarks = true;
const validationsEnabled = true;

const exampleValidationJson = r'''
{
  "cedula": "1050298650",
  "nacionalidad": "ecuatoriana",
  "etnia": "mestiza",
  "metadatos": {
    "valido": "True",
    "nombre": "1050298650",
    "extension": ".png",
    "formato": "PNG",
    "ancho": 375,
    "alto": 425,
    "peso": 56565
  },
  "fondo": {
    "valido": "True",
    "porcentaje_blanco": 34.15780392156863,
    "h": 0,
    "s": 0,
    "l": 100
  },
  "rostro": {
    "valido": "True"
  },
  "postura_cuerpo": {
    "valido": "True"
  },
  "postura_rostro": {
    "valido": "True"
  },
  "color_vestimenta": {
    "valido": "True"
  },
  "observaciones": "",
  "valido": "True"
}
''';

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
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky));
    runApp(const PoseApp());
  }, (Object error, StackTrace stack) {
    // ignore: avoid_print
    print('🌍 Uncaught (zone): $error\n$stack');
  });
}

class PoseApp extends StatefulWidget {
  const PoseApp({super.key});

  @override
  State<PoseApp> createState() => _PoseAppState();
}

class _PoseAppState extends State<PoseApp> {
  PoseCaptureService? _poseService;
  StreamSubscription<ImagesRx>? _imagesProcessedSubscription;
  Object? _bootstrapError;
  bool _bootstrapping = true;
  bool _bootstrapStarted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_bootstrapStarted) return;
      _bootstrapStarted = true;
      unawaited(_bootstrap());
    });
  }

  Future<void> _bootstrap() async {
    try {
      await dotenv.load(fileName: '.env');

      final offerUrl = dotenv.env['WEBRTC_OFFER_URL'];
      if (offerUrl == null || offerUrl.isEmpty) {
        throw Exception('WEBRTC_OFFER_URL not found in .env');
      }

      final cedula = dotenv.env['CEDULA']?.trim();

      if (!GetIt.I.isRegistered<PoseCaptureService>()) {
        registrarDependenciasPosture(
          offerUri: Uri.parse(offerUrl),
          cedula: cedula,
          logEverything: false,
        );
      }

      final poseService = GetIt.I<PoseCaptureService>();
      await poseService.init();

      if (!mounted) {
        await poseService.dispose();
        return;
      }

      final imagesProcessedSub = poseService.imagesProcessed.listen((metadata) {
        if (!kDebugMode) return;
        debugPrint('Pose metadata: $metadata');
      });

      setState(() {
        _poseService = poseService;
        _imagesProcessedSubscription = imagesProcessedSub;
        _bootstrapError = null;
        _bootstrapping = false;
      });

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(
          poseService.connect().catchError((Object error, StackTrace stack) {
            debugPrint('PoseService connect error: $error\n$stack');
          }),
        );
      });
    } catch (error, stack) {
      debugPrint('App bootstrap error: $error\n$stack');
      if (!mounted) return;
      setState(() {
        _bootstrapError = error;
        _bootstrapping = false;
      });
    }
  }

  @override
  void dispose() {
    _imagesProcessedSubscription?.cancel();
    _poseService?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Widget home;
    if (_bootstrapping) {
      home = const _BootstrapLoadingPage();
    } else if (_bootstrapError != null) {
      home = _BootstrapErrorPage(
        error: _bootstrapError!,
        onRetry: () {
          setState(() {
            _bootstrapping = true;
            _bootstrapError = null;
          });
          unawaited(_bootstrap());
        },
      );
    } else {
      home = PoseCapturePage(
        poseService: _poseService!,
        validationsEnabled: validationsEnabled,
        drawLandmarks: drawLandmarks,
        resultText: exampleValidationJson,
      );
    }

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AsistenteTheme.light,
      darkTheme: AsistenteTheme.dark,
      themeMode: ThemeMode.dark,
      home: home,
    );
  }
}

class _BootstrapLoadingPage extends StatelessWidget {
  const _BootstrapLoadingPage();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(
                'Inicializando…',
                style: theme.textTheme.titleMedium,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BootstrapErrorPage extends StatelessWidget {
  const _BootstrapErrorPage({
    required this.error,
    required this.onRetry,
  });

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'No se pudo iniciar la app',
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall,
              ),
              const SizedBox(height: 12),
              Text(
                '$error',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: onRetry,
                child: const Text('Reintentar'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
