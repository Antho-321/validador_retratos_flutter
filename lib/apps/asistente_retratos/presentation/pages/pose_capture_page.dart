// ==========================
// lib/apps/asistente_retratos/presentation/pages/pose_capture_page.dart
// ==========================
import 'dart:async' show Completer, StreamSubscription, Timer, TimeoutException, unawaited;
import 'dart:convert' show base64Decode, jsonDecode;
import 'dart:typed_data' show Uint8List;
import 'dart:ui' show Size;
import 'dart:ui' as ui show Image, ImageByteFormat, ImageFilter;

import 'package:flutter/foundation.dart' show compute, kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'package:image/image.dart' as img;

import '../../domain/service/pose_capture_service.dart';

// ✅ agrega:
import '../widgets/landmarks_painter.dart' show LandmarksPainter, FaceStyle;
// (si tu painter usa directamente la impl del servicio)
import '../../infrastructure/services/pose_webrtc_service_imp.dart'
    show PoseWebrtcServiceImp;
import '../../infrastructure/model/pose_frame.dart' show PoseFrame;

import '../widgets/portrait_validator_hud.dart' show PortraitValidatorHUD;
import '../widgets/frame_sequence_overlay.dart' show FrameSequenceOverlay;
import '../../core/face_oval_geometry.dart' show faceOvalRectFor;

import '../controllers/pose_capture_controller.dart';
import '../utils/capture_downloader.dart' show saveCapturedPortrait;
import '../widgets/formatted_text_box.dart' show FormattedTextBox;
import '../../infrastructure/services/portrait_validation_api.dart'
    show PortraitValidationApi;

// ✅ acceso a CaptureTheme (para color de landmarks)
import 'package:validador_retratos_flutter/apps/asistente_retratos/presentation/styles/colors.dart'
    show CaptureTheme;

class PoseCapturePage extends StatefulWidget {
  const PoseCapturePage({
    super.key,
    required this.poseService,
    this.resultText,
    this.countdownDuration = const Duration(seconds: 3),
    this.countdownFps = 30,
    this.countdownSpeed = 1.6,
    this.validationsEnabled = true,
    this.drawLandmarks = true, // ⬅️ nuevo
    this.showDownloadButton = false,
  });

  final PoseCaptureService poseService;
  final String? resultText;
  final Duration countdownDuration;
  final int countdownFps;
  final double countdownSpeed;
  final bool validationsEnabled;
  final bool drawLandmarks; // ⬅️ nuevo
  final bool showDownloadButton;

  @override
  State<PoseCapturePage> createState() => _PoseCapturePageState();
}

bool _isTrue(dynamic v) {
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) return v.trim().toLowerCase() == 'true';
  return false;
}

String _mark(bool ok) => ok ? '✅' : '❌';

bool _okSection(Map<String, dynamic> root, String key) {
  final section = root[key];
  if (section is Map) {
    final map = Map<String, dynamic>.from(section);
    return _isTrue(map['valido']);
  }
  return false;
}

typedef _ChecklistItem = ({String label, bool ok});
typedef _ChecklistData = ({List<_ChecklistItem> items, String observations});

List<_ChecklistItem> _buildChecklistItems(Map<String, dynamic> root) => [
      (
        label: 'Metadatos (Formato/Resolución/Peso)',
        ok: _okSection(root, 'metadatos'),
      ),
      if (root['fondo'] is Map)
        (
          label: 'Fondo blanco',
          ok: _okSection(root, 'fondo'),
        ),
      if (root['rostro'] is Map)
        (
          label: 'Rostro',
          ok: _okSection(root, 'rostro'),
        ),
      (
        label: 'Postura del cuerpo',
        ok: _okSection(root, 'postura_cuerpo'),
      ),
      (
        label: 'Postura del rostro',
        ok: _okSection(root, 'postura_rostro'),
      ),
      (
        label: 'Vestimenta oscura',
        ok: _okSection(root, 'color_vestimenta'),
      ),
    ];

