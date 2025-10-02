// ==========================
// lib/apps/asistente_retratos/presentation/pages/pose_capture_page.dart
// ==========================
import 'dart:typed_data' show Uint8List;
import 'dart:ui' show Size;
import 'dart:ui' as ui show Image, ImageByteFormat;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../domain/service/pose_capture_service.dart';

// ✅ agrega:
import '../widgets/landmarks_painter.dart' show LandmarksPainter, FaceStyle;
// (si tu painter usa directamente la impl del servicio)
import '../../infrastructure/services/pose_webrtc_service_imp.dart'
    show PoseWebrtcServiceImp;

import '../widgets/portrait_validator_hud.dart' show PortraitValidatorHUD;
import '../widgets/frame_sequence_overlay.dart' show FrameSequenceOverlay;
import '../../core/face_oval_geometry.dart' show faceOvalRectFor;

import '../controllers/pose_capture_controller.dart';

// ✅ acceso a CaptureTheme (para color de landmarks)
import 'package:validador_retratos_flutter/apps/asistente_retratos/presentation/styles/colors.dart'
    show CaptureTheme;

class PoseCapturePage extends StatefulWidget {
  const PoseCapturePage({
    super.key,
    required this.poseService,
    this.countdownDuration = const Duration(seconds: 3),
    this.countdownFps = 30,
    this.countdownSpeed = 1.6,
    this.validationsEnabled = true,
    this.drawLandmarks = true, // ⬅️ nuevo
  });

  final PoseCaptureService poseService;
  final Duration countdownDuration;
  final int countdownFps;
  final double countdownSpeed;
  final bool validationsEnabled;
  final bool drawLandmarks; // ⬅️ nuevo

  @override
  State<PoseCapturePage> createState() => _PoseCapturePageState();
}

class _PoseCapturePageState extends State<PoseCapturePage> {
  final GlobalKey _previewKey = GlobalKey();
  late final PoseCaptureController ctl;

  @override
  void initState() {
    super.initState();
    final logAll = widget.poseService is PoseWebrtcServiceImp
        ? (widget.poseService as PoseWebrtcServiceImp).logEverything
        : false;
    ctl = PoseCaptureController(
      poseService: widget.poseService,
      countdownDuration: widget.countdownDuration,
      countdownFps: widget.countdownFps,
      countdownSpeed: widget.countdownSpeed,
      mirror: true,
      validationsEnabled: widget.validationsEnabled,
      logEverything: logAll,
    );
    ctl.setFallbackSnapshot(_captureSnapshotBytes);
    ctl.attach();
  }

  @override
  void dispose() {
    ctl.dispose();
    super.dispose();
  }

  Future<Uint8List?> _captureSnapshotBytes() async {
    final ctx = _previewKey.currentContext;
    if (ctx == null) return null;

    final boundary = ctx.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) return null;

