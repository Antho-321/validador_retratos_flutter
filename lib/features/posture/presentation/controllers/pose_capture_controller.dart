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
    // _firstAttemptDone se conserva: segundo intento y siguientes quedan menos estrictos.
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

/// Pequeño contenedor para métrica de roll
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
  })  : assert(countdownFps > 0, 'countdownFps must be > 0'),
        assert(countdownSpeed > 0, 'countdownSpeed must be > 0'),
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
        );

  // ── External deps/config ──────────────────────────────────────────────
  final PoseWebRTCService poseService;
  final Duration countdownDuration;
  final int countdownFps;
  final double countdownSpeed;
  final bool mirror; // front camera UX

  // ── Controllers owned by this class ───────────────────────────────────
  final PortraitUiController hud;
  final FrameSequenceController seq;

  // Centralized validator for all portrait rules (oval + yaw/pitch/roll/shoulders).
  final PortraitValidator _validator = const PortraitValidator();

  // Angle thresholds (deg)
  static const double _yawDeadbandDeg = 2.2;
  static const double _pitchDeadbandDeg = 2.2;
  // ⬇️ NEW: shoulders tilt (absolute degrees of shoulder-line slope)
  static const double _shouldersDeadbandDeg = 1.8;

  // Para roll AHORA usamos **error a 180°** en grados (no 178.x).
  // Ej.: tolerar ±1.7° alrededor de 180° ⇒ error ≤ 1.7°
  static const double _rollErrorDeadbandDeg = 1.7;

  static const double _maxOffDeg = 20.0;

  // 👇 Opcional (para usar en el onframe): zona muerta para no cambiar
  // el texto cuando ya estás prácticamente en 180°.
  static const double _rollHintDeadzoneDeg = 0.3;

  // Axis gates (Proposal 1 + adjustments)
  final _AxisGate _yawGate = _AxisGate(
    baseDeadband: _yawDeadbandDeg,
    tighten: 1.4,
    hysteresis: 0.2,
    dwell: Duration(milliseconds: 0),
    extraRelaxAfterFirst: 0.2,
  );
  final _AxisGate _pitchGate = _AxisGate(
    baseDeadband: _pitchDeadbandDeg,
    tighten: 1.4,
    hysteresis: 0.2,
    dwell: Duration(milliseconds: 0),
    extraRelaxAfterFirst: 0.2,
  );

  // ROLL: métrica unificada = **distancia a 180°** → insideIsOk (≤ umbral)
  final _AxisGate _rollGate = _AxisGate(
    baseDeadband: _rollErrorDeadbandDeg,
    sense: _GateSense.insideIsOk, // unificado
    tighten: 0.4,
    hysteresis: 0.3,
    dwell: Duration(milliseconds: 0),
    extraRelaxAfterFirst: 0.4,
  );

  // ⬇️ NEW: Shoulders use same mechanics; keep a small dwell to avoid flicker.
  final _AxisGate _shouldersGate = _AxisGate(
    baseDeadband: _shouldersDeadbandDeg,
    sense: _GateSense.insideIsOk,
    tighten: 0.4,
    hysteresis: 0.2,
    dwell: Duration(milliseconds: 0),
    extraRelaxAfterFirst: 0.2,
  );

  // Keep current canvas size to map image↔canvas consistently.
  Size? _canvasSize;
  void setCanvasSize(Size s) => _canvasSize = s;

  // Countdown state
  Timer? _countdownTicker;
  double _countdownProgress = 1.0; // 1 → 0
  int _countdownSeconds = 3;
  bool get isCountingDown => _countdownTicker != null;

  // Global stability (no extra hold; gates already enforce dwell)
  DateTime? _readySince;
  static const _readyHold = Duration(milliseconds: 0);

  // Throttle HUD updates to ~15 Hz
  DateTime _lastHudPush = DateTime.fromMillisecondsSinceEpoch(0);
  static const _hudMinInterval = Duration(milliseconds: 66);

  // Snapshot state (exposed)
  Uint8List? capturedPng; // captured bytes (from WebRTC track or boundary fallback)
  bool isCapturing = false; // Capture-mode flag to hide preview/HUD instantly at T=0

  // Early-fire latch so we shoot as soon as digits hit '1'
  bool _firedAtOne = false;

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

  // EMA smoothing for angles (yaw/pitch siguen igual)
  static const double _emaTauMs = 150.0;
  DateTime? _lastSampleAt;
  double? _emaYawDeg;
  double? _emaPitchDeg;
  double? _emaRollDeg; // mantenida por compatibilidad si la usa el onframe

  // ── Dinámica de ROLL (unwrap + suavizado propio + velocidad) ─────────
  static const double _rollMaxDpsDuringDwell = 15.0; // umbral sugerido
  double? _rollSmoothedDeg;  // señal de roll suavizada y "unwrapped"
  DateTime? _rollSmoothedAt; // timestamp de la muestra suavizada
  double? _lastRollDps;      // velocidad angular estimada (deg/s)

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
  Future<Uint8List?> Function()? _fallbackSnapshot;
  void setFallbackSnapshot(Future<Uint8List?> Function() fn) {
    _fallbackSnapshot = fn;
  }

  // Lifecycle wiring
  void attach() {
    poseService.latestFrame.addListener(_onFrame);
  }

  @override
  void dispose() {
    poseService.latestFrame.removeListener(_onFrame);
    _stopCountdown();
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
  /// Actualiza cinemática de roll: *unwrap*, EMA propio, dps y error a 180°.
  /// Si se está en dwell y hay demasiada velocidad, reinicia el intento.
  _RollMetrics updateRollKinematics(double rawRollDeg, DateTime now) {
    // Inicialización
    if (_rollSmoothedDeg == null || _rollSmoothedAt == null) {
      _rollSmoothedDeg = rawRollDeg;
      _rollSmoothedAt = now;
      _lastRollDps = 0.0;
      final err0 = _distTo180(_rollSmoothedDeg!);
      return _RollMetrics(err0, _lastRollDps!);
    }

    // Unwrap local alrededor del último valor suavizado
    final prev = _rollSmoothedDeg!;
    double cur = rawRollDeg;
    double delta = cur - prev;
    if (delta > 180.0) cur -= 360.0;
    if (delta < -180.0) cur += 360.0;

    final dtMs = now.difference(_rollSmoothedAt!).inMilliseconds.clamp(1, 1000);
    final alpha = 1.0 -
        math.exp(-dtMs / PoseCaptureController._emaTauMs); // ⬅️ qualified

    // EMA sobre señal "cur" (ya desenvuelta)
    final next = prev + alpha * (cur - prev);

    // Velocidad sobre la señal suavizada
    final dps = ((next - prev) / dtMs) * 1000.0;

    _rollSmoothedDeg = next;
    _rollSmoothedAt = now;
    _lastRollDps = dps;

    final err = _distTo180(next);

    // Si el usuario aún se mueve demasiado durante dwell, reinicia intento
    if (_rollGate.isDwell &&
        dps.abs() > PoseCaptureController._rollMaxDpsDuringDwell) { // ⬅️ qualified
      _rollGate.resetTransient();
    }

    // (Opcional) sincronizar _emaRollDeg si tu onframe lo muestra en HUD
    _emaRollDeg = next;

    return _RollMetrics(err, dps);
  }
}

