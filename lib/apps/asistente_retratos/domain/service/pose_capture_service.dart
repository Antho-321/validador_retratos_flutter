// lib/apps/asistente_retratos/domain/service/pose_capture_service.dart
import 'dart:async';
import 'dart:ui' show Offset;
import 'dart:typed_data' show Uint8List;
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter_webrtc/flutter_webrtc.dart' show RTCVideoRenderer, MediaStream;

import '../model/lmk_state.dart';
import '../model/face_recog_result.dart';
import '../../infrastructure/model/pose_frame.dart' show PoseFrame;
import '../../infrastructure/model/pose_point.dart' show PosePoint;
// ⬇️ NUEVO: el tipo del stream
import '../../infrastructure/model/images_rx.dart' show ImagesRx;
import '../../infrastructure/model/images_upload_ack.dart' show ImagesUploadAck;
import '../model/ui_step_event.dart';

abstract class PoseCaptureService {
  Future<void> init();
  Future<void> connect();
  Future<void> switchCamera();
  Future<void> dispose();

  // Renderers para preview
  RTCVideoRenderer get localRenderer;
  RTCVideoRenderer get remoteRenderer;
  MediaStream? get localStream;

  // Último frame y stream
  ValueListenable<PoseFrame?> get latestFrame;
  Stream<PoseFrame> get frames;

  // Accesos opcionales
  List<List<Offset>>? get latestFaceLandmarks;
  List<Offset>? get latestPoseLandmarks;
  List<PosePoint>? get latestPoseLandmarks3D;

  // Estado reactivo
  ValueListenable<LmkState> get faceLandmarks;
  ValueListenable<LmkState> get poseLandmarks;
  ValueListenable<FaceRecogResult?> get faceRecogResult;

  // ⬇️ NUEVO: Images DataChannel
  Stream<ImagesRx> get imagesProcessed;                 // <<--- AÑADIR
  Stream<ImagesUploadAck> get imageUploads;             // <<--- AÑADIR
  Stream<UiStepEvent> get uiStepEvents;                 // <<--- AÑADIR UI STEP
  bool get imagesReady; // DC open?
  Future<void> sendImageBytes(
    Uint8List bytes, {
      String? requestId,
      String? basename,
      String? formatOverride,
      bool alreadySegmented = false,
      Map<String, dynamic>? headerExtras,
  });

  // Image reception control - block further images after processing completes
  void blockImageReception();
  void unblockImageReception();
  bool get isImageReceptionBlocked;

  /// Sends a command to restart the backend process/state.
  Future<void> restartBackend();
}
