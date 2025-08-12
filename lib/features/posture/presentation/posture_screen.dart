// lib/features/posture/presentation/posture_screen.dart
import 'dart:math' as math;
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../services/posture_camera_service.dart';
import '../services/pose_ws_service.dart';
import 'widgets/overlays.dart'; // Provides PoseFrame, PoseSkeletonOverlay, CircularMaskPainter, TopShade, ProgressRing

class PostureScreen extends StatefulWidget {
  const PostureScreen({
    super.key,
    required this.cameraService,
    required this.poseService,   // ← NEW: service to start/stop streaming
    required this.poseFrames,    // ← Stream<PoseFrame> from /ws/pose
  });

  final PostureCameraService cameraService;
  final PoseWsService poseService;          // ← NEW
  final Stream<PoseFrame> poseFrames;

  @override
  State<PostureScreen> createState() => _PostureScreenState();
}

class _PostureScreenState extends State<PostureScreen> {
  final ValueNotifier<bool> _isCorrect = ValueNotifier<bool>(false);
  double? _lastLoggedPct;

  @override
  void initState() {
    super.initState();
    // Start streaming AFTER first frame so preview/surfaces are ready.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // tiny delay lets Camera2 settle on some devices
      await Future.delayed(const Duration(milliseconds: 150));
      if (!mounted) return;
      final ctrl = widget.cameraService.controller;
      if (ctrl.value.isInitialized) {
        await widget.poseService.startStreamingFromCamera(ctrl);
      }
    });
  }

  @override
  void dispose() {
    // Stop streaming but do NOT dispose the camera here (let the service/app own it).
    final ctrl = widget.cameraService.controller;
    if (ctrl.value.isStreamingImages) {
      widget.poseService.stopStreamingFromCamera(ctrl);
    }
    _isCorrect.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: _isCorrect,
      builder: (context, isCorrect, _) {
        final borderColor = isCorrect ? Colors.greenAccent : Colors.redAccent;
        final title = isCorrect ? 'Stay in that position' : 'Incorrect posture';

        final mirrorPreview =
            widget.cameraService.controller.description.lensDirection ==
                CameraLensDirection.front;

        return Scaffold(
          body: Stack(
            fit: StackFit.expand,
            children: [
              // 1) Camera preview (full screen)
              _FullScreenCameraPreview(
                controller: widget.cameraService.controller,
              ),

              // 2) Pose skeleton overlay (fed by /ws/pose)
              StreamBuilder<PoseFrame>(
                stream: widget.poseFrames,
                builder: (_, snap) => PoseSkeletonOverlay(
                  data: snap.data,                 // null => nothing drawn
                  color: Colors.limeAccent,
                  mirror: mirrorPreview,           // mirror front camera
                ),
              ),

              // 3) Mask / guides (circle + top shade)
              LayoutBuilder(
                builder: (context, constraints) {
                  final m = _calcCircleLayout(context, constraints);

                  // Optional: throttle debug logging (kept from your original)
                  if (_lastLoggedPct == null ||
                      (m.pct - _lastLoggedPct!).abs() >= 0.1) {
                    _lastLoggedPct = m.pct;
                    // final view = View.of(context); // available if you need dpr/metrics
                  }

                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      // Dim everything except the circular region
                      CustomPaint(
                        size: Size(constraints.maxWidth, constraints.maxHeight),
                        painter: CircularMaskPainter(
                          circleCenter: m.circleCenter,
                          circleRadius: m.diameter / 2 + m.borderWidth / 2,
                        ),
                      ),
                      const TopShade(),
                      // Circular border
                      Positioned(
                        left: (constraints.maxWidth - m.diameter) / 2,
                        top: m.circleCenter.dy - m.diameter / 2,
                        width: m.diameter,
                        height: m.diameter,
                        child: Container(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: borderColor,
                              width: m.borderWidth,
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),

              // 4) Status/UI
              Positioned.fill(
                child: Column(
                  children: [
                    const SizedBox(height: 36),
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                        color: _isCorrect.value
                            ? Colors.greenAccent
                            : Colors.redAccent,
                      ),
                    ),
                    if (!_isCorrect.value)
                      const Padding(
                        padding: EdgeInsets.only(top: 6.0),
                        child: Text(
                          'Adjust shoulders',
                          style: TextStyle(fontSize: 16, color: Colors.white70),
                        ),
                      ),
                    const Spacer(),
                    if (_isCorrect.value)
                      const ProgressRing(value: 0.8, color: Colors.greenAccent),
                    const SizedBox(height: 48),
                  ],
                ),
              ),

              // 5) Buttons
              Positioned(
                top: 16,
                right: 16,
                child: IconButton(
                  icon: const Icon(Icons.settings),
                  onPressed: () => _isCorrect.value = !_isCorrect.value,
                ),
              ),
              const Positioned(top: 16, left: 16, child: BackButton()),
            ],
          ),
        );
      },
    );
  }

  _CircleLayout _calcCircleLayout(BuildContext context, BoxConstraints c) {
    const borderWidth = 6.0;

    final mq = MediaQuery.of(context);
    final dpr = mq.devicePixelRatio;

    final logicalH = mq.size.height; // dp
    final safeLogicalH = mq.size.height - mq.padding.vertical; // dp
    final physicalH = (logicalH * dpr).round(); // px
    final safePhysicalH = (safeLogicalH * dpr).round(); // px

    final diameter = math.min(c.maxWidth, c.maxHeight * 0.78) * 0.9;

    final pct = (diameter / logicalH) * 100.0;
    final pctSafe = (diameter / safeLogicalH) * 100.0;

    final topTextsHeight = 36 + 26 + 22 + (mq.size.height * 0.06);
    final circleCenter = Offset(c.maxWidth / 2, topTextsHeight + diameter / 2);

    return _CircleLayout(
      diameter: diameter,
      borderWidth: borderWidth,
      circleCenter: circleCenter,
      logicalH: logicalH,
      safeLogicalH: safeLogicalH,
      physicalH: physicalH,
      safePhysicalH: safePhysicalH,
      pct: pct,
      pctSafe: pctSafe,
    );
  }
}

class _FullScreenCameraPreview extends StatelessWidget {
  const _FullScreenCameraPreview({required this.controller});
  final CameraController controller;

  @override
  Widget build(BuildContext context) {
    if (!controller.value.isInitialized) {
      return const ColoredBox(color: Color(0xFF1C1C1E));
    }

    final size = MediaQuery.of(context).size;
    final deviceRatio = size.width / size.height;
    final previewRatio = controller.value.aspectRatio;

    final preview = CameraPreview(controller);

    return OverflowBox(
      alignment: Alignment.center,
      maxHeight:
          previewRatio > deviceRatio ? size.height : size.width / previewRatio,
      maxWidth:
          previewRatio > deviceRatio ? size.height * previewRatio : size.width,
      child: preview,
    );
  }
}

/// Datos precalculados para el círculo y métricas
class _CircleLayout {
  _CircleLayout({
    required this.diameter,
    required this.borderWidth,
    required this.circleCenter,
    required this.logicalH,
    required this.safeLogicalH,
    required this.physicalH,
    required this.safePhysicalH,
    required this.pct,
    required this.pctSafe,
  });

  final double diameter;
  final double borderWidth;
  final Offset circleCenter;

  // Métricas útiles (dp/px y %)
  final double logicalH;
  final double safeLogicalH;
  final int physicalH;
  final int safePhysicalH;
  final double pct;
  final double pctSafe;
}
