// ==========================
// lib/apps/asistente_retratos/presentation/controllers/pose_capture_controller.dart
// ==========================
import 'dart:async';
import 'dart:typed_data' show Uint8List, ByteBuffer, ByteData;
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary; // kept for types
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'dart:ui' show Size, Offset;
import 'package:flutter/painting.dart' show BoxFit;

import '../../domain/service/pose_capture_service.dart';
import '../../domain/model/face_recog_result.dart';
import '../../infrastructure/model/images_rx.dart'; // <-- RUTA CORREGIDA
import '../widgets/portrait_validator_hud.dart'
    show PortraitValidatorHUD, PortraitUiController, PortraitUiModel, Tri;
import '../widgets/frame_sequence_overlay.dart'
    show FrameSequenceOverlay, FrameSequenceController, FramePlayMode;
import '../../domain/validators/portrait_validations.dart'
    show PortraitValidator, PortraitValidationContext, defaultPortraitRules;
// ⬇️ NEW: centralized, data-driven thresholds & bands
import '../../domain/entity/validation_profile.dart' show ValidationProfile, GateSense;

import '../../domain/metrics/pose_geometry.dart' as geom;  // ⬅️ NUEVO
import '../../domain/metrics/metrics.dart';
import '../../domain/metrics/head_pose.dart' show yawPitchRollFromFaceMesh;
part 'pose_capture_controller.onframe.dart';

/// Treat empty/whitespace strings as null so the HUD won't render the secondary line.
String? _nullIfBlank(String? s) => (s == null || s.trim().isEmpty) ? null : s;

/// Private direction enum must be top-level (not inside a class).
enum _TurnDir { none, left, right }

// Which overlay animation is currently active
enum _Axis { none, yaw, pitch, roll }

/// Axis stability gate with dwell + hysteresis + first-pass tightening.
enum _GateState { searching, dwell, confirmed }

/// How to interpret the threshold comparison.
/// - insideIsOk: value <= threshold passes (yaw/pitch and roll-error).
/// - outsideIsOk: value >= threshold passes (modo legado, ya no usado para roll).
enum _GateSense { insideIsOk, outsideIsOk }

class _AxisGate {
  _AxisGate({
    required this.baseDeadband,
    this.sense = _GateSense.insideIsOk,
    this.tighten = 0.2,
    this.hysteresis = 0.2,
    this.dwell = const Duration(milliseconds: 500),
    this.extraRelaxAfterFirst = 0.2,
  });

  final double baseDeadband;
  final _GateSense sense;
  final double tighten;
  final double hysteresis;
  final Duration dwell;
  final double extraRelaxAfterFirst;

  bool hasConfirmedOnce = false;

  /// Ya ocurrió el primer intento del eje (donde el band es estricto).
  bool _firstAttemptDone = false;

  /// Modo de “apriete” dinámico:
  /// - true  → usar deadband estricto (base ± tighten)
  /// - false → usar deadband relajado (base)
  bool _strictActive = true;

  _GateState _state = _GateState.searching;
  DateTime? _dwellStart;

  bool get isSearching => _state == _GateState.searching;
  bool get isDwell => _state == _GateState.dwell;
  bool get isConfirmed => _state == _GateState.confirmed;

  bool get firstAttemptDone => _firstAttemptDone;
  bool get isStrictActive => _strictActive;

  void resetTransient() {
    _state = _GateState.searching;
    _dwellStart = null;
    // No tocamos _strictActive aquí: es “memoria” del modo actual.
  }

  void resetForNewStage() {
    _state = _GateState.searching;
    _dwellStart = null;
    _firstAttemptDone = false;
    hasConfirmedOnce = false;
    _strictActive = true; // primer intento estricto
  }

  double get enterBand {
    final bool strict = _strictActive;
    if (sense == _GateSense.insideIsOk) {
      return strict ? (baseDeadband - tighten) : baseDeadband;
    } else {
      return strict ? (baseDeadband + tighten) : baseDeadband;
    }
  }

