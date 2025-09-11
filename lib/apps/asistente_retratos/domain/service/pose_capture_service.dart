// lib/apps/asistente_retratos/domain/service/pose_capture_service.dart
import 'dart:async';
import 'dart:ui' show Offset;
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter_webrtc/flutter_webrtc.dart' show RTCVideoRenderer, MediaStream;

import '../../infrastructure/model/pose_frame.dart' show PoseFrame;
import '../../infrastructure/model/pose_point.dart' show PosePoint;

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
  List<PosePoint>? get latestPoseLandmarks3D; // ← lo usa tu onframe
}