    final dpr = MediaQuery.of(context).devicePixelRatio;
    final ui.Image image = await boundary.toImage(pixelRatio: dpr);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    return byteData?.buffer.asUint8List();
  }

  @override
  Widget build(BuildContext context) {
    final svc = widget.poseService;
    // ✅ obtiene el CaptureTheme del tema actual
    final cap = Theme.of(context).extension<CaptureTheme>() ?? const CaptureTheme();

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        ctl.setCanvasSize(size);

        return AnimatedBuilder(
          animation: ctl,
          builder: (context, _) {
            final scheme = Theme.of(context).colorScheme;

            return Scaffold(
              backgroundColor: Theme.of(context).scaffoldBackgroundColor,
              body: Stack(
                children: [
                  if (!ctl.isCapturing && ctl.capturedPng == null) ...[
                    // ÚNICO bloque preview + overlay unificado
                    Positioned.fill(
                      child: RepaintBoundary(
                        key: _previewKey,
                        child: IgnorePointer(
                          child: Builder(
                            builder: (_) {
                              // si el servicio concreto es PoseWebrtcServiceImp, úsalo directo
                              final impl = widget.poseService is PoseWebrtcServiceImp
                                  ? widget.poseService as PoseWebrtcServiceImp
                                  : null;

                              final hasPainter = widget.drawLandmarks && impl != null;

                              return hasPainter
                                  ? CustomPaint(
                                      isComplex: true,
                                      willChange: true,
                                      foregroundPainter: LandmarksPainter(
                                        impl!,
                                        cap: cap,                 // ✅ color desde CaptureTheme
                                        mirror: ctl.mirror,
                                        srcSize: impl.latestFrame.value?.imageSize, // mejor escalado
                                        fit: BoxFit.cover,
                                        showPoseBones: true,
                                        showPosePoints: true,
                                        showFacePoints: true,
                                        faceStyle: FaceStyle.cross, // o FaceStyle.points
                                      ),
                                      child: RTCVideoView(
                                        svc.localRenderer,
                                        mirror: ctl.mirror,
                                        objectFit: RTCVideoViewObjectFit
                                            .RTCVideoViewObjectFitCover,
                                      ),
                                    )
                                  : RTCVideoView(
                                      svc.localRenderer,
                                      mirror: ctl.mirror,
                                      objectFit: RTCVideoViewObjectFit
                                          .RTCVideoViewObjectFitCover,
                                    );
                            },
                          ),
                        ),
                      ),
                    ),

                    // 3) HUD
                    Positioned.fill(
                      child: IgnorePointer(
                        child: PortraitValidatorHUD(
                          modelListenable: ctl.hud,
                          mirror: ctl.mirror,
                          fit: BoxFit.cover,
                          showSafeBox: false,
                          messageGap: 0.045,
                          ovalRectFor: (sz) {
                            final r = faceOvalRectFor(sz);
                            final newW = r.width * 0.88;
                            final newH = r.height * 0.83;
                            final dx = (r.width - newW) / 2;
                            final dy = (r.height - newH) / 2;
                            return Rect.fromLTWH(
                                r.left + dx, r.top + dy, newW, newH);
                          },
                        ),
                      ),
                    ),

                    // 4) Secuencia de giro
                    if (ctl.showTurnRightSeq)
                      Positioned(
                        left: 0,
                        right: 0,
                        top: constraints.maxHeight * 0.75,
                        child: IgnorePointer(
                          child: SizedBox(
                            height: constraints.maxHeight * 0.25,
                            child: Center(
                              child: Transform.scale(
                                scale: 0.60,
                                child: FrameSequenceOverlay(
                                  controller: ctl.seq,
                                  mirror: false,
                                  fit: BoxFit.contain,
                                  opacity: 1.0,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),

                    // 5) Remote PiP
                    Positioned(
                      left: 12,
                      top: 12,
                      width: 144,
                      height: 192,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: RTCVideoView(
                          svc.remoteRenderer,
                          mirror: ctl.mirror,
                          objectFit: RTCVideoViewObjectFit
                              .RTCVideoViewObjectFitCover,
                        ),
                      ),
                    ),
                  ],

                  // CAPTURANDO
                  if (ctl.isCapturing && ctl.capturedPng == null)
                    Positioned.fill(
                      child: ColoredBox(
                        color: scheme.background,
                        child:
                            const Center(child: CircularProgressIndicator()),
                      ),
                    ),

                  // FOTO CAPTURADA
                  if (ctl.capturedPng != null)
                    Positioned.fill(
                      child: Container(
                        color: scheme.background,
                        alignment: Alignment.center,
                        child: Stack(
                          children: [
                            Positioned.fill(
                              child: GestureDetector(
                                onTap: ctl.closeCaptured,
                                child: Center(
                                  child: Image.memory(
                                    ctl.capturedPng!,
                                    fit: BoxFit.contain,
                                  ),
                                ),
                              ),
                            ),
                            Positioned(
                              top: 16,
                              right: 16,
                              child: Material(
                                color: scheme.primary.withOpacity(0.92),
                                shape: const CircleBorder(),
                                child: IconButton(
                                  icon: Icon(Icons.close,
                                      color: scheme.onPrimary),
                                  onPressed: ctl.closeCaptured,
                                  tooltip: 'Cerrar',
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}