  double get exitBand {
    final e = enterBand;
    return (sense == _GateSense.insideIsOk) ? (e + hysteresis) : (e - hysteresis);
  }

  bool _isOk(double v, double th) =>
      (sense == _GateSense.insideIsOk) ? (v <= th) : (v >= th);

  double _withRelax(double th, double relax) =>
      (sense == _GateSense.insideIsOk) ? (th + relax) : (th - relax);

  void _retighten() => _strictActive = true;
  void _relax() => _strictActive = false;

  /// Reglas:
  /// 1) Primer intento: estricto. Si rompe, segundo intento arranca relajado.
  /// 2) Si en intentos ≥2 rompe dwell/confirmed estando relajado → re-apretar.
  /// 3) Mientras esté apretado en intentos ≥2, al volver a entrar al band estricto,
  ///    volvemos a relajar (y el dwell comienza en el siguiente tick ya relajado).
  bool update(double metricDeg, DateTime now) {
    switch (_state) {
      case _GateState.searching:
        // ⬅️ NUEVO: si estamos en modo ESTRICTO y se toca el enterBand estricto,
        // relajamos de inmediato y NO iniciamos dwell en este tick.
        if (_strictActive && _isOk(metricDeg, enterBand)) {
          if (!_firstAttemptDone) _firstAttemptDone = true;
          _relax();
          // Inicio de dwell en el mismo tick si ya cumple el band relajado
          if (_isOk(metricDeg, enterBand)) {
            _dwellStart = now;
            _state = _GateState.dwell;
          }
          return false;
        }

        // Si estamos RELAJADOS y ya cumplimos el enterBand (base), iniciamos dwell.
        if (!_strictActive && _isOk(metricDeg, enterBand)) {
          _dwellStart = now;
          _state = _GateState.dwell;
        }
        return false;

      case _GateState.dwell:
        // Si nos salimos del band ampliado (exitBand), reapretar y volver a buscar.
        if (!_isOk(metricDeg, exitBand)) {
          _state = _GateState.searching;
          _dwellStart = null;
          _retighten(); // ⬅️ siempre reaprieta al perder el dwell ampliado
          return false;
        }
        // Tiempo de dwell cumplido ⇒ confirmar.
        if (now.difference(_dwellStart!) >= dwell) {
          _state = _GateState.confirmed;
          hasConfirmedOnce = true;
          return true;
        }
        return false;

      case _GateState.confirmed:
        // Permite una pequeña relajación adicional si la configuraste.
        final double relax = hasConfirmedOnce ? extraRelaxAfterFirst : 0.0;
        final double exitWithRelax = _withRelax(exitBand, relax);

        // Si se pierde la confirmación (fuera del band ampliado + relax),
        // volvemos a SEARCHING y reapretamos. Para re-capturar:
        // tocar estricto ⇒ relajarse ⇒ dwell otra vez en ampliado.
        if (!_isOk(metricDeg, exitWithRelax)) {
          _state = _GateState.searching;
          _dwellStart = null;
          _retighten(); // ⬅️ clave: reactivar estricto al perder confirmación
          return false;
        }
        return true;
    }
  }
}

// ───────────────────────────────────────────────────────────────────────────
// MÓDULOS PRIVADOS (mismo archivo) — para modularizar countdown, captura y roll
// ───────────────────────────────────────────────────────────────────────────

typedef SnapshotFn = Future<Uint8List?> Function();

/// Métricas de roll tras filtrar/unwrap
class _RollFilterMetrics {
  final double errDeg;       // distancia a 180° (0 = perfecto)
  final double dps;          // grados/seg en señal suavizada
  final double smoothedDeg;  // roll suavizado (unwrapped) para HUD/debug
  const _RollFilterMetrics(this.errDeg, this.dps, this.smoothedDeg);
}

/// Filtro de roll con unwrap + EMA + dps
class _RollFilter {
  _RollFilter({required this.tauMs});
  final double tauMs;

  double? _smoothedDeg;
  DateTime? _lastAt;

