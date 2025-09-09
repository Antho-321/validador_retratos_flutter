// ==========================
// lib/features/posture/presentation/pages/pose_capture_page.dart
// ==========================
import 'dart:typed_data' show Uint8List;
import 'dart:ui' show Size; // for LayoutBuilder size
import 'dart:ui' as ui show Image, ImageByteFormat;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../../posture/domain/service/pose_capture_service.dart';
import '../widgets/rtc_pose_overlay.dart' show PoseOverlayFast;
import '../widgets/portrait_validator_hud.dart' show PortraitValidatorHUD;
import '../widgets/frame_sequence_overlay.dart' show FrameSequenceOverlay;
import '../../core/face_oval_geometry.dart' show faceOvalRectFor;

import '../controllers/pose_capture_controller.dart';

class PoseCapturePage extends StatefulWidget {
  const PoseCapturePage({
    super.key,
    required this.poseService,

    /// Total logical duration of the countdown when [countdownSpeed] == 1.0.
    this.countdownDuration = const Duration(seconds: 3),

    /// Visual smoothness of the ring updates (frames per second).
    this.countdownFps = 30,

    /// Speed multiplier: 1.0 = normal; 2.0 = twice as fast (finishes in half the time).
    this.countdownSpeed = 1.6,

    /// NEW: enables/disables pose validations logic entirely.
    this.validationsEnabled = true,
  });

  final PoseCaptureService poseService;
  final Duration countdownDuration;
  final int countdownFps;
  final double countdownSpeed;

  /// NEW: global switch to disable all validations (yaw/pitch/roll/shoulders/azimut).
  final bool validationsEnabled;

  @override
  State<PoseCapturePage> createState() => _PoseCapturePageState();
}

class _PoseCapturePageState extends State<PoseCapturePage> {
  // UI-only state
  final GlobalKey _previewKey = GlobalKey(); // wraps only the camera preview
  late final PoseCaptureController ctl;

  @override
  void initState() {
    super.initState();
    ctl = PoseCaptureController(
      poseService: widget.poseService,
      countdownDuration: widget.countdownDuration,
      countdownFps: widget.countdownFps,
      countdownSpeed: widget.countdownSpeed,
      mirror: true,
      validationsEnabled: widget.validationsEnabled, // NEW: pass the flag
    );
    // Provide fallback snapshot closure (uses this widget's context & key)
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

    // Match on-screen sharpness.
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final ui.Image image = await boundary.toImage(pixelRatio: dpr);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    return byteData?.buffer.asUint8List();
  }

  @override
  Widget build(BuildContext context) {
    final svc = widget.poseService;

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        ctl.setCanvasSize(size); // keep current canvas size for mapping

        return AnimatedBuilder(
          animation: ctl,
          builder: (context, _) {
            return Scaffold(
              backgroundColor: Colors.black,
              body: Stack(
                children: [
                  // Live preview + overlays only when NOT capturing and no photo shown
                  if (!ctl.isCapturing && ctl.capturedPng == null) ...[
                    // 1) Full-screen local preview (wrapped for snapshot)
                    Positioned.fill(
                      child: RepaintBoundary(
                        key: _previewKey,
                        child: RTCVideoView(
                          svc.localRenderer,
                          mirror: ctl.mirror,
                          objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                        ),
                      ),
                    ),

                    // 2) Low-latency landmarks overlay (your existing widget)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: PoseOverlayFast(
                          latest: svc.latestFrame,
                          mirror: ctl.mirror,
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),

                    // 3) Portrait HUD (face oval, checklist, guidance, countdown)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: PortraitValidatorHUD(
                          modelListenable: ctl.hud,
                          mirror: ctl.mirror,
                          fit: BoxFit.cover,
                          showSafeBox: false,
                          messageGap: 0.045,
                          ovalRectFor: (sz) {
                            final r   = faceOvalRectFor(sz);
                            final newW = r.width  * 0.90;     // 10% más angosto
                            final newH = r.height * 0.85;     // 15% más bajo
                            final dx   = (r.width  - newW) / 2; // centrar horizontalmente
                            final dy   = (r.height - newH) / 2; // centrar verticalmente
                            return Rect.fromLTWH(r.left + dx, r.top + dy, newW, newH);
                          },
                        ),
                      ),
                    ),

                    // 4) Frame sequence animation overlay (ONLY while hint is active)
                    if (ctl.showTurnRightSeq)
                      Positioned(
                        left: 0,
                        right: 0,
                        // ~75% desde arriba: queda por debajo de los textos del HUD.
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

                    // 5) Optional remote PiP
                    Positioned(
                      left: 12,
                      top: 12,
                      width: 144,
                      height: 192,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: RTCVideoView(
                          svc.remoteRenderer,
                          mirror: ctl.mirror, // consider false if remote is not mirrored
                          objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                        ),
                      ),
                    ),
                  ],

                  // Capture in progress (hidden live UI, image not ready yet)
                  if (ctl.isCapturing && ctl.capturedPng == null)
                    const Positioned.fill(
                      child: ColoredBox(
                        color: Colors.black,
                        child: Center(child: CircularProgressIndicator()),
                      ),
                    ),

                  // Captured photo overlay (tap/close → return to live)
                  if (ctl.capturedPng != null)
                    Positioned.fill(
                      child: Container(
                        color: Colors.black,
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
                                color: Colors.black54,
                                shape: const CircleBorder(),
                                child: IconButton(
                                  icon: const Icon(Icons.close, color: Colors.white),
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
