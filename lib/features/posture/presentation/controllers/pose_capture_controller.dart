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

// ⬇️ add this line:
part 'pose_capture_controller.onframe.dart';

/// Treat empty/whitespace strings as null so the HUD won't render the secondary line.
String? _nullIfBlank(String? s) => (s == null || s.trim().isEmpty) ? null : s;

/// Private direction enum must be top-level (not inside a class).
enum _TurnDir { none, left, right }

// Which overlay animation is currently active
enum _Axis { none, yaw, pitch, roll }

/// Sequential flow: enforce yaw → pitch → roll → shoulders
enum _FlowStage { yaw, pitch, roll, shoulders, done }

/// Axis stability gate with dwell + hysteresis + first-pass tightening.
/// Implements Proposal 1 (+ touch of Proposal 2).
enum _GateState { searching, dwell, confirmed }

/// How to interpret the threshold comparison.
/// - insideIsOk: value <= threshold passes (yaw/pitch and roll-error).
/// - outsideIsOk: value >= threshold passes (modo legado, ya no usado para roll).
enum _GateSense { insideIsOk, outsideIsOk }

class _AxisGate {
  _AxisGate({
    required this.baseDeadband,
    this.sense = _GateSense.insideIsOk, // default matches yaw/pitch behavior
    this.tighten = 0.2,
    this.hysteresis = 0.2,
    this.dwell = const Duration(milliseconds: 500),
    this.extraRelaxAfterFirst = 0.2,
  });

  final double baseDeadband; // p.ej., yaw/pitch: 2.2°, roll: error a 180° (p.ej., 1.7°)
  final _GateSense sense;
  final double tighten; // e.g., 0.2° → first pass stricter
  final double hysteresis; // inside: exit = enter + hys, outside: exit = enter - hys
  final Duration dwell; // e.g., 500 ms
  final double extraRelaxAfterFirst; // extra room after first confirm while confirmed

  bool hasConfirmedOnce = false;

  // Endurecer solo en el primer intento del eje; desde el segundo intento, deadband base.
  bool _firstAttemptDone = false;

  _GateState _state = _GateState.searching;
  DateTime? _dwellStart;

  // Exponer estado para UI/decisiones
  bool get isSearching => _state == _GateState.searching;
  bool get isDwell => _state == _GateState.dwell;
  bool get isConfirmed => _state == _GateState.confirmed;

  /// Reinicia el intento actual (p. ej., por ruptura momentánea) pero mantiene
  /// el conocimiento de si ya hubo primer intento.
  void resetTransient() {
    _state = _GateState.searching;
    _dwellStart = null;
  }

  /// Reinicia totalmente el eje (nuevo “primer intento”).
  void resetForNewStage() {
    _state = _GateState.searching;
    _dwellStart = null;
    _firstAttemptDone = false;
    hasConfirmedOnce = false;
  }

  // tighten SOLO en primer intento.
  // - insideIsOk (yaw/pitch y roll-error): primer intento más estricto = umbral más pequeño.
  // - outsideIsOk (legado): primer intento más estricto = umbral más grande.
  double get enterBand {
    final strict = !_firstAttemptDone; // solo primer intento
    if (!strict) return baseDeadband;
    return (sense == _GateSense.insideIsOk)
        ? (baseDeadband - tighten)
        : (baseDeadband + tighten);
  }

  double get exitBand {
    final e = enterBand;
    return (sense == _GateSense.insideIsOk) ? (e + hysteresis) : (e - hysteresis);
  }

  bool _isOk(double v, double th) =>
      (sense == _GateSense.insideIsOk) ? (v <= th) : (v >= th);

  double _withRelax(double th, double relax) =>
      (sense == _GateSense.insideIsOk) ? (th + relax) : (th - relax);