  double _wrapDeg180(double x) => ((x + 180.0) % 360.0) - 180.0;
  double _distTo180(double deg) => _wrapDeg180(deg - 180.0).abs();

  _RollFilterMetrics update(double rawRollDeg, DateTime now) {
    if (_smoothedDeg == null || _lastAt == null) {
      _smoothedDeg = rawRollDeg;
      _lastAt = now;
      return _RollFilterMetrics(_distTo180(_smoothedDeg!), 0.0, _smoothedDeg!);
    }

    final prev = _smoothedDeg!;
    double cur = rawRollDeg;
    double delta = cur - prev;
    if (delta > 180.0) cur -= 360.0;
    if (delta < -180.0) cur += 360.0;

    final dtMs = now.difference(_lastAt!).inMilliseconds.clamp(1, 1000);
    final alpha = 1.0 - math.exp(-dtMs / tauMs);

    final next = prev + alpha * (cur - prev);
    final dps = ((next - prev) / dtMs) * 1000.0;

    _smoothedDeg = next;
    _lastAt = now;

    return _RollFilterMetrics(_distTo180(next), dps, next);
  }
}

/// Controlador de cuenta regresiva reutilizable
class _Countdown {
  _Countdown({
    required this.duration,
    required this.fps,
    required this.speed,
    required this.isOkNow,
    required this.onTick,
    required this.onFire,
    required this.onAbort,
  })  : assert(fps > 0),
        assert(speed > 0);

  final Duration duration;
  final int fps;
  final double speed;

  /// Debe ser true para continuar (validaciones mantienen "ok")
  final bool Function() isOkNow;

  /// (seconds, progress[0..1]) → para HUD
  final void Function(int seconds, double progress) onTick;

  /// Acción final (disparo/captura)
  final Future<void> Function() onFire;

  /// Abort callback (e.g., clear HUD)
  final void Function() onAbort;

  Timer? _ticker;
  bool get isRunning => _ticker != null;

  void start() {
    stop();

    final totalLogicalMs = duration.inMilliseconds;
    final totalScaledMs = (totalLogicalMs / speed).round().clamp(1, 86400000);
    int seconds = (totalLogicalMs / 1000.0).ceil();
    double progress = 1.0;

    // Push inicial
    onTick(seconds, progress);

    final tickMs = (1000 / fps).round().clamp(10, 1000);
    int elapsedScaled = 0;
    bool firedAtOne = false;

    _ticker = Timer.periodic(Duration(milliseconds: tickMs), (t) async {
      elapsedScaled += tickMs;

      final remainingScaledMs =
          (totalScaledMs - elapsedScaled).clamp(0, totalScaledMs);
      progress = remainingScaledMs / totalScaledMs;

      final remainingLogicalMs =
          (remainingScaledMs / totalScaledMs * totalLogicalMs).round();
      final nextSeconds =
          (remainingLogicalMs / 1000.0).ceil().clamp(1, seconds);

      if (nextSeconds != seconds) seconds = nextSeconds;

      onTick(seconds, progress);

      if (!isOkNow()) {
        stop();
        onAbort();
        return;
      }

      // Early fire al llegar a "1"
      if (!firedAtOne && seconds == 1) {
        firedAtOne = true;
        stop();
        await onFire();
        return;
      }

      // Fin normal
      if (!firedAtOne && elapsedScaled >= totalScaledMs) {
        firedAtOne = true;
        stop();
        await onFire();
        return;
      }
    });
  }

  void stop() {
    _ticker?.cancel();
    _ticker = null;
  }
}

/// Pipeline de captura (WebRTC → fallback)
class _Capture {
  static Future<Uint8List?> tryAll(
    PoseCaptureService svc,
    SnapshotFn? fallback,
  ) async {
    // 1) WebRTC track
    try {
      final stream = svc.localRenderer.srcObject ?? svc.localStream;
      if (stream != null && stream.getVideoTracks().isNotEmpty) {
        final track = stream.getVideoTracks().first;
        final dynamic dynTrack = track;
        final Object data = await dynTrack.captureFrame(); // plugin-specific
        if (data is Uint8List && data.isNotEmpty) return data;
        if (data is ByteBuffer) return data.asUint8List();
        if (data is ByteData) {
          return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
        }
      }
    } catch (_) {
      // continúa a fallback
    }

    // 2) Fallback a snapshot proporcionado por widget/controlador
    if (fallback != null) {
      try {
        final bytes = await fallback();
        if (bytes != null && bytes.isNotEmpty) return bytes;
      } catch (_) {/* noop */}
    }
    return null;
  }
}