_ChecklistData? _tryParseChecklistData(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;

  try {
    final decoded = jsonDecode(trimmed);
    if (decoded is! Map) return null;
    final root = Map<String, dynamic>.from(decoded);
    if (!root.containsKey('valido')) return null;

    final obs = root['observaciones'];
    final observations = obs is String ? obs.trim() : '';

    return (
      items: _buildChecklistItems(root),
      observations: observations,
    );
  } catch (_) {
    return null;
  }
}

String _buildChecklistText(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return '';

  final data = _tryParseChecklistData(trimmed);
  if (data == null) return trimmed;

  final lines = <String>[
    for (final item in data.items) '${item.label} → ${_mark(item.ok)}',
  ];

  if (data.observations.isNotEmpty) {
    lines.add('');
    lines.add('Observaciones: ${data.observations}');
  }

  return lines.join('\n');
}

Widget _buildChecklistTable(String raw, BuildContext context) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return const SizedBox.shrink();

  final scheme = Theme.of(context).colorScheme;
  final baseStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
            fontFamily: 'monospace',
            height: 1.35,
            color: scheme.onSurface,
          ) ??
      TextStyle(
        fontFamily: 'monospace',
        fontSize: 12,
        height: 1.35,
        color: scheme.onSurface,
      );

  final data = _tryParseChecklistData(trimmed);
  if (data == null) {
    return DefaultTextStyle(
      style: baseStyle,
      child: Text(trimmed),
    );
  }

  final headerStyle = baseStyle.copyWith(
    fontWeight: FontWeight.w800,
    color: scheme.onSurfaceVariant,
  );

  final borderColor = scheme.outlineVariant.withOpacity(0.35);

  Widget statusIcon(bool ok) => Icon(
        ok ? Icons.check_circle_rounded : Icons.cancel_rounded,
        size: 18,
        color: ok ? Colors.greenAccent.shade400 : scheme.error,
      );

  return DefaultTextStyle(
    style: baseStyle,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Table(
          columnWidths: const {
            0: FlexColumnWidth(),
            1: IntrinsicColumnWidth(),
          },
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          border: TableBorder(
            horizontalInside: BorderSide(color: borderColor),
          ),
          children: [
            TableRow(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text('Validación', style: headerStyle),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Text('Estado', style: headerStyle),
                  ),
                ),
              ],
            ),
            for (final item in data.items)
              TableRow(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(item.label),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: statusIcon(item.ok),
                    ),
                  ),
                ],
              ),
          ],
        ),
        if (data.observations.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text('Observaciones', style: headerStyle),
          const SizedBox(height: 6),
          Text(data.observations),
        ],
      ],
    ),
  );
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

enum _ValidationOverlayStep {
  processingImage,
  validatingRequirements,
  uploadingToPortfolio,
}

class _PhotoValidationOverlay extends StatelessWidget {
  const _PhotoValidationOverlay({
    required this.activeStep,
  });

  final _ValidationOverlayStep activeStep;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final titleStyle = theme.textTheme.headlineMedium?.copyWith(
          color: Colors.white,
          fontWeight: FontWeight.w500,
        ) ??
        const TextStyle(
          fontSize: 34,
          fontWeight: FontWeight.w500,
          color: Colors.white,
        );

