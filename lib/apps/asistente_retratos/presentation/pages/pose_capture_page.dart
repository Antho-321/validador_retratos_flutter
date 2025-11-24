// ==========================
// lib/apps/asistente_retratos/presentation/pages/pose_capture_page.dart
// ==========================
import 'dart:typed_data' show Uint8List;
import 'dart:ui' show Size;
import 'dart:ui' as ui show Image, ImageByteFormat;

import 'package:flutter/foundation.dart' show compute, kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:image/image.dart' as img;

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
import '../utils/capture_downloader.dart' show saveCapturedPortrait;

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

class _ProgressBadge extends StatelessWidget {
  const _ProgressBadge({required this.value});

  final double value;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: const ValueKey('progress'),
      width: 22,
      height: 22,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CircularProgressIndicator(
            value: value,
            strokeWidth: 2,
            color: Colors.white,
            backgroundColor: Colors.white24,
          ),
          Text(
            '${(value * 100).round()}',
            style: const TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}

Future<Uint8List> _resizeCaptureForDownload(
  Uint8List bytes, {
  int width = 375,
  int height = 425,
}) async {
  final payload = <String, Object?>{
    'bytes': bytes,
    'width': width,
    'height': height,
  };
  try {
    return await compute(_resizeCaptureWorker, payload);
  } catch (_) {
    return _resizeCaptureWorker(payload);
  }
}

Uint8List _resizeCaptureWorker(Map<String, Object?> payload) {
  final bytes = payload['bytes'] as Uint8List;
  final width = payload['width'] as int;
  final height = payload['height'] as int;

  final decoded = img.decodeImage(bytes);
  if (decoded == null) {
    throw StateError('No se pudo decodificar la captura.');
  }

  final resized = _resizeImage(decoded, width, height);
  final encoded = img.encodeJpg(resized, quality: 95);
  return Uint8List.fromList(encoded);
}

img.Image _resizeImage(img.Image source, int width, int height) {
  if (source.width == width && source.height == height) {
    return source;
  }
  return img.copyResize(
    source,
    width: width,
    height: height,
    interpolation: img.Interpolation.average,
  );
}

class _PoseCapturePageState extends State<PoseCapturePage> {
  final GlobalKey _previewKey = GlobalKey();
  late final PoseCaptureController ctl;
  bool _isDownloading = false;
  double _downloadProgress = 0.0;

  String _resolveDownloadFilename() {
    final svc = widget.poseService;
    if (svc is PoseWebrtcServiceImp) {
      final ref = svc.taskParams['face_recog']?['ref_image_path'];
      if (ref is String && ref.trim().isNotEmpty) {
        return ref.trim();
      }
    }
    return 'retrato_${DateTime.now().millisecondsSinceEpoch}.jpg';
  }

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

  Future<void> _downloadCapturedWithProgress() async {
    final bytes = ctl.capturedPng;
    if (bytes == null) return;

    const double resizePhaseWeight = 0.2; // treat resize as 20% of the progress bar

    setState(() {
      _isDownloading = true;
      _downloadProgress = 0.0;
    });

    late final Uint8List resizedBytes;
    try {
      resizedBytes = await _resizeCaptureForDownload(
        bytes,
        width: 375,
        height: 425,
      );
    } catch (e) {
      if (!mounted) return;
      if (kDebugMode) {
        // ignore: avoid_print
        print('[pose] Failed to prepare capture for download: $e');
      }
      setState(() {
        _isDownloading = false;
        _downloadProgress = 0.0;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No se pudo preparar la foto para descargar. Intenta de nuevo.'),
        ),
      );
      return;
    }

    if (!mounted) return;

    setState(() => _downloadProgress = resizePhaseWeight);

    final filename = _resolveDownloadFilename();
    final success = await saveCapturedPortrait(
      resizedBytes,
      filename: filename,
      onProgress: (p) {
        if (!mounted) return;
        final scaled =
            resizePhaseWeight + p.clamp(0, 1) * (1 - resizePhaseWeight);
        setState(() => _downloadProgress = scaled);
      },
    );

    if (!mounted) return;

    setState(() => _isDownloading = false);

    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          success
              ? 'Descarga finalizada. Revisa tu carpeta de descargas.'
              : 'La descarga no está disponible en esta plataforma.',
        ),
      ),
    );
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
                            if (ctl.isProcessingCapture)
                              Positioned.fill(
                                child: IgnorePointer(
                                  ignoring: true,
                                  child: Container(
                                    color: Colors.black38,
                                    child: const Center(
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          CircularProgressIndicator(
                                            color: Colors.white,
                                          ),
                                          SizedBox(height: 12),
                                          Text(
                                            'Procesando…',
                                            style: TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            Positioned(
                              bottom: 32,
                              left: 0,
                              right: 0,
                              child: SafeArea(
                                child: Center(
                                  child: FilledButton.icon(
                                    onPressed: (_isDownloading ||
                                            ctl.isProcessingCapture)
                                        ? null
                                        : _downloadCapturedWithProgress,
                                    icon: AnimatedSwitcher(
                                      duration:
                                          const Duration(milliseconds: 200),
                                      child: _isDownloading
                                          ? _ProgressBadge(
                                              value: _downloadProgress,
                                            )
                                          : const Icon(
                                              Icons.download,
                                              key: ValueKey('download'),
                                            ),
                                    ),
                                    label: Text(
                                        _isDownloading
                                            ? 'Descargando…'
                                            : (ctl.isProcessingCapture
                                                ? 'Procesando…'
                                                : 'Descargar foto')),
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
                                  icon: Icon(
                                    Icons.close,
                                    color: scheme.onPrimary,
                                  ),
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