// ───────────────────────────────────────────────────────────────────────────
// Estructuras usadas por onframe (compatibilidad con tu extensión existente)
// ───────────────────────────────────────────────────────────────────────────

/// Pequeño contenedor para métrica de roll usado en onframe
class _RollMetrics {
  final double errDeg; // distancia a 180°, en grados (0 = perfecto)
  final double dps;    // velocidad angular (grados/seg) sobre señal suavizada
  const _RollMetrics(this.errDeg, this.dps);
}

class _CaptureProcessingCancelled implements Exception {
  const _CaptureProcessingCancelled();
  @override
  String toString() => 'Capture processing cancelled';
}

/// Controller
class PoseCaptureController extends ChangeNotifier {
  PoseCaptureController({
    required this.poseService,
    required this.countdownDuration,
    required this.countdownFps,
    required this.countdownSpeed,
    this.mirror = true,
    this.validationsEnabled = true, // ⇠ NEW
    this.logEverything = false,
    ValidationProfile? validationProfile, // ⇠ NEW: inject data-driven thresholds
  })  : assert(countdownFps > 0, 'countdownFps must be > 0'),
        assert(countdownSpeed > 0, 'countdownSpeed must be > 0'),
        profile = validationProfile ?? ValidationProfile.defaultProfile, // ⇠ NEW
        hud = PortraitUiController(
          const PortraitUiModel(
            primaryMessage: 'Ubica tu rostro dentro del óvalo',
            ovalProgress: 0.0,
          ),
        ),
        seq = FrameSequenceController(
          fps: 30,
          playMode: FramePlayMode.forward,
          loop: true,
          autoplay: true,
    ) {
    // fija la misma referencia del tear-off para add/removeListener
    _frameListener = _onFrame;
    _faceRecogListener = _handleFaceRecogChanged;

    // Configura countdown con callbacks → HUD y captura integrados
    _countdown = _Countdown(
      duration: countdownDuration,
      fps: countdownFps,
      speed: countdownSpeed,
      // ⇣ Si validationsEnabled está OFF, permite countdown/captura sin gates.
      isOkNow: () => validationsEnabled
          ? (poseService.latestFrame.value != null && this._isDone)
          : true,
      onTick: (seconds, progress) {
        // ⬇️ Garantiza mostrar “¡Perfecto! ¡Permanece así!” mientras todo siga OK
        final cur = hud.value;
        final primary = (validationsEnabled && _isDone)
            ? '¡Perfecto! ¡Permanece así!'
            : cur.primaryMessage;
        _setHud(
          cur.copyWith(
            primaryMessage: primary,
            countdownSeconds: seconds,
            countdownProgress: progress,
          ),
          // puedes mantener force:false aquí
        );
      },
      // 2. <-- BLOQUE onFire ACTUALIZADO
      onFire: () async {
        // Disparo/captura
        isCapturing = true;
        isProcessingCapture = false;
        if (!_isDisposed) notifyListeners();

        final bytes = await _Capture.tryAll(poseService, _fallbackSnapshot);
        if (_isDisposed) return;

        // Verifica si la captura local falló
        if (bytes == null || bytes.isEmpty) {
          if (kDebugMode) {
            print('[pose] Local capture failed (bytes empty)');
          }
          isCapturing = false;
          isProcessingCapture = false;
          _readySince = null;
          if (!_isDisposed) notifyListeners();
          return; // Aborta
        }

        final String captureId = 'cap_${DateTime.now().millisecondsSinceEpoch}';
        _activeCaptureId = captureId;

        // Muestra la captura local de inmediato
        capturedPng = bytes;
        if (!_isDisposed) notifyListeners();

        // ⬇️ NEW: Enviar, esperar respuesta, y asignar.
        try {
          // Si el canal no está listo, deja la captura local y sal.
          if (!poseService.imagesReady) {
            if (kDebugMode) {
              print('[pose] images DC not ready; using local fallback');
            }
            return; // Sale del 'try', el 'finally' se ejecutará
          }

          // Prepara la escucha de la respuesta (sin timeout: esperar lo necesario)
          final responseFuture = _waitForProcessedImage(captureId);
          // Evita futuros con error sin handler si falla el envío antes del await.
          unawaited(responseFuture.then<void>((_) {}, onError: (_, __) {}));

          // Activa loader mientras esperamos al servidor
          isProcessingCapture = true;
          if (!_isDisposed) notifyListeners();

          // Intenta enviar la imagen
          await poseService.sendImageBytes(bytes, requestId: captureId);

          // Espera la respuesta del servidor (sin timeout)
          final ImagesRx serverResponse = await responseFuture;

          // Éxito: Asigna la imagen procesada del servidor
          if (_isDisposed || _activeCaptureId != captureId) {
            return;
          }

          if (serverResponse.bytes.isNotEmpty) {
            capturedPng = serverResponse.bytes;
          } else {
            // Respuesta vacía, usa local
            if (kDebugMode) {
              print('[pose] Server response empty; using local fallback');
            }
            // mantenemos la captura local ya visible
          }
        } catch (e) {
          if (e is _CaptureProcessingCancelled) {
            return;
          }
          // Fallback 2: Error en envío/espera (ej. TimeoutException)
          if (kDebugMode) {
            print('[pose] Failed to get server response, using local fallback: $e');
          }
        } finally {
          _cancelImagesWait(captureId: captureId);
          if (_isDisposed || _activeCaptureId != captureId) {
            return;
          }
          // Pase lo que pase (éxito, error, canal no listo),
          // actualiza la UI para mostrar la imagen (sea cual sea)
          isCapturing = false;
          isProcessingCapture = false;
          _readySince = null;
          notifyListeners();
        }
      },
      // FIN DEL BLOQUE onFire ACTUALIZADO

      onAbort: () {
        // Limpia HUD de countdown si aborta
        final cur = hud.value;
        _setHud(
          PortraitUiModel(
            primaryMessage: cur.primaryMessage,
            secondaryMessage: cur.secondaryMessage,
            countdownSeconds: null,
            countdownProgress: null,
            ovalProgress: cur.ovalProgress,
          ),
          force: true,
        );
        _readySince = null;
      },
    );

    // ⬇️ NEW: registra los providers de métricas (una sola vez)
    _ensureMetricsRegisteredOnce();
  }

