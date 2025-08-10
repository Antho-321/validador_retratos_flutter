// lib/features/posture/presentation/posture_screen.dart
import 'dart:math' as math;
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../../posture/services/posture_camera_service.dart';
import 'widgets/overlays.dart';

class PostureScreen extends StatefulWidget {
  const PostureScreen({super.key, required this.cameraService});
  final PostureCameraService cameraService;

  @override
  State<PostureScreen> createState() => _PostureScreenState();
}

class _PostureScreenState extends State<PostureScreen> {
  final ValueNotifier<bool> _isCorrect = ValueNotifier<bool>(false);
  double? _lastLoggedPct;

  @override
  void dispose() {
    _isCorrect.dispose();
    widget.cameraService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: _isCorrect,
      builder: (context, isCorrect, _) {
        final borderColor = isCorrect ? Colors.greenAccent : Colors.redAccent;
        final title = isCorrect ? 'Stay in that position' : 'Incorrect posture';

        return Scaffold(
          body: Stack(
            fit: StackFit.expand,
            children: [
              // 1) PREVIEW pantalla completa
              _FullScreenCameraPreview(
                controller: widget.cameraService.controller,
              ),

              // 2) Overlays y máscara con un solo LayoutBuilder
              LayoutBuilder(
                builder: (context, constraints) {
                  final m = _calcCircleLayout(context, constraints);

                  // Log: tamaños lógicos/físicos + % (con throttle)
                  if (_lastLoggedPct == null ||
                      (m.pct - _lastLoggedPct!).abs() >= 0.1) {
                    _lastLoggedPct = m.pct;
                    final view = View.of(context);
                  }

                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      CustomPaint(
                        size: Size(constraints.maxWidth, constraints.maxHeight),
                        painter: CircularMaskPainter(
                          circleCenter: m.circleCenter,
                          circleRadius: m.diameter / 2 + m.borderWidth / 2,
                        ),
                      ),
                      const TopShade(),
                      Positioned(
                        left: (constraints.maxWidth - m.diameter) / 2,
                        top: m.circleCenter.dy - m.diameter / 2,
                        width: m.diameter,
                        height: m.diameter,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            Container(
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: borderColor,
                                  width: m.borderWidth,
                                ),
                              ),
                            ),
                            CustomPaint(
                              size: Size.square(m.diameter),
                              painter: SkeletonPainter(color: borderColor),
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),

              // 3) UI de estado + acciones
              Positioned.fill(
                child: Column(
                  children: [
                    const SizedBox(height: 36),
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                        color:
                            _isCorrect.value
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

    Widget preview = CameraPreview(controller);

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
