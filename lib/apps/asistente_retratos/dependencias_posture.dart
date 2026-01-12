// lib/apps/asistente_retratos/dependencias_posture.dart
import 'package:get_it/get_it.dart';

import 'core/pose_config.dart';
import 'domain/service/pose_capture_service.dart';
import 'domain/repository/posture_repository.dart';

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
  final cedulaTrimmed = cedula?.trim() ?? '';
  final refImagePath =
      cedulaTrimmed.isNotEmpty ? cedulaTrimmed : '1050298650';

  // Service (infra) — registra UNA sola instancia y expón tanto el contrato
  // como la implementación (útil si tu repo aún depende de la clase concreta).
  sl.registerLazySingleton<PoseWebrtcServiceImp>(
    () => PoseWebrtcServiceImp(
      offerUri: offerUri,
      logEverything: logEverything,
      lowLatency: PoseConfig.lowLatency,
      preferBestResolution: PoseConfig.preferBestResolution,
      idealWidth: PoseConfig.idealWidth,
      idealHeight: PoseConfig.idealHeight,
      idealFps: PoseConfig.idealFps,
      maxBitrateKbps: PoseConfig.maxBitrateKbps,
      encoder: RtcVideoEncoder(
        idealFps: PoseConfig.idealFps,
        maxBitrateKbps: PoseConfig.maxBitrateKbps,
        encoderFps: PoseConfig.sendFps,
        scaleDownBy: PoseConfig.sendScale,
      ),
      kfMinGapMs: PoseConfig.kfMinGapMs,
      requestedTasks: PoseConfig.enableFaceRecog
          ? const ['pose', 'face', 'face_recog']
          : const ['pose', 'face'],
      jsonTasks: PoseConfig.enableFaceRecog ? const {'face_recog'} : const <String>{},
      stunUrl: PoseConfig.stunUrl,
      turnUrl: PoseConfig.turnUrl,
      turnUsername: PoseConfig.turnUsername,
      turnPassword: PoseConfig.turnPassword,
      initialTaskParams: PoseConfig.enableFaceRecog
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
}
