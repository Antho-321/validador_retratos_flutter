// ==========================
// lib/apps/asistente_retratos/presentation/pages/pose_capture_page.dart
// ==========================
import 'dart:async' show Completer, StreamSubscription, Timer, TimeoutException, unawaited;
import 'dart:convert' show JsonEncoder, base64Decode, jsonDecode, jsonEncode;
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
import '../../infrastructure/model/images_upload_ack.dart'
    show ImagesUploadAck;

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

import '../widgets/retry_button.dart';

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
typedef _UploadDisplay = ({
  bool inProgress,
  bool? ok,
  String? status,
  String? error,
  String? photoId,
});

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
      if (root['postura'] is Map)
        (
          label: 'Postura (cuerpo y rostro)',
          ok: _okSection(root, 'postura'),
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

String _buildDetailsCopyText(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return '';
  try {
    final obj = jsonDecode(trimmed);
    return const JsonEncoder.withIndent('  ').convert(obj);
  } catch (_) {
    return _buildChecklistText(raw);
  }
}

Widget _buildChecklistTable(
  String raw,
  BuildContext context, {
  _UploadDisplay? uploadDisplay,
}) {
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
        if (uploadDisplay != null) ...[
          const SizedBox(height: 12),
          Text('Carga en base de datos', style: headerStyle),
          const SizedBox(height: 6),
          if (uploadDisplay.inProgress)
            Row(
              children: [
                const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                const Text('Subiendo...'),
              ],
            )
          else if (uploadDisplay.ok == true)
            Row(
              children: [
                statusIcon(true),
                const SizedBox(width: 8),
                Text(
                  uploadDisplay.status?.isNotEmpty == true
                      ? 'Subida exitosa (${uploadDisplay.status})'
                      : 'Subida exitosa',
                ),
              ],
            )
          else if (uploadDisplay.ok == false)
            Row(
              children: [
                statusIcon(false),
                const SizedBox(width: 8),
                Text(
                  uploadDisplay.status?.isNotEmpty == true
                      ? 'Fallo en subida (${uploadDisplay.status})'
                      : 'Fallo en subida',
                ),
              ],
            )
          else
            Row(
              children: [
                const Icon(Icons.hourglass_empty, size: 18),
                const SizedBox(width: 8),
                const Text('Pendiente'),
              ],
            ),
          if (uploadDisplay.photoId != null &&
              uploadDisplay.photoId!.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            Text('ID: ${uploadDisplay.photoId}'),
          ],
          if (uploadDisplay.error != null &&
              uploadDisplay.error!.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              'Error: ${uploadDisplay.error}',
              style: baseStyle.copyWith(color: scheme.error),
            ),
          ],
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
    String titleText;
    switch (activeStep) {
      case _ValidationOverlayStep.processingImage:
        titleText = 'Procesando imagen...';
        break;
      case _ValidationOverlayStep.validatingRequirements:
        titleText = 'Validando requisitos...';
        break;
      case _ValidationOverlayStep.uploadingToPortfolio:
        titleText = 'Subiendo al Portafolio...';
        break;
    }
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
                    titleText,
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

/// Reusable error overlay for SOAP/cédula data retrieval failures.
/// Shows an error message and a retry button with the same functionality
/// as the existing retry button used after captures.
class _CedulaDataErrorOverlay extends StatelessWidget {
  const _CedulaDataErrorOverlay({
    required this.onRetry,
  });

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Container(
      color: scheme.surface.withOpacity(0.92),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline,
                size: 72,
                color: scheme.error,
              ),
              const SizedBox(height: 20),
              Text(
                kCedulaDataFailureMessage,
                textAlign: TextAlign.center,
                style: textTheme.titleLarge?.copyWith(
                  color: scheme.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'No fue posible obtener la información de referencia. '
                'Verifique la conexión y vuelva a intentar.',
                textAlign: TextAlign.center,
                style: textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 28),
              RetryButton(onPressed: onRetry),
            ],
          ),
        ),
      ),
    );
  }
}

/// Overlay que se muestra mientras se establece la conexión inicial con el servidor.
/// Cuando hay error de conexión (timeout), muestra el botón de Reintentar.
class _ConnectionOverlay extends StatelessWidget {
  const _ConnectionOverlay({
    required this.isConnecting,
    required this.hasError,
    required this.onRetry,
  });