  // ── External deps/config ──────────────────────────────────────────────
  final PoseCaptureService poseService;
  final Duration countdownDuration;
  final int countdownFps;
  final double countdownSpeed;
  final bool mirror; // front camera UX

  /// NEW: switch global de validaciones
  final bool validationsEnabled;

  final bool logEverything;

  /// ⇠ NEW: Perfil de validación inyectado (bandas y deadbands data-driven)
  final ValidationProfile profile;

  // ── Controllers owned by this class ───────────────────────────────────
  final PortraitUiController hud;
  final FrameSequenceController seq;
  late final _Countdown _countdown;

  // Centralized validator for all portrait rules (oval + yaw/pitch/roll/shoulders).
  late final PortraitValidator _validator =
      const PortraitValidator(rules: defaultPortraitRules);

  // Distancia firmada a un rango [lo, hi]:
  //   < 0  → dentro del rango (más negativo = más centrado)
  //   = 0  → en el borde
  //   > 0  → fuera (cuánto se sale)
  static double _signedDistanceToBand(double deg, double lo, double hi) {
    final l = math.min(lo, hi);
    final h = math.max(lo, hi);
    if (deg < l) return l - deg;            // por debajo del rango
    if (deg > h) return deg - h;            // por encima del rango
    final depth = math.min(deg - l, h - deg);
    return -depth;                           // negativo = “adentro”
  }

