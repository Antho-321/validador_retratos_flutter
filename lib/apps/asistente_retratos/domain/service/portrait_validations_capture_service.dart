// lib/apps/asistente_retratos/domain/service/portrait_validations_capture_service.dart
import 'dart:async';
import 'dart:ui' show Offset;
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter_webrtc/flutter_webrtc.dart' show RTCVideoRenderer, MediaStream;

import '../model/lmk_state.dart'; // ⬅️ añade esto
import '../model/face_recog_result.dart';

import '../../infrastructure/model/pose_frame.dart' show PoseFrame;
import '../../infrastructure/model/pose_point.dart' show PosePoint;

abstract class PortraitValidationsCaptureService {
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

  // Accesos opcionales (puedes mantenerlos por compatibilidad)
  List<List<Offset>>? get latestFaceLandmarks;
  List<Offset>? get latestPoseLandmarks;
  List<PosePoint>? get latestPoseLandmarks3D;

  // ✅ Estado reactivo con “hold-last” para evitar parpadeo
  ValueListenable<LmkState> get faceLandmarks;
  // ⬅️ NUEVO: POSE landmarks para usar con PosePainter
  ValueListenable<LmkState> get poseLandmarks;

  ValueListenable<FaceRecogResult?> get faceRecogResult;
}
