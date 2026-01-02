// lib/apps/asistente_retratos/dependencias_posture.dart
import 'package:get_it/get_it.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'domain/service/pose_capture_service.dart';
import 'domain/repository/posture_repository.dart';
//import 'domain/service/evaluate_frame_usecase.dart';

import 'infrastructure/services/pose_webrtc_service_imp.dart';
import 'infrastructure/repository/posture_repository_imp.dart';
import 'infrastructure/webrtc/rtc_video_encoder.dart';

final sl = GetIt.instance;

/// Registra todas las dependencias de `apps/asistente_retratos`.
/// Pasa aquí la configuración del servicio WebRTC.
void registrarDependenciasPosture({
  required Uri offerUri,
  String? cedula,
  bool logEverything = false,
}) {
  String? envOrNull(String key) {
    final value = dotenv.env[key]?.trim();
    return (value == null || value.isEmpty) ? null : value;
  }

  bool envBool(String key, {bool defaultValue = false}) {
    final raw = dotenv.env[key]?.trim().toLowerCase();
    if (raw == null || raw.isEmpty) return defaultValue;
    if (raw == '1' || raw == 'true' || raw == 'yes' || raw == 'y' || raw == 'on') {
      return true;
    }
    if (raw == '0' || raw == 'false' || raw == 'no' || raw == 'n' || raw == 'off') {
      return false;
    }
    return defaultValue;
  }

  int envInt(String key, {required int defaultValue}) {
    final raw = dotenv.env[key]?.trim();
    if (raw == null || raw.isEmpty) return defaultValue;
    final parsed = int.tryParse(raw);
    return parsed ?? defaultValue;
  }

  double envDouble(String key, {required double defaultValue}) {
    final raw = dotenv.env[key]?.trim();
    if (raw == null || raw.isEmpty) return defaultValue;
    final parsed = double.tryParse(raw);
    return parsed ?? defaultValue;
  }

  final stunUrl = envOrNull('STUN_URL');
  final turnUrl = envOrNull('TURN_URL');
  final turnUsername = envOrNull('TURN_USERNAME');
  final turnPassword = envOrNull('TURN_PASSWORD');

  final lowLatency = envBool('POSE_LOW_LATENCY', defaultValue: true);
  final preferBestResolution =
      envBool('POSE_PREFER_BEST_RESOLUTION', defaultValue: true);
  final idealWidth =
      envInt('POSE_IDEAL_WIDTH', defaultValue: lowLatency ? 640 : 640);
  final idealHeight =
      envInt('POSE_IDEAL_HEIGHT', defaultValue: lowLatency ? 360 : 360);
  final idealFps = envInt('POSE_IDEAL_FPS', defaultValue: lowLatency ? 30 : 30);
  final sendFps = envInt('POSE_SEND_FPS', defaultValue: idealFps);
  final maxBitrateKbps =
      envInt('POSE_MAX_BITRATE_KBPS', defaultValue: lowLatency ? 600 : 800);
  final sendScale = envDouble('POSE_SEND_SCALE', defaultValue: 1.0);
  final kfMinGapMs =
      envInt('POSE_KF_MIN_GAP_MS', defaultValue: lowLatency ? 100 : 500);
  final enableFaceRecog =
      envBool('POSE_ENABLE_FACE_RECOG', defaultValue: true);

  final cedulaTrimmed = cedula?.trim() ?? '';
  final refImagePath =
      cedulaTrimmed.isNotEmpty ? cedulaTrimmed : '1050298650';

  // Service (infra) — registra UNA sola instancia y expón tanto el contrato
  // como la implementación (útil si tu repo aún depende de la clase concreta).
  sl.registerLazySingleton<PoseWebrtcServiceImp>(
    () => PoseWebrtcServiceImp(
      offerUri: offerUri,
      logEverything: logEverything,
      lowLatency: lowLatency,
      preferBestResolution: preferBestResolution,
      idealWidth: idealWidth,
      idealHeight: idealHeight,
      idealFps: idealFps,
      maxBitrateKbps: maxBitrateKbps,
      encoder: RtcVideoEncoder(
        idealFps: idealFps,
        maxBitrateKbps: maxBitrateKbps,
        encoderFps: sendFps,
        scaleDownBy: sendScale,
      ),
      kfMinGapMs: kfMinGapMs,
      requestedTasks: enableFaceRecog
          ? const ['pose', 'face', 'face_recog']
          : const ['pose', 'face'],
      jsonTasks: enableFaceRecog ? const {'face_recog'} : const <String>{},
      stunUrl: stunUrl,
      turnUrl: turnUrl,
      turnUsername: turnUsername,
      turnPassword: turnPassword,
      initialTaskParams: enableFaceRecog
          ? {
              // Se envía como task_params.face_recog.ref_image_path en el offer (WebRTC).
              'face_recog': {'ref_image_path': refImagePath},
            }
          : const <String, Map<String, dynamic>>{},
    ),
  );
  sl.registerLazySingleton<PoseCaptureService>(
    () => sl<PoseWebrtcServiceImp>(),
  );

  // Repository
  sl.registerLazySingleton<PostureRepository>(
    () => PostureRepositoryImp(
      sl<PoseWebrtcServiceImp>(), // si tu repo acepta el contrato, usa: sl<PoseCaptureService>()
    ),
  );

  // Use cases
  //sl.registerFactory(() => EvaluateFrameUseCase(sl<PostureRepository>()));
}
