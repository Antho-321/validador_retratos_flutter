// ==========================
// lib/features/posture/presentation/controllers/pose_capture_controller.dart
// ==========================
import 'dart:async';
import 'dart:typed_data' show Uint8List, ByteBuffer, ByteData;
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary; // kept for types
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'dart:ui' show Size;
import 'package:flutter/painting.dart' show BoxFit;

import '../../services/pose_webrtc_service.dart';
import '../widgets/portrait_validator_hud.dart'
    show PortraitValidatorHUD, PortraitUiController, PortraitUiModel, Tri;
import '../widgets/frame_sequence_overlay.dart'
    show FrameSequenceOverlay, FrameSequenceController, FramePlayMode;
import '../../domain/validators/portrait_validations.dart'
    show PortraitValidator;
// ⬇️ NEW: centralized, data-driven thresholds & bands
import '../../domain/validation_profile.dart' show ValidationProfile, GateSense;

// ⬇️ add this line:
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
        if (_firstAttemptDone && _strictActive && _isOk(metricDeg, enterBand)) {
          _relax();
          return false; // no iniciamos dwell en este mismo update
        }

        if (_isOk(metricDeg, enterBand)) {
          if (!_firstAttemptDone) {
            _firstAttemptDone = true; // a partir de ahora hay “segundo intento”
          }
          _dwellStart = now;
          _state = _GateState.dwell;
        }
        return false;

      case _GateState.dwell:
        if (!_isOk(metricDeg, exitBand)) {
          _state = _GateState.searching;
          _dwellStart = null;

          if (_firstAttemptDone && !_strictActive) {
            _retighten();
          }
          return false;
        }
        if (now.difference(_dwellStart!) >= dwell) {
          _state = _GateState.confirmed;
          hasConfirmedOnce = true;
          return true;
        }
        return false;

      case _GateState.confirmed:
        final double relax = hasConfirmedOnce ? extraRelaxAfterFirst : 0.0;
        final double exitWithRelax = _withRelax(exitBand, relax);
        if (!_isOk(metricDeg, exitWithRelax)) {
          _state = _GateState.searching;
          _dwellStart = null;

          if (_firstAttemptDone) {
            _relax();
          }
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

/// Tuning centralizado
class _Tuning {
  final double yawDeadbandDeg;
  final double pitchDeadbandDeg;
  final double shouldersDeadbandDeg;
  final double rollErrorDeadbandDeg;
  final double maxOffDeg;
  final double rollHintDeadzoneDeg;
  final double emaTauMs;
  final double rollMaxDpsDuringDwell;
  final Duration hudMinInterval;

  const _Tuning({
    this.yawDeadbandDeg = 2.2,
    this.pitchDeadbandDeg = 2.2,
    this.shouldersDeadbandDeg = 1.8,
    this.rollErrorDeadbandDeg = 1.7,
    this.maxOffDeg = 20.0,
    this.rollHintDeadzoneDeg = 0.3,
    this.emaTauMs = 150.0,
    this.rollMaxDpsDuringDwell = 15.0,
    this.hudMinInterval = const Duration(milliseconds: 66),
  });
}

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
        await onFire();
        stop();
        return;
      }

      // Fin normal
      if (!firedAtOne && elapsedScaled >= totalScaledMs) {
        await onFire();
        stop();
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
    PoseWebRTCService svc,
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

/// Controller
class PoseCaptureController extends ChangeNotifier {
  PoseCaptureController({
    required this.poseService,
    required this.countdownDuration,
    required this.countdownFps,
    required this.countdownSpeed,
    this.mirror = true,
    this.validationsEnabled = true, // ⇠ NEW
    _Tuning? tuning, // opcional para ajustar parámetros en tests
    ValidationProfile? validationProfile, // ⇠ NEW: inject data-driven thresholds
  })  : assert(countdownFps > 0, 'countdownFps must be > 0'),
        assert(countdownSpeed > 0, 'countdownSpeed must be > 0'),
        _tuning = tuning ?? const _Tuning(),
        profile = validationProfile ?? ValidationProfile.defaultProfile, // ⇠ NEW
        hud = PortraitUiController(
          const PortraitUiModel(
            statusLabel: 'Adjusting',
            privacyLabel: 'On-device',
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
        _setHud(
          hud.value.copyWith(
            countdownSeconds: seconds,
            countdownProgress: progress,
          ),
        );
      },
      onFire: () async {
        // Disparo/captura
        isCapturing = true;
        notifyListeners();

        final bytes = await _Capture.tryAll(poseService, _fallbackSnapshot);
        if (bytes != null && bytes.isNotEmpty) {
          capturedPng = bytes;
        }

        isCapturing = false;
        _readySince = null;
        notifyListeners();
      },
      onAbort: () {
        // Limpia HUD de countdown si aborta
        final cur = hud.value;
        _setHud(
          PortraitUiModel(
            statusLabel: cur.statusLabel,
            privacyLabel: cur.privacyLabel,
            primaryMessage: cur.primaryMessage,
            secondaryMessage: cur.secondaryMessage,
            checkFraming: cur.checkFraming,
            checkHead: cur.checkHead,
            checkEyes: cur.checkEyes,
            checkLighting: cur.checkLighting,
            checkBackground: cur.checkBackground,
            countdownSeconds: null,
            countdownProgress: null,
            ovalProgress: cur.ovalProgress,
          ),
          force: true,
        );
        _readySince = null;
      },
    );
  }

  // ── External deps/config ──────────────────────────────────────────────
  final PoseWebRTCService poseService;
  final Duration countdownDuration;
  final int countdownFps;
  final double countdownSpeed;
  final bool mirror; // front camera UX

  /// NEW: switch global de validaciones
  final bool validationsEnabled;

  final _Tuning _tuning;

  /// ⇠ NEW: Perfil de validación inyectado (bandas y deadbands data-driven)
  final ValidationProfile profile;

  // ── Controllers owned by this class ───────────────────────────────────
  final PortraitUiController hud;
  final FrameSequenceController seq;
  late final _Countdown _countdown;

  // Centralized validator for all portrait rules (oval + yaw/pitch/roll/shoulders).
  final PortraitValidator _validator = const PortraitValidator();

  // ─────────────────────────────────────────────────────────────────────
  // Legacy static constants kept for backwards compatibility with the
  // current onframe part. New code should read from [profile] instead.
  // ─────────────────────────────────────────────────────────────────────
  // Angle thresholds (deg) — USED ONLY BY LEGACY CALL SITES IN THE PART FILE.
  static const double _maxOffDeg = 20.0;
  static const double _rollHintDeadzoneDeg = 0.3;
  
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
  // (usaremos _tuning.hudMinInterval en _setHud)

  // Snapshot state (exposed)
  Uint8List? capturedPng; // captured bytes (from WebRTC track or boundary fallback)
  bool isCapturing = false; // Capture-mode flag to hide preview/HUD instantly at T=0

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
  static const double _rollMaxDpsDuringDwell = 15.0; // compatibilidad
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

  // ⬇️ NEW: factor para convertir z normalizada → píxeles (calibrable)
  double? _zToPxScale;
  void setZtoPxScale(double s) => _zToPxScale = s;

  /// ⬇️ NEW: Estimación de azimut biacromial (torso yaw) en grados.
  /// Usa hombros 3D (índices 11, 12). Devuelve null si no hay 3D.
  double? _estimateAzimutBiacromial() {
    final lms3d = poseService.latestPoseLandmarks3D;
    if (lms3d == null || lms3d.length <= 12) return null;

    final ls = lms3d[11]; // left shoulder
    final rs = lms3d[12]; // right shoulder

    // z is nullable → guard it
    final double? rz = rs.z;
    final double? lz = ls.z;
    if (rz == null || lz == null) return null; // no depth this frame

    final double dx = (rs.x - ls.x);
    final double dxPx = dx.abs();
    if (dxPx <= 1e-6) return 0.0;

    // ensure this is double, not num
    final double imgW =
        poseService.latestFrame.value?.imageSize.width ??
        _canvasSize?.width ??
        640.0;

    final double zToPx = (_zToPxScale ?? imgW);

    // now safe: rz/lz are non-null doubles
    final double dzPx = (rz - lz) * zToPx;

    double deg = math.atan2(dzPx, dxPx) * 180.0 / math.pi;
    if (mirror) deg = -deg;
    return deg;
  }

  // Fallback snapshot closure (widget provides it)
  SnapshotFn? _fallbackSnapshot;
  void setFallbackSnapshot(SnapshotFn fn) {
    _fallbackSnapshot = fn;
  }

  // ── Suscripción de frames (por instancia) ─────────────────────────────
  bool _attached = false;
  late final VoidCallback _frameListener;

  void attach() {
    if (_attached) return;
    _attached = true;
    poseService.latestFrame.addListener(_frameListener);
  }

  @override
  void dispose() {
    if (_attached) {
      poseService.latestFrame.removeListener(_frameListener);
      _attached = false;
    }
    _countdown.stop();
    seq.dispose();
    hud.dispose();
    super.dispose();
  }

  // ── Public actions ────────────────────────────────────────────────────
  void closeCaptured() {
    capturedPng = null;
    isCapturing = false;
    _readySince = null;
    notifyListeners();
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
    if (!force && now.difference(_lastHudPush) < _tuning.hudMinInterval) return;

    final cur = hud.value;
    final same =
        cur.statusLabel == next.statusLabel &&
        cur.primaryMessage == next.primaryMessage &&
        cur.secondaryMessage == next.secondaryMessage &&
        cur.countdownSeconds == next.countdownSeconds &&
        cur.countdownProgress == next.countdownProgress &&
        cur.checkFraming == next.checkFraming &&
        cur.checkHead == next.checkHead &&
        cur.checkEyes == next.checkEyes &&
        cur.checkLighting == next.checkLighting &&
        cur.checkBackground == next.checkBackground &&
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
        statusLabel: cur.statusLabel,
        privacyLabel: cur.privacyLabel,
        primaryMessage: cur.primaryMessage,
        secondaryMessage: cur.secondaryMessage,
        checkFraming: cur.checkFraming,
        checkHead: cur.checkHead,
        checkEyes: cur.checkEyes,
        checkLighting: cur.checkLighting,
        checkBackground: cur.checkBackground,
        countdownSeconds: null, // cleared for real
        countdownProgress: null, // cleared for real
        ovalProgress: cur.ovalProgress,
      ),
      force: true,
    );
  }
}