  // Keep current canvas size to map image↔canvas consistently.
  Size? _canvasSize;
  void setCanvasSize(Size s) => _canvasSize = s;

  // Countdown state
  bool get isCountingDown => _countdown.isRunning;

  // Global stability (no extra hold; gates already enforce dwell)
  DateTime? _readySince;
  static const _readyHold = Duration(milliseconds: 0);

  // Throttle HUD updates to ~15 Hz
  DateTime _lastHudPush = DateTime.fromMillisecondsSinceEpoch(0);
  // (usaremos profile.ui.hudMinInterval en _setHud)

  // Snapshot state (exposed)
  Uint8List? capturedPng; // captured bytes (from WebRTC track or boundary fallback)
  bool isCapturing = false; // Capture-mode flag to hide preview/HUD instantly at T=0
  bool isProcessingCapture = false; // waiting for server-processed image
  String? _activeCaptureId; // requestId currently shown/processed
  String? _imagesWaitCaptureId;
  StreamSubscription<ImagesRx>? _imagesWaitSub;
  Completer<ImagesRx>? _imagesWaitCompleter;
  bool _isDisposed = false;

  // Face recognition gating state
  bool _faceRecogMatch = false;
  double? _faceRecogScore;
  String? _faceRecogDecisionRaw;

  // Hint trigger & visibility for sequence
  bool _turnRightSeqLoaded = false;
  bool _turnLeftSeqLoaded = false;
  bool showTurnRightSeq = false; // used as generic overlay visibility

  // Which direction’s frames are currently loaded (for yaw)
  _TurnDir _activeTurn = _TurnDir.none;

  // Track pitch direction (true = pitch > 0)
  bool? _activePitchUp;

  // Track roll sign (true => rollDeg > 0)
  bool? _activeRollPositive;

  // NEW — eje actualmente mostrado por el overlay (para evitar “cruces” entre ejes)
  _Axis _animAxis = _Axis.none;

  // EMA smoothing for angles (yaw/pitch HUD)
  static const double _emaTauMs = 150.0; // kept for compatibility
  double? _emaYawDeg;
  double? _emaPitchDeg;
  double? _emaRollDeg; // for HUD/debug

  // ✅ Legacy smoothing state used by the existing onframe implementation
  DateTime? _lastSampleAt;   // global timestamp for EMA deltas (yaw/pitch)
  double? _rollSmoothedDeg;  // smoothed + unwrapped roll (for compatibility)
  DateTime? _rollSmoothedAt; // timestamp of last smoothed roll sample
  double? _lastRollDps;      // last angular velocity estimate for roll

  // ── Dinámica de ROLL modular ──────────────────────────────────────────
  final _RollFilter _rollFilter = _RollFilter(tauMs: 150.0);

  /// Envuelve ángulos a (-180, 180]
  double _wrapDeg180(double x) => ((x + 180.0) % 360.0) - 180.0;

  /// Distancia mínima a 180° (0 = perfecto; 2° = 178° o 182°)
  double _distTo180(double deg) => _wrapDeg180(deg - 180.0).abs();

  /// 🔧 Dirección hacia el 180° más cercano (con wrap). Resultado en [-180, 180].
  /// +delta ⇒ aumentar el ángulo; -delta ⇒ disminuirlo.
  double _deltaToNearest180(double curDeg) {
    final int k = ((curDeg - 180.0) / 360.0).round();
    final double target = 180.0 + 360.0 * k;
    return _wrapDeg180(target - curDeg);
  }

  double _normalizeTilt90(double a) {
    double x = a;
    if (x > 90.0) x -= 180.0;
    if (x <= -90.0) x += 180.0;
    return x;
  }

  // ⬇️ NEW: factor para convertir z normalizada → píxeles (calibrable)
  double? _zToPxScale;
  void setZtoPxScale(double s) => _zToPxScale = s;