extension _HudHelpers on PoseCaptureController {
  void _setHud(PortraitUiModel next, {bool force = false}) {
    final now = DateTime.now();
    if (!force &&
        now.difference(_lastHudPush) <
            PoseCaptureController._hudMinInterval) return; // ⬅️ qualified

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

extension _CaptureHelpers on PoseCaptureController {
  Future<void> _captureFromWebRtcTrack() async {
    try {
      MediaStream? stream =
          poseService.localRenderer.srcObject ?? poseService.localStream;
      if (stream == null || stream.getVideoTracks().isEmpty) {
        throw StateError('No local WebRTC video track available');
      }

      final track = stream.getVideoTracks().first;
      final dynamic dynTrack = track;

      final Object data =
          await dynTrack.captureFrame(); // may be Uint8List / ByteBuffer / ByteData
      late final Uint8List bytes;

      if (data is Uint8List) {
        bytes = data;
      } else if (data is ByteBuffer) {
        bytes = data.asUint8List();
      } else if (data is ByteData) {
        bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      } else {
        throw StateError('Unsupported captureFrame type: ${data.runtimeType}');
      }

      if (bytes.isNotEmpty) {
        capturedPng = bytes; // if your plugin returns encoded PNG/JPEG
        isCapturing = false;
        _readySince = null;
        notifyListeners();
        return;
      }
    } catch (e) {
      // ignore: avoid_print
      print('captureFrame failed, falling back to boundary: $e');
    }

    // Fallback to widget-provided snapshot if available
    if (_fallbackSnapshot != null) {
      try {
        final bytes = await _fallbackSnapshot!.call();
        if (bytes != null && bytes.isNotEmpty) {
          capturedPng = bytes;
          isCapturing = false;
          _readySince = null;
          notifyListeners();
          return;
        }
      } catch (e) {
        // ignore
      }
    }

    // If nothing worked, recover UI
    isCapturing = false;
    notifyListeners();
  }
}

extension _CountdownHelpers on PoseCaptureController {
  void _startCountdown() {
    _stopCountdown();
    _countdownProgress = 1.0;
    _firedAtOne = false;

    final int totalLogicalMs = countdownDuration.inMilliseconds;
    final int totalScaledMs =
        (totalLogicalMs / countdownSpeed).round().clamp(1, 24 * 60 * 60 * 1000);

    _countdownSeconds = (totalLogicalMs / 1000.0).ceil();

    _setHud(
      hud.value.copyWith(
        countdownSeconds: _countdownSeconds,
        countdownProgress: _countdownProgress,
      ),
      force: true,
    );

    final int tickMs = (1000 / countdownFps).round().clamp(10, 1000);
    int elapsedScaled = 0;

    _countdownTicker = Timer.periodic(Duration(milliseconds: tickMs), (_) {
      elapsedScaled += tickMs;

      final int remainingScaledMs =
          (totalScaledMs - elapsedScaled).clamp(0, totalScaledMs);
      _countdownProgress = remainingScaledMs / totalScaledMs;

      final int remainingLogicalMs =
          (remainingScaledMs / totalScaledMs * totalLogicalMs).round();
      final int nextSeconds =
          (remainingLogicalMs / 1000.0).ceil().clamp(1, _countdownSeconds);

      if (nextSeconds != _countdownSeconds) {
        _countdownSeconds = nextSeconds;
      }

      _setHud(
        hud.value.copyWith(
          countdownSeconds: _countdownSeconds,
          countdownProgress: _countdownProgress,
        ),
      );

      // Abort if stream died or validations failed mid-countdown.
      final bool okNow =
          poseService.latestFrame.value != null && _stage == _FlowStage.done;
      if (poseService.latestFrame.value == null || !okNow) {
        _stopCountdown();
        return;
      }

      // Early fire: as soon as digits read "1", shoot immediately.
      if (!_firedAtOne && nextSeconds == 1) {
        final bool okToShoot =
            poseService.latestFrame.value != null && okNow;
        if (okToShoot) {
          isCapturing = true;
          notifyListeners();
          _firedAtOne = true;
          unawaited(_captureFromWebRtcTrack());
          _stopCountdown();
          return;
        }
      }

      // Countdown finished → capture, then stop. (Fallback if not fired at "1")
      if (!_firedAtOne && elapsedScaled >= totalScaledMs) {
        final bool okToShoot =
            poseService.latestFrame.value != null && okNow;

        if (okToShoot) {
          isCapturing = true;
          notifyListeners();
          unawaited(_captureFromWebRtcTrack());
        }

        _stopCountdown();
      }
    });
  }

  void _stopCountdown() {
    _countdownTicker?.cancel();
    _countdownTicker = null;

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