    return Stack(
      children: [
        Positioned.fill(
          child: ClipRect(
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
              child: const SizedBox.expand(),
            ),
          ),
        ),
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withOpacity(0.35),
                  Colors.black.withOpacity(0.70),
                ],
              ),
            ),
          ),
        ),
        SafeArea(
          child: Column(
            children: [
              const Spacer(),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 72,
                    height: 72,
                    child: CircularProgressIndicator(
                      strokeWidth: 6,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Validando foto...',
                    textAlign: TextAlign.center,
                    style: titleStyle,
                  ),
                ],
              ),
              const Spacer(),
              Padding(
                padding: const EdgeInsets.fromLTRB(28, 0, 28, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _ValidationOverlayStepRow(
                      label: 'Procesando imagen',
                      state: _ValidationOverlayStep.processingImage == activeStep
                          ? _ValidationOverlayStepState.active
                          : _ValidationOverlayStepState.pending,
                    ),
                    const SizedBox(height: 18),
                    _ValidationOverlayStepRow(
                      label: 'Validando requisitos',
                      state:
                          _ValidationOverlayStep.validatingRequirements ==
                                  activeStep
                              ? _ValidationOverlayStepState.active
                              : _ValidationOverlayStepState.pending,
                    ),
                    const SizedBox(height: 18),
                    _ValidationOverlayStepRow(
                      label: 'Subiendo al Portafolio',
                      state: _ValidationOverlayStep.uploadingToPortfolio ==
                              activeStep
                          ? _ValidationOverlayStepState.active
                          : _ValidationOverlayStepState.pending,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

enum _ValidationOverlayStepState { active, pending }

class _ValidationOverlayStepRow extends StatelessWidget {
  const _ValidationOverlayStepRow({
    required this.label,
    required this.state,
  });

  final String label;
  final _ValidationOverlayStepState state;

  @override
  Widget build(BuildContext context) {
    final bool isActive = state == _ValidationOverlayStepState.active;

    final Color color = isActive
        ? Colors.white
        : Colors.white.withOpacity(0.62);

    final textStyle = Theme.of(context).textTheme.headlineSmall?.copyWith(
          color: color,
          fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
        ) ??
        TextStyle(
          fontSize: 28,
          color: color,
          fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
        );

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          isActive ? Icons.radio_button_checked : Icons.radio_button_unchecked,
          color: color,
          size: 22,
        ),
        const SizedBox(width: 14),
        Flexible(
          child: Text(
            label,
            style: textStyle,
          ),
        ),
      ],
    );
  }
}

Future<Uint8List> _prepareHighResCapture(
  Uint8List bytes, {
  int jpegQuality = 100,
}) async {
  final payload = <String, Object?>{
    'bytes': bytes,
    'jpegQuality': jpegQuality,
  };
  try {
    return await compute(_highResCaptureWorker, payload);
  } catch (_) {
    return _highResCaptureWorker(payload);
  }
}

Uint8List _highResCaptureWorker(Map<String, Object?> payload) {
  final bytes = payload['bytes'] as Uint8List;
  final jpegQuality = payload['jpegQuality'] as int? ?? 100;

  final decoded = img.decodeImage(bytes);
  if (decoded == null) {
    throw StateError('No se pudo decodificar la captura.');
  }

  // No resizing, just convert to JPEG at high quality
  // Modificar pixel específico (legacy markers, preservados por compatibilidad)
  // Nota: se mantienen los marcadores pero en coordenadas relativas si fuera necesario,
  // pero el código original usaba coords fijas (374, 424) para 375x425.
  // En alta resolución, estos pixeles quedarían en la "esquina superior izquierda".
  // Si son críticos para el backend, deberían escalarse.
  // Asumiendo que eran marcadores de "debug" o "marca de agua" legacy para 375x425.
  // Se omiten para High Res o se dejan fijos.
  // El usuario pidió "highest possible resolution", así que evitamos alterar los píxeles
  // arbitrariamente a menos que sea validación estricta.
  // El código original:
  /*
    if (resized.width > 0 && resized.height > 424) {
      resized.setPixelRgb(0, 424, 100, 100, 100);
    }
    if (resized.width > 374 && resized.height > 424) {
      resized.setPixelRgb(374, 424, 100, 100, 100);
    }
  */
  // Al no redimensionar, simplemente codificamos.

  final encoded = img.encodeJpg(decoded, quality: jpegQuality);
  return Uint8List.fromList(encoded);
}

Future<Uint8List> _resizeCapture(
  Uint8List bytes, {
  required String format,
  required int width,
  required int height,
  int jpegQuality = 95,
  int pngLevel = 6,
}) async {
  final payload = <String, Object?>{
    'bytes': bytes,
    'format': format,
    'width': width,
    'height': height,
    'jpegQuality': jpegQuality,
    'pngLevel': pngLevel,
  };
  try {
    return await compute(_resizeCaptureWorker, payload);
  } catch (_) {
    return _resizeCaptureWorker(payload);
  }
}

Future<Uint8List> _resizeCaptureForDownload(
  Uint8List bytes, {
  int width = 375,
  int height = 425,
}) =>
    _resizeCapture(
      bytes,
      format: 'png', // Changed to png
      width: width,
      height: height,
    );

// Mantener para compatibilidad si algo más lo usa, o marcar deprecated.
Future<Uint8List> _resizeCaptureForValidation(
  Uint8List bytes, {
  int width = 375,
  int height = 425,
}) =>
    _resizeCapture(
      bytes,
      format: 'jpeg',
      width: width,
      height: height,
      jpegQuality: 100,
    );

Uint8List _resizeCaptureWorker(Map<String, Object?> payload) {
  final bytes = payload['bytes'] as Uint8List;
  final format = (payload['format'] as String?)?.toLowerCase().trim() ?? 'png';
  final width = payload['width'] as int;
  final height = payload['height'] as int;
  final jpegQuality = payload['jpegQuality'] as int? ?? 95;
  final pngLevel = payload['pngLevel'] as int? ?? 6;

  final decoded = img.decodeImage(bytes);
  if (decoded == null) {
    throw StateError('No se pudo decodificar la captura.');
  }

  final resized = _resizeImage(decoded, width, height);
  if (format == 'png') {
    final encoded = img.encodePng(resized, level: pngLevel);
    return Uint8List.fromList(encoded);
  }
  if (format == 'jpeg' || format == 'jpg') {
    if (resized.width > 0 && resized.height > 424) {
      resized.setPixelRgb(0, 424, 100, 100, 100);
    }
    if (resized.width > 374 && resized.height > 424) {
      resized.setPixelRgb(374, 424, 100, 100, 100);
    }
    final encoded = img.encodeJpg(resized, quality: jpegQuality);
    return Uint8List.fromList(encoded);
  }

  throw ArgumentError.value(format, 'format', 'Unsupported output format (only png)');
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
  bool _isRestarting = false; // ⇠ NEW: Loading spinner state for retry
  double _downloadProgress = 0.0;
  bool _isValidatingRemote = false;
  bool _isSegmenting = false; // Controls "Procesando imagen" state extension
  String? _validationResultText;
  String? _validationErrorText;
  String? _lastValidatedCaptureId;
  Uint8List? _segmentedImageBytes; // Segmented image received from API

  void _resetValidationState() {
    if (_validationResultText == null &&
        _validationErrorText == null &&
        !_isValidatingRemote &&
        _lastValidatedCaptureId == null) {
      return;
    }
    setState(() {
      _isValidatingRemote = false;
      _isSegmenting = false;
      _validationResultText = null;
      _validationErrorText = null;
      _lastValidatedCaptureId = null;
      _segmentedImageBytes = null; // Reset segmented image
    });
  }

  String _resolveDownloadFilename() {
    final svc = widget.poseService;
    if (svc is PoseWebrtcServiceImp) {
      final ref = svc.taskParams['face_recog']?['ref_image_path'];
      if (ref is String && ref.trim().isNotEmpty) {
        return ref.trim();
      }
    }
    return 'retrato_${DateTime.now().millisecondsSinceEpoch}.png';
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
    ctl.addListener(_handleControllerChanged);
  }

  void _handleControllerChanged() {
    final captureId = ctl.activeCaptureId;
    if (captureId == null || ctl.capturedPng == null) {
      if (_lastValidatedCaptureId != null ||
          _validationResultText != null ||
          _validationErrorText != null ||
          _isValidatingRemote) {
        _resetValidationState();
      }
      return;
    }

    final shouldStart = !ctl.isCapturing &&
        !ctl.isProcessingCapture &&
        !_isValidatingRemote &&
        _lastValidatedCaptureId != captureId;

    if (!shouldStart) return;

    _lastValidatedCaptureId = captureId;
    _validationResultText = null;
    _validationErrorText = null;
    _isValidatingRemote = true;
    _isSegmenting = true; // Start segmentation waiting
    if (mounted) setState(() {});

    unawaited(_runRemoteValidation(captureId, ctl.capturedPng!));
  }

  Future<void> _runRemoteValidation(String captureId, Uint8List bytes) async {
    try {
      final endpointRaw = (dotenv.env['VALIDAR_IMAGEN_URL'] ?? '').trim();
      final baseUrl = endpointRaw.isNotEmpty
          ? endpointRaw.replaceAll('/validar-imagen', '')
          : 'https://127.0.0.1:5001';
      final validationEndpoint = Uri.parse('$baseUrl/validar-imagen');
      final segmentationEndpoint = Uri.parse('$baseUrl/segmentar-imagen');

      final cedula = (dotenv.env['CEDULA'] ?? '').trim().isNotEmpty
          ? dotenv.env['CEDULA']!.trim()
          : '1050298650';
      final nacionalidad =
          (dotenv.env['NACIONALIDAD'] ?? '').trim().isNotEmpty
              ? dotenv.env['NACIONALIDAD']!.trim()
              : 'Ecuatoriana';
      final etnia = (dotenv.env['ETNIA'] ?? '').trim().isNotEmpty
          ? dotenv.env['ETNIA']!.trim()
          : 'Mestiza';

      final allowInsecureFromEnv =
          (dotenv.env['ALLOW_INSECURE_SSL'] ?? '').trim().toLowerCase() == 'true';
      final isLocalHost = validationEndpoint.host == '127.0.0.1' ||
          validationEndpoint.host == 'localhost' ||
          validationEndpoint.host == '10.0.2.2';
      final allowInsecure = allowInsecureFromEnv || (kDebugMode && isLocalHost);

      // Usar imagen en ALTA RESOLUCIÓN (sin resize)
      // ignore: avoid_print
      print('[PoseCapturePage] 📸 Preparando imagen en alta resolución (JPEG quality 100)...');
      final highResJpeg = await _prepareHighResCapture(
        bytes,
        jpegQuality: 100,
      );
      // ignore: avoid_print
      print('[PoseCapturePage] 📏 Imagen lista para envío: ${highResJpeg.length} bytes (High Res).');

      // STEP 1: Call segmentation endpoint FIRST (during "Procesando imagen" step)
      Uint8List? segmentedImageBytes;
      try {
        // ignore: avoid_print
        print('[PoseCapturePage] 🔄 Llamando a /segmentar-imagen (Esperando hasta 5m)...');
        final segmentationApi = PortraitValidationApi(
          endpoint: segmentationEndpoint,
          allowInsecure: allowInsecure,
        );
        // User requested "wait as long as necessary", using 5 minute timeout
        final segmentedResult = await segmentationApi.segmentarImagen(
          imageBytes: highResJpeg, // Se envía FULL RES
          filename: '$cedula.jpg',
          contentType: 'image/jpeg',
          timeout: const Duration(minutes: 5), 
        );
        segmentedImageBytes = segmentedResult;
        // ignore: avoid_print
        print('[PoseCapturePage] ✅ IMAGEN SEGMENTADA RECIBIDA: ${segmentedImageBytes.length} bytes');
        
        // Update UI immediately with segmented image AND move to next step
        if (mounted && ctl.activeCaptureId == captureId) {
          setState(() {
            _segmentedImageBytes = segmentedImageBytes;
             // Still in "Procesando imagen" step, just updated visual feedback
          });
        }

        // STEP 1.5: Send segmented image via WebRTC for post-processing
        // This uses the existing WebRTC data channel instead of a separate HTTP call
        if (segmentedImageBytes != null && widget.poseService is PoseWebrtcServiceImp) {
          try {
             // ignore: avoid_print
             print('[PoseCapturePage] 🔄 Enviando imagen segmentada via WebRTC para post-procesamiento...');
             final webrtcService = widget.poseService as PoseWebrtcServiceImp;
             
             // Check if WebRTC images DC is ready
             if (!webrtcService.imagesReady) {
               throw StateError('WebRTC images data channel not ready');
             }
             
             // Set up listener for processed image response
             final processedCompleter = Completer<Uint8List>();
             StreamSubscription? subscription;
             subscription = webrtcService.imagesProcessed.listen((rx) {
               if (!processedCompleter.isCompleted) {
                 // ignore: avoid_print
                 print('[PoseCapturePage] ✅ IMAGEN PROCESADA RECIBIDA (WebRTC): ${rx.bytes.length} bytes');
                 processedCompleter.complete(rx.bytes);
               }
               subscription?.cancel();
             });
             
             // Send the segmented image for processing via WebRTC
             await webrtcService.sendImageBytes(
               segmentedImageBytes!,
               alreadySegmented: true,  // Use post-processing only pipeline
             );
             
             // Wait for processed result (with timeout)
             final processedBytes = await processedCompleter.future.timeout(
               const Duration(minutes: 2),
               onTimeout: () {
                 subscription?.cancel();
                 throw TimeoutException('Post-processing via WebRTC timed out');
               },
             );
             
             // ignore: avoid_print
             print('[PoseCapturePage] 📏 Redimensionando imagen procesada a 375x425 para validación...');
             
             // Redimensionar explícitamente a 375x425 como requiere el validador
             final resizedProcessed = await _resizeCaptureForValidation(
               processedBytes, // viene del servidor (post-proceso via WebRTC)
               width: 375,
               height: 425,
             );
             
             // ignore: avoid_print
             print('[PoseCapturePage] ✅ Imagen redimensionada lista: ${resizedProcessed.length} bytes (375x425)');

             segmentedImageBytes = resizedProcessed;

             if (mounted && ctl.activeCaptureId == captureId) {
               setState(() {
                 _segmentedImageBytes = segmentedImageBytes;
                 _isSegmenting = false; // FINALLY Move to "Validando requisitos"
               });
             }
          } catch (procErr) {
             // ignore: avoid_print
             print('[PoseCapturePage] ⚠️ Error en post-procesamiento via WebRTC: $procErr');
             // Decide: fail or continue with raw segmented?
             // Let's continue with raw segmented but stop spinner
             if (mounted && ctl.activeCaptureId == captureId) {
               setState(() {
                 _isSegmenting = false;
               });
             }
          }
        } else if (segmentedImageBytes != null) {
             // Fallback: WebRTC not available, just continue with segmented image
             // ignore: avoid_print
             print('[PoseCapturePage] ⚠️ WebRTC no disponible, usando imagen segmentada sin post-procesamiento');
             if (mounted && ctl.activeCaptureId == captureId) {
               setState(() {
                 _isSegmenting = false;
               });
             }
        } else {
             if (mounted && ctl.activeCaptureId == captureId) {
               setState(() {
                 _isSegmenting = false;
               });
             }
        }
      } catch (segErr) {
        // ignore: avoid_print
        print('[PoseCapturePage] ⚠️ Error en segmentación: $segErr');
        // If segmentation fails, we stop "processing" state to allow validation or error to show
        if (mounted && ctl.activeCaptureId == captureId) {
          setState(() {
             _isSegmenting = false;
          });
        }
      }

      if (!mounted || ctl.activeCaptureId != captureId) return;

      // STEP 2: Call validation endpoint (during "Validando requisitos" step)
      final api = PortraitValidationApi(
        endpoint: validationEndpoint,
        allowInsecure: allowInsecure,
      );

      String result;
      // STEP 2: Call validation endpoint (during "Validando requisitos" step)
      // If we have a processed segmented image, we use it for validation.
      if (segmentedImageBytes != null) {
          // ignore: avoid_print
          print('[PoseCapturePage] 🚀 Enviando imagen PROCESADA (High Res / Server Output) a validación');
          result = await api.validarImagen(
            imageBytes: segmentedImageBytes!,
            filename: '$cedula.jpg', // Podríamos cambiar extensión si el procesado es png, pero el backend deducirá
            contentType: 'image/jpeg', // o 'image/png'
            cedula: cedula,
            nacionalidad: nacionalidad,
            etnia: etnia,
          );
      } else {
         // Fallback to original capture if segmentation failed or wasn't available
         // ignore: avoid_print
         print('[PoseCapturePage] ⚠️ Enviando captura ORIGINAL (High Res) a validación (fallback)');
         result = await api.validarImagen(
          imageBytes: highResJpeg, // FALLBACK HIGH RES
          filename: '$cedula.jpg',
          contentType: 'image/jpeg',
          cedula: cedula,
          nacionalidad: nacionalidad,
          etnia: etnia,
        );
      }

      // Parse JSON response for any additional segmented image (fallback)
      if (segmentedImageBytes == null) {
        try {
          final jsonResponse = jsonDecode(result) as Map<String, dynamic>;
          final segmentedImageB64 = jsonResponse['imagen_segmentada_base64'];
          if (segmentedImageB64 != null && segmentedImageB64 is String && segmentedImageB64.isNotEmpty) {
            segmentedImageBytes = base64Decode(segmentedImageB64);
            // ignore: avoid_print
            print('[PoseCapturePage] ✅ IMAGEN SEGMENTADA (fallback) DECODIFICADA: ${segmentedImageBytes.length} bytes');
          }
        } catch (jsonErr) {
          // ignore: avoid_print
          print('[PoseCapturePage] ⚠️ Error al parsear imagen segmentada del JSON: $jsonErr');
        }
      }

      if (!mounted || ctl.activeCaptureId != captureId) return;
      setState(() {
        _isValidatingRemote = false;
        _validationResultText = result;
        _validationErrorText = null;
        _segmentedImageBytes = segmentedImageBytes ?? _segmentedImageBytes;
      });
    } catch (e) {
      if (!mounted || ctl.activeCaptureId != captureId) return;
      setState(() {
        _isValidatingRemote = false;
        _validationErrorText = e.toString();
        _validationResultText = null;
      });
    }
  }

  /// Waits until landmarks are being received from the API.
  /// Returns after the first valid frame with landmarks, or after a timeout.
  Future<void> _waitForLandmarks() async {
    if (!mounted) return;
    
    final svc = widget.poseService;
    final completer = Completer<void>();
    StreamSubscription<PoseFrame>? subscription;
    Timer? timeoutTimer;
    
    // Set a maximum timeout of 30 seconds
    timeoutTimer = Timer(const Duration(seconds: 30), () {
      if (!completer.isCompleted) {
        subscription?.cancel();
        completer.complete();
      }
    });
    
    // Listen for the first frame with valid landmarks
    subscription = svc.frames.listen((frame) {
      // Check if the frame contains valid landmark data
      final hasPackedPositions = frame.packedPositions != null && 
          frame.packedPositions!.isNotEmpty;
      final hasPosesPx = frame.posesPx != null && frame.posesPx!.isNotEmpty;
      final hasPosesFlat = frame.posesPxFlat != null && frame.posesPxFlat!.isNotEmpty;
      
      if (hasPackedPositions || hasPosesPx || hasPosesFlat) {
        timeoutTimer?.cancel();
        subscription?.cancel();
        if (!completer.isCompleted) {
          completer.complete();
        }
      }
    });
    
    await completer.future;
  }

  @override
  void dispose() {
    ctl.removeListener(_handleControllerChanged);
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
    // Download the segmented/processed image if available, otherwise the original capture.
    final bytes = _segmentedImageBytes ?? ctl.capturedPng;
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
    late final bool success;
    try {
      success = await saveCapturedPortrait(
        resizedBytes,
        filename: filename,
        onProgress: (p) {
          if (!mounted) return;
          final scaled =
              resizePhaseWeight + p.clamp(0, 1) * (1 - resizePhaseWeight);
          setState(() => _downloadProgress = scaled);
        },
      );
    } catch (e) {
      if (!mounted) return;
      if (kDebugMode) {
        // ignore: avoid_print
        print('[pose] Failed to save capture: $e');
      }
      setState(() {
        _isDownloading = false;
        _downloadProgress = 0.0;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No se pudo guardar la foto. Intenta de nuevo.'),
        ),
      );
      return;
    }

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
                                  // Display segmented image if available, otherwise show original
                                  child: Image.memory(
                                    _segmentedImageBytes ?? ctl.capturedPng!,
                                    fit: BoxFit.contain,
                                  ),
                                ),
                              ),
                            ),
                            if (ctl.isProcessingCapture || _isValidatingRemote)
                              Positioned.fill(
                                child: IgnorePointer(
                                  ignoring: true,
                                  child: _PhotoValidationOverlay(
                                    activeStep: (ctl.isProcessingCapture || _isSegmenting)
                                        ? _ValidationOverlayStep.processingImage
                                        : _ValidationOverlayStep
                                            .validatingRequirements,
                                  ),
                                ),
                              ),
                            if (!ctl.isProcessingCapture && !_isValidatingRemote)
                              Positioned(
                                left: 0,
                                right: 0,
                                bottom: 32,
                                child: SafeArea(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (((_validationResultText ??
                                                  _validationErrorText ??
                                                  '')
                                              .trim()
                                              .isNotEmpty))
                                        Padding(
                                          padding: const EdgeInsets.fromLTRB(
                                              16, 0, 16, 12),
                                          child: FormattedTextBox(
                                            text: (_validationResultText ??
                                                _validationErrorText)!,
                                            title: 'Detalles',
                                            collapsible: true,
                                            initiallyExpanded: true,
                                            maxHeight:
                                                constraints.maxHeight * 0.34,
                                            child: _buildChecklistTable(
                                              (_validationResultText ??
                                                  _validationErrorText)!,
                                              context,
                                            ),
                                            copyText: _buildChecklistText(
                                              (_validationResultText ??
                                                  _validationErrorText)!,
                                            ),
                                          ),
                                        ),
                                      Center(
                                        child: Wrap(
                                          spacing: 12,
                                          runSpacing: 12,
                                          alignment: WrapAlignment.center,
                                          children: [
                                            if (widget.showDownloadButton)
                                              FilledButton.icon(
                                                onPressed: _isDownloading
                                                    ? null
                                                    : () => unawaited(
                                                          _downloadCapturedWithProgress(),
                                                        ),
                                                icon: _isDownloading
                                                    ? _ProgressBadge(
                                                        value: _downloadProgress,
                                                      )
                                                    : const Icon(
                                                        Icons.download_rounded,
                                                      ),
                                                label: Text(
                                                  _isDownloading
                                                      ? 'Descargando…'
                                                      : 'Descargar',
                                                ),
                                              ),
                                            FilledButton.icon(
                                              onPressed: _isRestarting
                                                  ? null
                                                  : () async {
                                                      setState(() => _isRestarting = true);
                                                      _resetValidationState();
                                                      try {
                                                        await ctl.restartBackend();
                                                        // Wait for landmarks to start arriving before ending loading state
                                                        await _waitForLandmarks();
                                                      } catch (_) {
                                                        // On error, just reset the loading state
                                                      } finally {
                                                        if (mounted) {
                                                          setState(() => _isRestarting = false);
                                                        }
                                                      }
                                                    },
                                              icon: _isRestarting
                                                  ? SizedBox(
                                                      width: 16,
                                                      height: 16,
                                                      child: CircularProgressIndicator(
                                                        strokeWidth: 2,
                                                        color: Theme.of(context).colorScheme.onPrimary,
                                                      ),
                                                    )
                                                  : const Icon(Icons.refresh),
                                              label: Text(_isRestarting ? 'Conectando...' : 'Reintentar'),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
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