  // Fallback snapshot closure (widget provides it)
  SnapshotFn? _fallbackSnapshot;
  void setFallbackSnapshot(SnapshotFn fn) {
    _fallbackSnapshot = fn;
  }

  // ── Métricas (registro y providers) ───────────────────────────────────
  final MetricRegistry _metricRegistry = MetricRegistry();

  bool _metricsReady = false;
  void _ensureMetricsRegisteredOnce() {
    if (_metricsReady) return;
    _metricsReady = true;
    _registerDefaultMetricProviders();
  }

  void _registerDefaultMetricProviders() {
    // Head pose (yaw/pitch/roll firmados)
    _metricRegistry.register(MetricKeys.yawSigned, (i) {
      final lms = i.landmarksImg;
      if (lms == null) return null;
      final imgW = i.imageSize.width.toInt();
      final imgH = i.imageSize.height.toInt();
      final ypr = yawPitchRollFromFaceMesh(lms, imgH, imgW);
      return ypr.yaw;
    });

    _metricRegistry.register(MetricKeys.pitchSigned, (i) {
      final lms = i.landmarksImg;
      if (lms == null) return null;
      final imgW = i.imageSize.width.toInt();
      final imgH = i.imageSize.height.toInt();
      final ypr = yawPitchRollFromFaceMesh(lms, imgH, imgW);
      return ypr.pitch;
    });

    _metricRegistry.register(MetricKeys.rollSigned, (i) {
      final lms = i.landmarksImg;
      if (lms == null) return null;
      final imgW = i.imageSize.width.toInt();
      final imgH = i.imageSize.height.toInt();
      final ypr = yawPitchRollFromFaceMesh(lms, imgH, imgW);
      return ypr.roll;
    });

    _metricRegistry.register(MetricKeys.yawAbs, (i) {
      final yaw = _metricRegistry.get<double>(MetricKeys.yawSigned, i);
      return yaw?.abs();
    });

    _metricRegistry.register(MetricKeys.pitchAbs, (i) {
      final pitch = _metricRegistry.get<double>(MetricKeys.pitchSigned, i);
      return pitch?.abs();
    });

    _metricRegistry.register(MetricKeys.rollErr, (i) {
      final roll = _metricRegistry.get<double>(MetricKeys.rollSigned, i);
      if (roll == null) return null;
      final delta = _deltaToNearest180(roll);
      return delta.abs();
    });

    // Hombros firmados (2D)
    _metricRegistry.register(MetricKeys.shouldersSigned, (i) {
      final pose = i.poseLandmarksImg;
      if (pose == null) return null;
      final ang = geom.calcularAnguloHombros(pose);
      if (ang == null) return null;
      return _normalizeTilt90(ang);
    });

    // Azimut del torso (3D)
    _metricRegistry.register(MetricKeys.azimutSigned, (i) {
      if (i.poseLandmarks3D == null) return null;
      final double zToPx = _zToPxScale ?? i.imageSize.width; // fallback
      return geom.estimateAzimutBiacromial3D(
        poseLandmarks3D: i.poseLandmarks3D,
        zToPx: zToPx,
        mirror: i.mirror,
      );
    });
  }

  // ── Suscripción de frames (por instancia) ─────────────────────────────
  bool _attached = false;
  late final VoidCallback _frameListener;
  late final VoidCallback _faceRecogListener;

  void _handleFaceRecogChanged() {
    final FaceRecogResult? result = poseService.faceRecogResult.value;
    final String? decision = result?.decision?.trim();
    _faceRecogDecisionRaw =
        (decision == null || decision.isEmpty) ? null : decision;
    _faceRecogScore = result?.cosSim;
    final String? normalized = _faceRecogDecisionRaw?.toUpperCase();
    _faceRecogMatch = normalized == 'MATCH';
  }

  void attach() {
    if (_attached) return;
    _attached = true;
    poseService.latestFrame.addListener(_frameListener);
    poseService.faceRecogResult.addListener(_faceRecogListener);
    _handleFaceRecogChanged();
  }

