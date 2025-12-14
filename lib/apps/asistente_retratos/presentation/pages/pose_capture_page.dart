// ==========================
// lib/apps/asistente_retratos/presentation/pages/pose_capture_page.dart
// ==========================
import 'dart:async' show unawaited;
import 'dart:convert' show jsonDecode;
import 'dart:typed_data' show Uint8List;
import 'dart:ui' show Size;
import 'dart:ui' as ui show Image, ImageByteFormat, ImageFilter;

import 'package:flutter/foundation.dart' show compute, kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:file_picker/file_picker.dart';
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
  });

  final PoseCaptureService poseService;
  final String? resultText;
  final Duration countdownDuration;
  final int countdownFps;
  final double countdownSpeed;
  final bool validationsEnabled;
  final bool drawLandmarks; // ⬅️ nuevo

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

Future<Uint8List> _resizeCapture(
  Uint8List bytes, {
  required String format,
  int width = 375,
  int height = 425,
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
      jpegQuality: 100, // Maximum quality for validation
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
  double _downloadProgress = 0.0;
  bool _isValidatingRemote = false;
  String? _validationResultText;
  String? _validationErrorText;
  String? _lastValidatedCaptureId;

  void _resetValidationState() {
    if (_validationResultText == null &&
        _validationErrorText == null &&
        !_isValidatingRemote &&
        _lastValidatedCaptureId == null) {
      return;
    }
    setState(() {
      _isValidatingRemote = false;
      _validationResultText = null;
      _validationErrorText = null;
      _lastValidatedCaptureId = null;
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
    if (mounted) setState(() {});

    unawaited(_runRemoteValidation(captureId, ctl.capturedPng!));
  }

  Future<void> _runRemoteValidation(String captureId, Uint8List bytes) async {
    try {
      final endpointRaw = (dotenv.env['VALIDAR_IMAGEN_URL'] ?? '').trim();
      final endpoint = Uri.parse(
        endpointRaw.isNotEmpty
            ? endpointRaw
            : 'https://127.0.0.1:5001/validar-imagen',
      );

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
      final isLocalHost = endpoint.host == '127.0.0.1' ||
          endpoint.host == 'localhost' ||
          endpoint.host == '10.0.2.2';
      final allowInsecure = allowInsecureFromEnv || (kDebugMode && isLocalHost);

      final resizedJpeg = await _resizeCaptureForValidation(
        bytes,
        width: 375,
        height: 425,
      );

      final api = PortraitValidationApi(
        endpoint: endpoint,
        allowInsecure: allowInsecure,
      );

      final result = await api.validarImagen(
        imageBytes: resizedJpeg,
        filename: '$cedula.jpg',
        contentType: 'image/jpeg',
        cedula: cedula,
        nacionalidad: nacionalidad,
        etnia: etnia,
      );

      if (!mounted || ctl.activeCaptureId != captureId) return;
      setState(() {
        _isValidatingRemote = false;
        _validationResultText = result;
        _validationErrorText = null;
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

  Future<void> _sendRawDngToBackend() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['dng'],
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;

      final picked = result.files.single;
      final bytes = picked.bytes;
      if (bytes == null || bytes.isEmpty) {
        throw StateError('No se pudo leer el archivo RAW seleccionado.');
      }

      await ctl.processExternalImageBytes(
        bytes,
        basename: picked.name,
        formatOverride: 'dng',
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('No se pudo enviar el RAW (DNG): $e'),
        ),
      );
    }
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
                            if (ctl.isProcessingCapture || _isValidatingRemote)
                              Positioned.fill(
                                child: IgnorePointer(
                                  ignoring: true,
                                  child: _PhotoValidationOverlay(
                                    activeStep: ctl.isProcessingCapture
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
                                              onPressed: (_isDownloading ||
                                                      ctl.isProcessingCapture ||
                                                      _isValidatingRemote)
                                                  ? null
                                                  : () => unawaited(
                                                        _sendRawDngToBackend(),
                                                      ),
                                              icon: const Icon(
                                                Icons.upload_file,
                                              ),
                                              label: const Text('Enviar RAW'),
                                            ),
                                            FilledButton.icon(
                                              onPressed: () {
                                                _resetValidationState();
                                                unawaited(ctl.restartBackend());
                                              },
                                              icon: const Icon(Icons.refresh),
                                              label: const Text('Reintentar'),
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