  /// Update with a metric in degrees and current time.
  /// Para yaw/pitch, usa |ángulo|; para roll, usa **error a 180°**.
  bool update(double metricDeg, DateTime now) {
    switch (_state) {
      case _GateState.searching:
        if (_isOk(metricDeg, enterBand)) {
          // Siempre inicia dwell; nunca confirmar de inmediato.
          _firstAttemptDone = true; // a partir de ahora, intentos menos estrictos
          _dwellStart = now;
          _state = _GateState.dwell;
        }
        return false;

      case _GateState.dwell:
        if (!_isOk(metricDeg, exitBand)) {
          // Se rompió el dwell → reiniciar intento (sin endurecimiento adicional).
          _state = _GateState.searching;
          _dwellStart = null;
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
    _Tuning? tuning, // opcional para ajustar parámetros en tests
  })  : assert(countdownFps > 0, 'countdownFps must be > 0'),
        assert(countdownSpeed > 0, 'countdownSpeed must be > 0'),
        _tuning = tuning ?? const _Tuning(),
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
    // Configura countdown con callbacks → HUD y captura integrados
    _countdown = _Countdown(
      duration: countdownDuration,
      fps: countdownFps,
      speed: countdownSpeed,
      isOkNow: () => poseService.latestFrame.value != null && _stage == _FlowStage.done,
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
  final _Tuning _tuning;

  // ── Controllers owned by this class ───────────────────────────────────
  final PortraitUiController hud;
  final FrameSequenceController seq;
  late final _Countdown _countdown;

  // Centralized validator for all portrait rules (oval + yaw/pitch/roll/shoulders).
  final PortraitValidator _validator = const PortraitValidator();

  // Angle thresholds (deg) — mantenidas por compatibilidad con ext onframe
  static const double _yawDeadbandDeg = 2.2;
  static const double _pitchDeadbandDeg = 2.2;
  static const double _shouldersDeadbandDeg = 1.8;
  static const double _rollErrorDeadbandDeg = 1.7;
  static const double _maxOffDeg = 20.0;
  static const double _rollHintDeadzoneDeg = 0.3;

  // Axis gates (Proposal 1 + adjustments)
  final _AxisGate _yawGate = _AxisGate(
    baseDeadband: _yawDeadbandDeg,
    tighten: 1.4,
    hysteresis: 0.2,
    dwell: Duration(milliseconds: 1000),
    extraRelaxAfterFirst: 0.2,
  );
  final _AxisGate _pitchGate = _AxisGate(
    baseDeadband: _pitchDeadbandDeg,
    tighten: 1.4,
    hysteresis: 0.2,
    dwell: Duration(milliseconds: 1000),
    extraRelaxAfterFirst: 0.2,
  );

  // ROLL: métrica unificada = **distancia a 180°** → insideIsOk (≤ umbral)
  final _AxisGate _rollGate = _AxisGate(
    baseDeadband: _rollErrorDeadbandDeg,
    sense: _GateSense.insideIsOk, // unificado
    tighten: 0.4,
    hysteresis: 0.3,
    dwell: Duration(milliseconds: 1000),
    extraRelaxAfterFirst: 0.4,
  );

  // ⬇️ NEW: Shoulders use same mechanics; keep a small dwell to avoid flicker.
  final _AxisGate _shouldersGate = _AxisGate(
    baseDeadband: _shouldersDeadbandDeg,
    sense: _GateSense.insideIsOk,
    tighten: 1.4,
    hysteresis: 0.2,
    dwell: Duration(milliseconds: 1000),
    extraRelaxAfterFirst: 0.2,
  );

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

  // Sequential flow stage
  _FlowStage _stage = _FlowStage.yaw;

  // Fallback snapshot closure (widget provides it)
  SnapshotFn? _fallbackSnapshot;
  void setFallbackSnapshot(SnapshotFn fn) {
    _fallbackSnapshot = fn;
  }

  // Lifecycle wiring
  void attach() {
    poseService.latestFrame.addListener(_onFrame);
  }

  @override
  void dispose() {
    poseService.latestFrame.removeListener(_onFrame);
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

extension _FlowHelpers on PoseCaptureController {
  // Reset sequential flow (use when face lost or to restart the process)
  void _resetFlow() {
    _stage = _FlowStage.yaw;

    _yawGate.resetForNewStage();
    _pitchGate.resetForNewStage();
    _rollGate.resetForNewStage();
    _shouldersGate.resetForNewStage(); // ⬅️ NEW
  }

  // Helper: does a confirmed axis still hold its stability?
  // Recuerda: para roll se debe pasar el **error** a 180° como metricDeg.
  bool _isHolding(_AxisGate g, double metricDeg) {
    final exit = g.exitBand;
    final relax = g.hasConfirmedOnce ? g.extraRelaxAfterFirst : 0.0;
    final bool inside = g.sense == _GateSense.insideIsOk;
    // inside: ok si ≤ exit+relax; outside: ok si ≥ exit-relax
    return inside ? (metricDeg <= exit + relax) : (metricDeg >= exit - relax);
  }
}

extension _RollMathKinematics on PoseCaptureController {
  /// Actualiza cinemática de roll usando el filtro modular (unwrap + EMA + dps)
  /// y mantiene sincronizados los campos legados usados por onframe.
  _RollMetrics updateRollKinematics(double rawRollDeg, DateTime now) {
    final m = _rollFilter.update(rawRollDeg, now);

    // ✅ Mantener compatibilidad con el onframe existente
    _rollSmoothedDeg = m.smoothedDeg;
    _rollSmoothedAt = now;
    _lastRollDps = m.dps;

    // Si el usuario se mueve demasiado durante dwell, reinicia intento
    if (_rollGate.isDwell && m.dps.abs() > _tuning.rollMaxDpsDuringDwell) {
      _rollGate.resetTransient();
    }

    // (Opcional) sincronizar _emaRollDeg si tu HUD lo muestra
    _emaRollDeg = m.smoothedDeg;

    return _RollMetrics(m.errDeg, m.dps);
  }
}


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
