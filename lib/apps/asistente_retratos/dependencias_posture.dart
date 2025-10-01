// lib/apps/asistente_retratos/dependencias_posture.dart
import 'package:get_it/get_it.dart';

import 'domain/service/pose_capture_service.dart';
import 'domain/repository/posture_repository.dart';
//import 'domain/service/evaluate_frame_usecase.dart';

import 'infrastructure/services/pose_webrtc_service_imp.dart';
import 'infrastructure/repository/posture_repository_imp.dart';

final sl = GetIt.instance;

/// Registra todas las dependencias de `apps/asistente_retratos`.
/// Pasa aquí la configuración del servicio WebRTC.
void registrarDependenciasPosture({
  required Uri offerUri,
  bool logEverything = false,
}) {
  // Service (infra) — registra UNA sola instancia y expón tanto el contrato
  // como la implementación (útil si tu repo aún depende de la clase concreta).
  sl.registerLazySingleton<PoseWebrtcServiceImp>(
    () => PoseWebrtcServiceImp(
      offerUri: offerUri,
      logEverything: logEverything,
      requestedTasks: const ['pose', 'face', 'face_recog'],
      jsonTasks: const {'face_recog'},
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