  final bool isConnecting;
  final bool hasError;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Container(
      color: scheme.surface.withOpacity(0.92),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (hasError) ...[
                Icon(
                  Icons.wifi_off_rounded,
                  size: 72,
                  color: scheme.error,
                ),
                const SizedBox(height: 20),
                Text(
                  'Error de conexión',
                  textAlign: TextAlign.center,
                  style: textTheme.titleLarge?.copyWith(
                    color: scheme.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'No fue posible establecer conexión con el servidor. '
                  'Verifique su conexión a internet y vuelva a intentar.',
                  textAlign: TextAlign.center,
                  style: textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 28),
                RetryButton(onPressed: onRetry),
              ] else ...[
                SizedBox(
                  width: 64,
                  height: 64,
                  child: CircularProgressIndicator(
                    strokeWidth: 5,
                    color: scheme.primary,
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  'Estableciendo conexión con el servidor',
                  textAlign: TextAlign.center,
                  style: textTheme.titleLarge?.copyWith(
                    color: scheme.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Por favor espere mientras se conecta...',
                  textAlign: TextAlign.center,
                  style: textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
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

/// Prepares a high-resolution PNG capture (lossless) for segmentation.
Future<Uint8List> _prepareHighResPngCapture(
  Uint8List bytes, {
  int pngLevel = 6,
}) async {
  final payload = <String, Object?>{
    'bytes': bytes,
    'pngLevel': pngLevel,
  };
  try {
    return await compute(_highResPngCaptureWorker, payload);
  } catch (_) {
    return _highResPngCaptureWorker(payload);
  }
}

Uint8List _highResPngCaptureWorker(Map<String, Object?> payload) {
  final bytes = payload['bytes'] as Uint8List;
  final pngLevel = payload['pngLevel'] as int? ?? 6;

  final decoded = img.decodeImage(bytes);
  if (decoded == null) {
    throw StateError('No se pudo decodificar la captura.');
  }

  // Encode as PNG (lossless) at the specified compression level
  final encoded = img.encodePng(decoded, level: pngLevel);
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
  double _downloadProgress = 0.0;
  bool _isValidatingRemote = false;
  bool _isSegmenting = false; // Controls "Procesando imagen" state extension
  String? _validationResultText;
  String? _validationErrorText;
  String? _lastValidatedCaptureId;
  Uint8List? _segmentedImageBytes; // Segmented image received from API
  bool _isUploading = false;
  bool? _uploadOk;
  String? _uploadStatus;
  String? _uploadError;
  String? _uploadPhotoId;
  String? _uploadCaptureId;
  StreamSubscription<ImagesUploadAck>? _uploadSubscription;
  
  // Estado de conexión inicial con el servidor
  bool _isConnecting = true;
  bool _connectionFailed = false;
  StreamSubscription<PoseFrame>? _connectionSubscription;

  void _resetValidationState() {
    // Unblock image reception for new captures
    if (widget.poseService is PoseWebrtcServiceImp) {
      (widget.poseService as PoseWebrtcServiceImp).unblockImageReception();
    }
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
      _clearUploadState();
    });
  }

  void _clearUploadState() {
    _isUploading = false;
    _uploadOk = null;
    _uploadStatus = null;
    _uploadError = null;
    _uploadPhotoId = null;
    _uploadCaptureId = null;
  }

  String? _captureIdFromUploadRequestId(String requestId) {
    const prefix = 'upload-';
    if (!requestId.startsWith(prefix)) return null;
    return requestId.substring(prefix.length);
  }

  void _handleUploadAck(ImagesUploadAck ack) {
    final captureId = _captureIdFromUploadRequestId(ack.requestId);
    if (captureId == null || captureId.isEmpty) return;
    if (_uploadCaptureId != captureId) return;

    bool? ok = ack.uploadOk;
    final statusUpper = ack.status?.toUpperCase();
    if (ok == null && statusUpper != null) {
      if (statusUpper == 'UPLOADED' || statusUpper == 'APPROVED') ok = true;
      if (statusUpper == 'FAILED') ok = false;
    }
    if (ack.error != null && ack.error!.trim().isNotEmpty) {
      ok = false;
    }

    if (mounted) {
      setState(() {
        _isUploading = false;
        _uploadOk = ok;
        _uploadStatus = ack.status;
        _uploadError = ack.error;
        _uploadPhotoId = ack.photoId;
        _validationResultText =
            _mergeUploadIntoDetails(_validationResultText, ack);
        _validationErrorText =
            _mergeUploadIntoDetails(_validationErrorText, ack);
      });
    } else {
      _isUploading = false;
      _uploadOk = ok;
      _uploadStatus = ack.status;
      _uploadError = ack.error;
      _uploadPhotoId = ack.photoId;
      _validationResultText = _mergeUploadIntoDetails(_validationResultText, ack);
      _validationErrorText = _mergeUploadIntoDetails(_validationErrorText, ack);
    }
  }

  String? _mergeUploadIntoDetails(String? raw, ImagesUploadAck ack) {
    if (raw == null || raw.trim().isEmpty) return raw;
    try {
      final parsed = jsonDecode(raw);
      if (parsed is! Map<String, dynamic>) return raw;
      final upload = <String, dynamic>{
        'ok': ack.uploadOk,
        'status': ack.status,
        'photo_id': ack.photoId,
        'error': ack.error,
        'request_id': ack.requestId,
      }..removeWhere((key, value) {
          if (value == null) return true;
          if (value is String && value.trim().isEmpty) return true;
          return false;
        });
      final merged = Map<String, dynamic>.from(parsed);
      merged['upload'] = upload;
      return jsonEncode(merged);
    } catch (_) {
      return raw;
    }
  }

  _UploadDisplay? _currentUploadDisplay() {
    if (_uploadCaptureId == null) return null;
    return (
      inProgress: _isUploading,
      ok: _uploadOk,
      status: _uploadStatus,
      error: _uploadError,
      photoId: _uploadPhotoId,
    );
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
      enableCapturePostProcessing: false, // Avoid double segmentation; post-process after /segmentar-imagen.
      logEverything: logAll,
    );
    ctl.setFallbackSnapshot(_captureSnapshotBytes);
    ctl.attach();
    ctl.addListener(_handleControllerChanged);
    
    // Iniciar espera de conexión con el servidor
    _startConnectionWait();
    
    // Escuchar cambios en latestFrame para detectar conexión establecida
    _setupFrameListener();
    _uploadSubscription =
        widget.poseService.imageUploads.listen(_handleUploadAck);
  }
  
  /// Listener para detectar cuando llegan frames válidos del servidor
  void _setupFrameListener() {
    widget.poseService.latestFrame.addListener(_onLatestFrameChanged);
  }
  
  void _onLatestFrameChanged() {
    // Si estamos en estado de error de conexión pero llegan frames, significa que la conexión se restableció
    if (_connectionFailed && mounted) {
      final frame = widget.poseService.latestFrame.value;
      if (frame != null) {
        // Un frame (aunque esté vacío) indica que la conexión WebRTC está viva.
        setState(() {
          _isConnecting = false;
          _connectionFailed = false;
        });
      }
    }
  }
  
  /// Espera la primera conexión con el servidor (landmarks)
  void _startConnectionWait() {
    // Cancelar suscripción anterior si existe
    _connectionSubscription?.cancel();
    
    // Actualizar estado y refrescar UI para mostrar "Estableciendo conexión"
    if (mounted) {
      setState(() {
        _isConnecting = true;
        _connectionFailed = false;
      });
    } else {
      _isConnecting = true;
      _connectionFailed = false;
    }
    
    // Primero verificar si ya hay un frame válido disponible
    final currentFrame = widget.poseService.latestFrame.value;
    if (currentFrame != null) {
      // Un frame (aunque no tenga landmarks) ya confirma conexión con el servidor.
      if (mounted) {
        setState(() {
          _isConnecting = false;
          _connectionFailed = false;
        });
      }
      return;
    }
    
    // Timeout de conexión de 30 segundos
    final timeoutTimer = Timer(const Duration(seconds: 30), () {
      if (_isConnecting && mounted) {
        _connectionSubscription?.cancel();
        setState(() {
          _isConnecting = false;
          _connectionFailed = true;
        });
      }
    });
    
    // Escuchar el primer frame (aunque esté vacío)
    _connectionSubscription = widget.poseService.frames.listen((frame) {
      timeoutTimer.cancel();
      _connectionSubscription?.cancel();
      if (mounted) {
        setState(() {
          _isConnecting = false;
          _connectionFailed = false;
        });
      }
    });
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
        !_isConnecting &&
        _lastValidatedCaptureId != captureId;

    if (!shouldStart) return;

    _lastValidatedCaptureId = captureId;
    _validationResultText = null;
    _validationErrorText = null;
    _isValidatingRemote = true;
    _isSegmenting = true; // Start segmentation waiting
    if (mounted) {
      setState(() {
        _clearUploadState();
      });
    }

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

      // Usar imagen en ALTA RESOLUCIÓN (sin resize) - PNG para segmentación
      // ignore: avoid_print
      print('[PoseCapturePage] 📸 Preparando imagen en alta resolución (PNG lossless) para segmentación...');
      final highResPng = await _prepareHighResPngCapture(
        bytes,
        pngLevel: 6,
      );
      // ignore: avoid_print
      print('[PoseCapturePage] 📏 Imagen PNG lista para segmentación: ${highResPng.length} bytes (High Res).');

      // También preparamos JPEG para validación (se usará después si la segmentación falla)
      // ignore: avoid_print
      print('[PoseCapturePage] 📸 Preparando imagen en alta resolución (JPEG quality 100) para validación fallback...');
      final highResJpeg = await _prepareHighResCapture(
        bytes,
        jpegQuality: 100,
      );
      // ignore: avoid_print
      print('[PoseCapturePage] 📏 Imagen JPEG lista para validación: ${highResJpeg.length} bytes (High Res).');

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
          imageBytes: highResPng, // Se envía FULL RES en PNG (lossless)
          filename: '$cedula.png',
          contentType: 'image/png',
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
                 // Block further image reception after successful delivery
                 webrtcService.blockImageReception();
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
             
             // El servidor devuelve la imagen procesada SIN redimensionar
             // El redimensionamiento a 375x425 se hace aquí en el cliente
             // ignore: avoid_print
             print('[PoseCapturePage] ✅ Imagen procesada recibida del servidor: ${processedBytes.length} bytes');

             // Validar que la imagen tenga un header válido (JPEG o PNG)
             bool isValidImage = false;
             if (processedBytes.length >= 3) {
               // JPEG: FF D8 FF
               if (processedBytes[0] == 0xFF && processedBytes[1] == 0xD8 && processedBytes[2] == 0xFF) {
                 isValidImage = true;
                 print('[PoseCapturePage] 📦 Formato detectado: JPEG');
               }
               // PNG: 89 50 4E 47
               else if (processedBytes.length >= 4 && 
                        processedBytes[0] == 0x89 && processedBytes[1] == 0x50 && 
                        processedBytes[2] == 0x4E && processedBytes[3] == 0x47) {
                 isValidImage = true;
                 print('[PoseCapturePage] 📦 Formato detectado: PNG');
               }
             }
             
             if (!isValidImage) {
               print('[PoseCapturePage] ❌ Imagen recibida tiene formato inválido o está corrupta');
               throw StateError('Invalid image format received from server');
             }

             // Redimensionar a 375x425 en el cliente
             print('[PoseCapturePage] 🔄 Redimensionando imagen a 375x425 en el cliente...');
             final resizedBytes = await _resizeCaptureForValidation(processedBytes);
             print('[PoseCapturePage] ✅ Imagen redimensionada: ${resizedBytes.length} bytes (375x425)');

             segmentedImageBytes = resizedBytes;

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
          // === DEBUG LOGS ===
          // ignore: avoid_print
          print('[PoseCapturePage] 📊 DEBUG: segmentedImageBytes.length = ${segmentedImageBytes!.length}');
          if (segmentedImageBytes!.length >= 10) {
            final header = segmentedImageBytes!.sublist(0, 10).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
            print('[PoseCapturePage] 📊 DEBUG: First 10 bytes = $header');
          }
          // Check image format
          String detectedFormat = 'unknown';
          if (segmentedImageBytes!.length >= 3 && 
              segmentedImageBytes![0] == 0xFF && 
              segmentedImageBytes![1] == 0xD8 && 
              segmentedImageBytes![2] == 0xFF) {
            detectedFormat = 'JPEG';
          } else if (segmentedImageBytes!.length >= 4 && 
                     segmentedImageBytes![0] == 0x89 && 
                     segmentedImageBytes![1] == 0x50 && 
                     segmentedImageBytes![2] == 0x4E && 
                     segmentedImageBytes![3] == 0x47) {
            detectedFormat = 'PNG';
          }
          print('[PoseCapturePage] 📊 DEBUG: Detected format = $detectedFormat');
          // === END DEBUG LOGS ===

          // Convert to JPEG if PNG
          if (detectedFormat == 'PNG') {
            print('[PoseCapturePage] 🔄 Convirtiendo PNG a JPEG localmente...');
            try {
              final image = img.decodeImage(segmentedImageBytes!);
              if (image != null) {
                // Encode to JPEG with quality 90
                final jpegBytes = img.encodeJpg(image, quality: 90);
                segmentedImageBytes = Uint8List.fromList(jpegBytes);
                detectedFormat = 'JPEG';
                print('[PoseCapturePage] ✅ Conversión a JPEG exitosa: ${segmentedImageBytes!.length} bytes');
              } else {
                print('[PoseCapturePage] ⚠️ No se pudo decodificar la imagen PNG para conversión');
              }
            } catch (e) {
              print('[PoseCapturePage] ❌ Error convirtiendo a JPEG: $e');
              // Continue with original bytes if conversion fails
            }
          }
          
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
      bool? validationOk;
      String? validationError;
      String validationPayload = result;
      try {
        final parsed = jsonDecode(result);
        if (parsed is Map<String, dynamic>) {
          validationOk = _isTrue(parsed['valido']);
          final err = parsed['error'];
          if (err != null) validationError = err.toString();
          final sanitized = Map<String, dynamic>.from(parsed);
          sanitized.remove('imagen_segmentada_base64');
          validationPayload = jsonEncode(sanitized);
        }
      } catch (jsonErr) {
        validationError = jsonErr.toString();
      }
      final uploadBytes = segmentedImageBytes ?? highResJpeg;
      // ignore: avoid_print
      print('[PoseCapturePage] 📊 DEBUG: Validation completed successfully');
      print('[PoseCapturePage] 📊 DEBUG: _segmentedImageBytes before setState = ${_segmentedImageBytes?.length ?? 'null'} bytes');
      print('[PoseCapturePage] 📊 DEBUG: segmentedImageBytes to set = ${segmentedImageBytes?.length ?? 'null'} bytes');
      setState(() {
        _isValidatingRemote = false;
        _validationResultText = result;
        _validationErrorText = null;
        _segmentedImageBytes = segmentedImageBytes ?? _segmentedImageBytes;
      });
      // ignore: avoid_print
      print('[PoseCapturePage] 📊 DEBUG: setState completed, _segmentedImageBytes = ${_segmentedImageBytes?.length ?? 'null'} bytes');
      if (uploadBytes.isNotEmpty) {
        unawaited(_sendValidatedPhotoToOracle(
          captureId: captureId,
          photoBytes: uploadBytes,
          userId: cedula,
          validationOk: validationOk,
          validationError: validationError,
          validationPayload: validationPayload,
        ));
      }
    } catch (e, stackTrace) {
      // ignore: avoid_print
      print('[PoseCapturePage] ❌ ERROR in _runRemoteValidation: $e');
      print('[PoseCapturePage] ❌ Stack trace: $stackTrace');
      if (!mounted || ctl.activeCaptureId != captureId) return;
      setState(() {
        _isValidatingRemote = false;
        _validationErrorText = e.toString();
        _validationResultText = null;
      });
    }
  }

  String _detectImageFormat(Uint8List bytes) {
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47 &&
        bytes[4] == 0x0D &&
        bytes[5] == 0x0A &&
        bytes[6] == 0x1A &&
        bytes[7] == 0x0A) {
      return 'png';
    }
    if (bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return 'jpeg';
    }
    return 'unknown';
  }

  String? _captureIdToIsoUtc(String captureId) {
    final idx = captureId.lastIndexOf('_');
    if (idx < 0 || idx + 1 >= captureId.length) return null;
    final ms = int.tryParse(captureId.substring(idx + 1));
    if (ms == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true)
        .toIso8601String();
  }

  Future<void> _sendValidatedPhotoToOracle({
    required String captureId,
    required Uint8List photoBytes,
    required String userId,
    bool? validationOk,
    String? validationError,
    required String validationPayload,
  }) async {
    final svc = widget.poseService;
    if (!svc.imagesReady) {
      if (mounted) {
        setState(() {
          _uploadCaptureId = captureId;
          _isUploading = false;
          _uploadOk = false;
          _uploadStatus = 'FAILED';
          _uploadError = 'WebRTC no disponible';
          _uploadPhotoId = null;
        });
      }
      if (kDebugMode) {
        // ignore: avoid_print
        print('[PoseCapturePage] ⚠️ WebRTC images DC not ready, skipping upload');
      }
      return;
    }

    if (mounted) {
      setState(() {
        _uploadCaptureId = captureId;
        _isUploading = true;
        _uploadOk = null;
        _uploadStatus = null;
        _uploadError = null;
        _uploadPhotoId = null;
      });
    } else {
      _uploadCaptureId = captureId;
      _isUploading = true;
      _uploadOk = null;
      _uploadStatus = null;
      _uploadError = null;
      _uploadPhotoId = null;
    }

    final headerExtras = <String, dynamic>{
      'purpose': 'upload',
      'user_id': userId,
      'capture_id': captureId,
      'validation_payload': validationPayload,
    };
    if (validationOk != null) {
      headerExtras['validation_ok'] = validationOk;
    }
    if (validationError != null && validationError.trim().isNotEmpty) {
      headerExtras['validation_error'] = validationError.trim();
    }
    final capturedAtIso = _captureIdToIsoUtc(captureId);
    if (capturedAtIso != null) {
      headerExtras['captured_at'] = capturedAtIso;
    }

    final fmt = _detectImageFormat(photoBytes);
    try {
      await svc.sendImageBytes(
        photoBytes,
        requestId: 'upload-$captureId',
        basename: userId,
        formatOverride: fmt == 'unknown' ? null : fmt,
        headerExtras: headerExtras,
      );
      if (kDebugMode) {
        // ignore: avoid_print
        print('[PoseCapturePage] ✅ Foto enviada para upload Oracle (id=$captureId)');
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isUploading = false;
          _uploadOk = false;
          _uploadStatus = 'FAILED';
          _uploadError = e.toString();
        });
      } else {
        _isUploading = false;
        _uploadOk = false;
        _uploadStatus = 'FAILED';
        _uploadError = e.toString();
      }
      if (kDebugMode) {
        // ignore: avoid_print
        print('[PoseCapturePage] ⚠️ Error enviando foto para Oracle: $e');
      }
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
    int frameCount = 0;
    bool receivedValidLandmarks = false;
    
    // ignore: avoid_print
    print('[_waitForLandmarks] 🎯 Starting to wait for landmarks...');
    
    // Set a maximum timeout of 30 seconds
    timeoutTimer = Timer(const Duration(seconds: 30), () {
      if (!completer.isCompleted) {
        // ignore: avoid_print
        print('[_waitForLandmarks] ⏰ Timeout after 30s. Received $frameCount frames, validLandmarks=$receivedValidLandmarks');
        subscription?.cancel();
        completer.complete();
      }
    });
    
    // Listen for the first frame with valid landmarks
    subscription = svc.frames.listen((frame) {
      frameCount++;
      
      // Check if the frame contains valid landmark data
      final packedLen = frame.packedPositions?.length ?? 0;
      final posesPxLen = frame.posesPx?.length ?? 0;
      final posesFlatLen = frame.posesPxFlat?.length ?? 0;
      
      final hasPackedPositions = packedLen > 0;
      final hasPosesPx = posesPxLen > 0;
      final hasPosesFlat = posesFlatLen > 0;
      
      // Log only first few frames to avoid spam
      if (frameCount <= 3) {
        // ignore: avoid_print
        print('[_waitForLandmarks] 📥 Frame #$frameCount: packed=$packedLen, posesPx=$posesPxLen, flat=$posesFlatLen');
      }
      
      if (hasPackedPositions || hasPosesPx || hasPosesFlat) {
        receivedValidLandmarks = true;
        // ignore: avoid_print
        print('[_waitForLandmarks] ✅ Valid landmarks detected in frame #$frameCount! packed=$packedLen, flat=$posesFlatLen');
        timeoutTimer?.cancel();
        subscription?.cancel();
        if (!completer.isCompleted) {
          completer.complete();
        }
      }
    });
    
    await completer.future;
    // ignore: avoid_print
    print('[_waitForLandmarks] 🏁 Finished waiting. Total frames=$frameCount, success=$receivedValidLandmarks');
  }

  @override
  void dispose() {
    _connectionSubscription?.cancel();
    _uploadSubscription?.cancel();
    widget.poseService.latestFrame.removeListener(_onLatestFrameChanged);
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
                    // ═══════════════════════════════════════════════════════════
                    // OPTIMIZACIÓN DE LATENCIA: Preview y Landmarks desacoplados
                    // ═══════════════════════════════════════════════════════════
                    // El RTCVideoView ahora está en su propio RepaintBoundary,
                    // aislado del CustomPaint de landmarks. Esto evita que las
                    // actualizaciones de landmarks bloqueen el pipeline de video.
                    
                    // 1) Camera preview - AISLADO en su propio layer
                    Positioned.fill(
                      child: RepaintBoundary(
                        key: _previewKey,
                        child: IgnorePointer(
                          child: RTCVideoView(
                            svc.localRenderer,
                            mirror: ctl.mirror,
                            filterQuality: FilterQuality.none,
                            objectFit: RTCVideoViewObjectFit
                                .RTCVideoViewObjectFitCover,
                          ),
                        ),
                      ),
                    ),

                    // 2) Landmarks overlay - Layer SEPARADO con su propio RepaintBoundary
                    if (widget.drawLandmarks &&
                        widget.poseService is PoseWebrtcServiceImp)
                      Positioned.fill(
                        child: RepaintBoundary(
                          child: IgnorePointer(
                            child: Builder(
                              builder: (_) {
                                final impl = widget.poseService as PoseWebrtcServiceImp;
                                return CustomPaint(
                                  isComplex: true,
                                  willChange: true,
                                  painter: LandmarksPainter(
                                    impl,
                                    cap: cap,
                                    mirror: ctl.mirror,
                                    srcSize: impl.latestFrame.value?.imageSize,
                                    fit: BoxFit.cover,
                                    showPoseBones: true,
                                    showPosePoints: true,
                                    showFacePoints: true,
                                    faceStyle: FaceStyle.cross,
                                  ),
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

                    // 3.5) Cédula Data Error Overlay (SOAP failure)
                    if (ctl.hasCedulaDataFailure)
                      Positioned.fill(
                        child: _CedulaDataErrorOverlay(
                          onRetry: () async {
                            // Mostrar inmediatamente "Estableciendo conexión con el servidor"
                            setState(() {
                              _isConnecting = true;
                              _connectionFailed = false;
                            });
                            _resetValidationState();
                            try {
                              await ctl.restartBackend();
                              _startConnectionWait();
                            } catch (_) {
                              if (mounted) {
                                setState(() {
                                  _isConnecting = false;
                                  _connectionFailed = true;
                                });
                              }
                            }
                          },
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

                  // FOTO CAPTURADA (no mostrar si se está reconectando)
                  if (ctl.capturedPng != null && !_isConnecting && !_connectionFailed)
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
                                    errorBuilder: (context, error, stackTrace) {
                                      final bytes = _segmentedImageBytes ?? ctl.capturedPng;
                                      // ignore: avoid_print
                                      print('═══════════════════════════════════════════════════════════════════');
                                      print('❌ IMAGE.MEMORY DECODE ERROR:');
                                      print('  Error: $error');
                                      print('  Error type: ${error.runtimeType}');
                                      if (bytes != null) {
                                        print('  Bytes length: ${bytes.length}');
                                        
                                        // Show first 40 bytes for better header analysis
                                        if (bytes.length >= 40) {
                                          final first40 = bytes.sublist(0, 40).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
                                          print('  First 40 bytes: $first40');
                                        } else if (bytes.length >= 20) {
                                          final first20 = bytes.sublist(0, 20).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
                                          print('  First 20 bytes: $first20');
                                        }
                                        
                                        // Show last 20 bytes for footer/IEND analysis
                                        if (bytes.length >= 20) {
                                          final last20 = bytes.sublist(bytes.length - 20).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
                                          print('  Last 20 bytes: $last20');
                                        } else if (bytes.length >= 12) {
                                          final last12 = bytes.sublist(bytes.length - 12).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
                                          print('  Last 12 bytes: $last12');
                                        }
                                        
                                        // Detect format and validate structure
                                        if (bytes.length >= 4) {
                                          if (bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47) {
                                            print('  Detected format: PNG');
                                            
                                            // PNG-specific diagnostics
                                            // Check for IEND marker (00 00 00 00 49 45 4E 44 AE 42 60 82)
                                            bool hasIEND = false;
                                            if (bytes.length >= 12) {
                                              final lastBytes = bytes.sublist(bytes.length - 12);
                                              // IEND chunk: length(4) + "IEND"(4) + CRC(4)
                                              // Standard IEND: 00 00 00 00 49 45 4E 44 AE 42 60 82
                                              if (lastBytes[4] == 0x49 && lastBytes[5] == 0x45 && 
                                                  lastBytes[6] == 0x4E && lastBytes[7] == 0x44) {
                                                hasIEND = true;
                                                print('  ✅ PNG IEND marker: FOUND at end');
                                              } else {
                                                // Search for IEND in last 100 bytes
                                                final searchStart = bytes.length > 100 ? bytes.length - 100 : 0;
                                                for (int i = searchStart; i < bytes.length - 4; i++) {
                                                  if (bytes[i] == 0x49 && bytes[i+1] == 0x45 && 
                                                      bytes[i+2] == 0x4E && bytes[i+3] == 0x44) {
                                                    hasIEND = true;
                                                    print('  ⚠️ PNG IEND marker: FOUND at offset ${i}, ${bytes.length - i - 8} bytes before end');
                                                    break;
                                                  }
                                                }
                                                if (!hasIEND) {
                                                  print('  ❌ PNG IEND marker: NOT FOUND - image is TRUNCATED');
                                                }
                                              }
                                            }
                                            
                                            // Analyze PNG chunks
                                            print('  PNG Chunk analysis:');
                                            int offset = 8; // Skip PNG signature
                                            int chunkCount = 0;
                                            String lastChunkType = '';
                                            int lastChunkOffset = 0;
                                            while (offset + 8 <= bytes.length && chunkCount < 20) {
                                              final chunkLen = (bytes[offset] << 24) | (bytes[offset+1] << 16) | 
                                                              (bytes[offset+2] << 8) | bytes[offset+3];
                                              if (offset + 4 <= bytes.length - 4) {
                                                final chunkType = String.fromCharCodes(bytes.sublist(offset + 4, offset + 8));
                                                if (chunkCount < 5 || chunkType == 'IEND' || chunkType == 'IDAT') {
                                                  print('    Chunk $chunkCount: $chunkType @ offset $offset, length $chunkLen');
                                                }
                                                lastChunkType = chunkType;
                                                lastChunkOffset = offset;
                                                
                                                // Move to next chunk (length + type + data + CRC)
                                                offset += 4 + 4 + chunkLen + 4;
                                              } else {
                                                print('    ❌ Truncated at chunk $chunkCount (offset $offset)');
                                                break;
                                              }
                                              chunkCount++;
                                            }
                                            print('    Total chunks scanned: $chunkCount');
                                            print('    Last chunk: $lastChunkType @ offset $lastChunkOffset');
                                            
                                            if (!hasIEND) {
                                              // Calculate how many bytes might be missing
                                              print('  📊 Corruption analysis:');
                                              print('    Expected last chunk: IEND (12 bytes)');
                                              print('    Actual last chunk: $lastChunkType');
                                              if (lastChunkType == 'IDAT') {
                                                print('    ⚠️ Image data (IDAT) appears truncated');
                                              }
                                            }
                                            
                                          } else if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
                                            print('  Detected format: JPEG');
                                            
                                            // JPEG-specific diagnostics
                                            // Check for EOI marker (FF D9)
                                            bool hasEOI = false;
                                            if (bytes.length >= 2) {
                                              if (bytes[bytes.length - 2] == 0xFF && bytes[bytes.length - 1] == 0xD9) {
                                                hasEOI = true;
                                                print('  ✅ JPEG EOI marker: FOUND at end');
                                              } else {
                                                // Search for EOI in last 100 bytes
                                                final searchStart = bytes.length > 100 ? bytes.length - 100 : 0;
                                                for (int i = bytes.length - 2; i >= searchStart; i--) {
                                                  if (bytes[i] == 0xFF && bytes[i+1] == 0xD9) {
                                                    hasEOI = true;
                                                    print('  ⚠️ JPEG EOI marker: FOUND at offset ${i}, ${bytes.length - i - 2} extra bytes after');
                                                    break;
                                                  }
                                                }
                                                if (!hasEOI) {
                                                  print('  ❌ JPEG EOI marker: NOT FOUND - image is TRUNCATED');
                                                }
                                              }
                                            }
                                          } else {
                                            print('  Detected format: UNKNOWN');
                                            final headerHex = bytes.sublist(0, bytes.length.clamp(0, 8)).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
                                            print('  Unknown header: $headerHex');
                                          }
                                        }
                                        
                                        // Calculate MD5-like fingerprint (simple hash for log correlation)
                                        int simpleHash = 0;
                                        for (int i = 0; i < bytes.length; i += 1000) {
                                          simpleHash = (simpleHash * 31 + bytes[i]) & 0xFFFFFFFF;
                                        }
                                        print('  Simple hash (for correlation): ${simpleHash.toRadixString(16).padLeft(8, '0')}');
                                        
                                        // Check for null bytes that might indicate padding
                                        int trailingNulls = 0;
                                        for (int i = bytes.length - 1; i >= 0 && bytes[i] == 0; i--) {
                                          trailingNulls++;
                                        }
                                        if (trailingNulls > 0) {
                                          print('  ⚠️ Trailing null bytes: $trailingNulls (possible buffer padding)');
                                        }
                                      }
                                      if (stackTrace != null && stackTrace.toString().trim().isNotEmpty) {
                                        print('  Stack trace: $stackTrace');
                                      } else {
                                        print('  Stack trace: (not available from Image.memory decoder)');
                                      }
                                      print('═══════════════════════════════════════════════════════════════════');
                                      return Center(
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(Icons.broken_image, size: 64, color: Colors.red),
                                            const SizedBox(height: 8),
                                            Text(
                                              'Error al mostrar imagen',
                                              style: TextStyle(color: Colors.red),
                                            ),
                                            const SizedBox(height: 4),
                                            Text(
                                              '${bytes?.length ?? 0} bytes',
                                              style: TextStyle(color: Colors.grey, fontSize: 12),
                                            ),
                                          ],
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ),
                            ),
                            if (ctl.isProcessingCapture ||
                                _isValidatingRemote ||
                                _isUploading)
                              Positioned.fill(
                                child: IgnorePointer(
                                  ignoring: true,
                                  child: _PhotoValidationOverlay(
                                    activeStep: _isUploading
                                        ? _ValidationOverlayStep
                                            .uploadingToPortfolio
                                        : (ctl.isProcessingCapture || _isSegmenting)
                                            ? _ValidationOverlayStep.processingImage
                                            : _ValidationOverlayStep
                                                .validatingRequirements,
                                  ),
                                ),
                              ),
                            if (!ctl.isProcessingCapture &&
                                !_isValidatingRemote &&
                                !_isUploading)
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
                                              uploadDisplay: _currentUploadDisplay(),
                                            ),
                                            copyText: _buildDetailsCopyText(
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
                                            RetryButton(
                                              onPressed: () async {
                                                // Mostrar inmediatamente "Estableciendo conexión con el servidor"
                                                setState(() {
                                                  _isConnecting = true;
                                                  _connectionFailed = false;
                                                });
                                                _resetValidationState();
                                                try {
                                                  await ctl.restartBackend();
                                                  _startConnectionWait();
                                                } catch (_) {
                                                  if (mounted) {
                                                    setState(() {
                                                      _isConnecting = false;
                                                      _connectionFailed = true;
                                                    });
                                                  }
                                                }
                                              },
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
                    
                  // OVERLAY DE CONEXIÓN GLOBAL (se muestra encima de todo)
                  if (_isConnecting || _connectionFailed)
                    Positioned.fill(
                      child: _ConnectionOverlay(
                        isConnecting: _isConnecting,
                        hasError: _connectionFailed,
                        onRetry: () async {
                          setState(() {
                            _isConnecting = true;
                            _connectionFailed = false;
                          });
                          _resetValidationState();
                          try {
                            await ctl.restartBackend();
                            _startConnectionWait();
                          } catch (_) {
                            if (mounted) {
                              setState(() {
                                _isConnecting = false;
                                _connectionFailed = true;
                              });
                            }
                          }
                        },
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