  @override
  void dispose() {
    _isDisposed = true;
    _cancelImagesWait();
    if (_attached) {
      poseService.latestFrame.removeListener(_frameListener);
      poseService.faceRecogResult.removeListener(_faceRecogListener);
      _attached = false;
    }
    _countdown.stop();
    seq.dispose();
    hud.dispose();
    super.dispose();
  }

  void _cleanupImagesWait() {
    final sub = _imagesWaitSub;
    _imagesWaitSub = null;
    _imagesWaitCaptureId = null;
    if (sub != null) {
      unawaited(sub.cancel());
    }
  }

  void _cancelImagesWait({String? captureId}) {
    if (captureId != null &&
        _imagesWaitCaptureId != null &&
        _imagesWaitCaptureId != captureId) {
      return;
    }

    final completer = _imagesWaitCompleter;
    _imagesWaitCompleter = null;
    if (completer != null && !completer.isCompleted) {
      completer.completeError(const _CaptureProcessingCancelled());
    }
    _cleanupImagesWait();
  }

  Future<ImagesRx> _waitForProcessedImage(String captureId) {
    _cancelImagesWait();

    final completer = Completer<ImagesRx>();
    _imagesWaitCompleter = completer;
    _imagesWaitCaptureId = captureId;
    _imagesWaitSub = poseService.imagesProcessed.listen(
      (imgRx) {
        if (imgRx.requestId != captureId) return;
        if (_imagesWaitCompleter != completer) return;

        if (!completer.isCompleted) {
          completer.complete(imgRx);
        }
        _imagesWaitCompleter = null;
        _cleanupImagesWait();
      },
      onError: (Object error, StackTrace st) {
        if (_imagesWaitCompleter != completer) return;
        if (!completer.isCompleted) {
          completer.completeError(error, st);
        }
        _imagesWaitCompleter = null;
        _cleanupImagesWait();
      },
      onDone: () {
        if (_imagesWaitCompleter != completer) return;
        if (!completer.isCompleted) {
          completer.completeError(StateError('imagesProcessed stream closed'));
        }
        _imagesWaitCompleter = null;
        _cleanupImagesWait();
      },
    );
    return completer.future;
  }

  // ── Public actions ────────────────────────────────────────────────────
  void closeCaptured() {
    final captureId = _activeCaptureId;
    _activeCaptureId = null;
    _cancelImagesWait(captureId: captureId);
    capturedPng = null;
    isCapturing = false;
    isProcessingCapture = false;
    _readySince = null;
    if (!_isDisposed) notifyListeners();
  }

  // Keep the same name/signature used by addListener tear-off:
  void _onFrame() => this._onFrameImpl(); // calls the extension method
}

// ───────────────────────────────────────────────────────────────────────────
// Modular helpers as extensions (same file, private)
// ───────────────────────────────────────────────────────────────────────────

extension _HudHelpers on PoseCaptureController {
  void _setHud(PortraitUiModel next, {bool force = false}) {
    final now = DateTime.now();
    if (!force && now.difference(_lastHudPush) < profile.ui.hudMinInterval) return;

    final cur = hud.value;
    final same =
        cur.primaryMessage == next.primaryMessage &&
        cur.secondaryMessage == next.secondaryMessage &&
        cur.countdownSeconds == next.countdownSeconds &&
        cur.countdownProgress == next.countdownProgress &&
        cur.ovalProgress == next.ovalProgress;

    if (!same) {
      hud.value = next;
      _lastHudPush = now;
    }
  }
}

extension _CountdownHelpers on PoseCaptureController {
  void _startCountdown() {
    _countdown.start();
  }

  void _stopCountdown() {
    _countdown.stop();

    _readySince = null;

    final cur = hud.value;
    _setHud(
      PortraitUiModel(
        primaryMessage: cur.primaryMessage,
        secondaryMessage: cur.secondaryMessage,
        countdownSeconds: null, // cleared for real
        countdownProgress: null, // cleared for real
        ovalProgress: cur.ovalProgress,
      ),
      force: true,
    );
  }
}
