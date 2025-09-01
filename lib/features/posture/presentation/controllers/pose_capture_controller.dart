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

/// Private direction enum must be top-level (not inside a class).
enum _TurnDir { none, left, right }

// Which overlay animation is currently active
enum _Axis { none, yaw, pitch, roll }

/// Sequential flow: enforce yaw → pitch → roll
enum _FlowStage { yaw, pitch, roll, done }

/// Treat empty/whitespace strings as null so the HUD won't render the secondary line.
String? _nullIfBlank(String? s) => (s == null || s.trim().isEmpty) ? null : s;

/// ─────────────────────────────────────────────────────────────────────────
/// Axis stability gate with dwell + hysteresis + first-pass tightening.
/// Implements Proposal 1 (+ touch of Proposal 2).
enum _GateState { searching, dwell, confirmed }

/// How to interpret the threshold comparison.
/// - insideIsOk: value <= threshold passes (yaw/pitch).
/// - outsideIsOk: value >= threshold passes (roll near 180°).
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

  final double baseDeadband;       // e.g., 2.2°
  final _GateSense sense;
  final double tighten;            // e.g., 0.2° → first pass stricter
  final double hysteresis;         // inside: exit = enter + hys, outside: exit = enter - hys
  final Duration dwell;            // e.g., 500 ms
  final double extraRelaxAfterFirst; // extra room after first confirm while confirmed

  bool hasConfirmedOnce = false;
  bool _tightenUntilSatisfied = false; // after break during dwell → instant confirm on next entry
  _GateState _state = _GateState.searching;
  DateTime? _dwellStart;

  // NEW: expose state for UI decisions (e.g., suppressing hints during dwell)
  bool get isSearching => _state == _GateState.searching;
  bool get isDwell     => _state == _GateState.dwell;
  bool get isConfirmed => _state == _GateState.confirmed;

  void resetTransient() {
    // Keep hasConfirmedOnce (UX-friendly), reset current attempt.
    _state = _GateState.searching;
    _dwellStart = null;
    _tightenUntilSatisfied = false;
  }

  // UPDATED: tighten subtracts for insideIsOk (yaw/pitch) and ADDS for outsideIsOk (roll)
  double get enterBand {
    final strict = !hasConfirmedOnce || _tightenUntilSatisfied;
    if (!strict) return baseDeadband;
    return (sense == _GateSense.insideIsOk)
        ? (baseDeadband - tighten)   // yaw/pitch → smaller threshold
        : (baseDeadband + tighten);  // roll → larger threshold (closer to 180°), stricter
  }

  double get exitBand {
    final e = enterBand;
    return (sense == _GateSense.insideIsOk) ? (e + hysteresis) : (e - hysteresis);
  }

  bool _isOk(double v, double th) =>
      (sense == _GateSense.insideIsOk) ? (v <= th) : (v >= th);

  double _withRelax(double th, double relax) =>
      (sense == _GateSense.insideIsOk) ? (th + relax) : (th - relax);

  /// Update with absolute degrees and current time.
  /// Returns whether the axis is considered "OK" after applying gate logic.
  bool update(double absDeg, DateTime now) {
    switch (_state) {
      case _GateState.searching:
        if (_isOk(absDeg, enterBand)) {
          if (_tightenUntilSatisfied) {
            // If we already tightened due to a break during dwell,
            // confirm immediately without waiting another 500 ms.
            _state = _GateState.confirmed;
            hasConfirmedOnce = true;
            _tightenUntilSatisfied = false;
            return true;
          } else {
            _dwellStart = now;
            _state = _GateState.dwell;
          }
        }
        return false;

      case _GateState.dwell:
        if (!_isOk(absDeg, exitBand)) {
          // Broke during dwell → tighten requirement next time, restart.
          _state = _GateState.searching;
          _dwellStart = null;
          _tightenUntilSatisfied = true;
          return false;
        }
        if (now.difference(_dwellStart!) >= dwell) {
          _state = _GateState.confirmed;
          hasConfirmedOnce = true;
          _tightenUntilSatisfied = false;
          return true;
        }
        return false;

      case _GateState.confirmed:
        final double relax = hasConfirmedOnce ? extraRelaxAfterFirst : 0.0;
        final double exitWithRelax = _withRelax(exitBand, relax);
        if (!_isOk(absDeg, exitWithRelax)) {
          _state = _GateState.searching;
          _dwellStart = null;
          return false;
        }
        return true;
    }
  }
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

  // Centralized validator for all portrait rules (oval + yaw/pitch/roll).
  final PortraitValidator _validator = const PortraitValidator();

  // Angle thresholds (deg)
  static const double _yawDeadbandDeg = 2.2;
  static const double _pitchDeadbandDeg = 2.2;
  static const double _rollDeadbandDeg = 178.4;
  static const double _maxOffDeg = 20.0;

  // Axis gates (Proposal 1 + small 2)
  final _AxisGate _yawGate = _AxisGate(
    baseDeadband: _yawDeadbandDeg,
    tighten: 0.6,
    hysteresis: 0.2,
    dwell: Duration(milliseconds: 1900),
    extraRelaxAfterFirst: 0.2,
  );
  final _AxisGate _pitchGate = _AxisGate(
    baseDeadband: _pitchDeadbandDeg,
    tighten: 0.6,
    hysteresis: 0.2,
    dwell: Duration(milliseconds: 1900),
    extraRelaxAfterFirst: 0.2,
  );
  // Roll uses the inverted sense so that larger thresholds are stricter (closer to 180°).
  final _AxisGate _rollGate = _AxisGate(
    baseDeadband: _rollDeadbandDeg,
    sense: _GateSense.outsideIsOk,
    tighten: 0.1,
    hysteresis: 0.2,
    dwell: Duration(milliseconds: 1900),
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

  // EMA smoothing for angles
  static const double _emaTauMs = 250.0;
  DateTime? _lastSampleAt;
  double? _emaYawDeg;
  double? _emaPitchDeg;
  double? _emaRollDeg;

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

  // Reset sequential flow (use when face lost or to restart the process)
  void _resetFlow() {
    _stage = _FlowStage.yaw;

    _yawGate.resetTransient();
    _pitchGate.resetTransient();
    _rollGate.resetTransient();

    // Start from scratch (optional but recommended for strict sequencing)
    _yawGate.hasConfirmedOnce = false;
    _pitchGate.hasConfirmedOnce = false;
    _rollGate.hasConfirmedOnce = false;
  }

  // Helper: does a confirmed axis still hold its stability?
  bool _isHolding(_AxisGate g, double absDeg) {
    final exit = g.exitBand;
    final relax = g.hasConfirmedOnce ? g.extraRelaxAfterFirst : 0.0;
    final bool inside = g.sense == _GateSense.insideIsOk;
    // inside: ok si ≤ exit+relax; outside (roll): ok si ≥ exit-relax
    return inside ? (absDeg <= exit + relax) : (absDeg >= exit - relax);
  }

  // ─────────────────────────────────────────────────────────────────────
  Future<void> _captureFromWebRtcTrack() async {
    try {
      MediaStream? stream =
          poseService.localRenderer.srcObject ?? poseService.localStream;
      if (stream == null || stream.getVideoTracks().isEmpty) {
        throw StateError('No local WebRTC video track available');
      }

      final track = stream.getVideoTracks().first;
      final dynamic dynTrack = track;

      final Object data = await dynTrack.captureFrame(); // may be Uint8List / ByteBuffer / ByteData
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

  void _setHud(PortraitUiModel next, {bool force = false}) {
    final now = DateTime.now();
    if (!force && now.difference(_lastHudPush) < _hudMinInterval) return;

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

  void _onFrame() {
    // While capturing OR while a photo is displayed, ignore frame/HUD updates.
    if (isCapturing || capturedPng != null) return;

    final frame = poseService.latestFrame.value;

    if (frame == null) {
      // Lost face → abort countdown and reset.
      _stopCountdown();
      final cur = hud.value;
      _setHud(
        PortraitUiModel(
          statusLabel: 'Searching',
          privacyLabel: cur.privacyLabel,
          primaryMessage: 'Show your face in the oval',
          secondaryMessage: null,
          checkFraming: Tri.pending,
          checkHead: Tri.pending,
          checkEyes: Tri.pending,
          checkLighting: Tri.pending,
          checkBackground: Tri.pending,
          countdownSeconds: null,
          countdownProgress: null,
          ovalProgress: 0.0,
        ),
      );
      _readySince = null;

      if (showTurnRightSeq) {
        showTurnRightSeq = false;
        try { seq.pause(); } catch (_) {}
        notifyListeners();
      }

      // Reset sequential flow + filters when face disappears.
      _resetFlow();
      _emaYawDeg = _emaPitchDeg = _emaRollDeg = null;
      _lastSampleAt = null;
      return;
    }

    // Defaults when we can't evaluate.
    bool faceOk = false;
    bool yawOk = false;
    bool pitchOk = false;
    bool rollOk = false;
    double arcProgress = 0.0;

    // Keep values available outside the block for the animation chooser
    double? yawDegForAnim;
    double? pitchDegForAnim;
    double? rollDegForAnim;

    final faces = poseService.latestFaceLandmarks;
    final canvas = _canvasSize;

    // Use current enter-bands so progress bars match what we are enforcing
    final double _yawDeadbandNow = _yawGate.enterBand;
    final double _pitchDeadbandNow = _pitchGate.enterBand;
    final double _rollDeadbandNow = _rollGate.enterBand;

    if (faces != null && faces.isNotEmpty && canvas != null) {
      final report = _validator.evaluate(
        landmarksImg: faces.first, // image-space points (px)
        imageSize: frame.imageSize, // from latestFrame
        canvasSize: canvas, // from LayoutBuilder
        mirror: mirror, // must match your preview overlay
        fit: BoxFit.cover, // must match your preview overlay
        minFractionInside: 1.0, // require ALL landmarks inside

        // Yaw thresholds (dynamic for progress only)
        enableYaw: true,
        yawDeadbandDeg: _yawDeadbandNow,
        yawMaxOffDeg: _maxOffDeg,

        // Pitch thresholds (dynamic for progress only)
        enablePitch: true,
        pitchDeadbandDeg: _pitchDeadbandNow,
        pitchMaxOffDeg: _maxOffDeg,

        // Roll thresholds (permissive)
        enableRoll: true,
        rollDeadbandDeg: _rollDeadbandNow,
        rollMaxOffDeg: _maxOffDeg,
      );

      faceOk = report.faceInOval;
      arcProgress = report.ovalProgress; // switches to head progress when faceOk

      // Smooth angles with EMA
      final now = DateTime.now();
      final dtMs = (() {
        if (_lastSampleAt == null) return 16.0;
        return now.difference(_lastSampleAt!).inMilliseconds.toDouble().clamp(1.0, 1000.0);
      })();
      final a = 1 - math.exp(-dtMs / _emaTauMs);
      _lastSampleAt ??= now;

      _emaYawDeg = (_emaYawDeg == null)
          ? report.yawDeg
          : (a * report.yawDeg + (1 - a) * _emaYawDeg!);
      _emaPitchDeg = (_emaPitchDeg == null)
          ? report.pitchDeg
          : (a * report.pitchDeg + (1 - a) * _emaPitchDeg!);
      _emaRollDeg = (_emaRollDeg == null)
          ? report.rollDeg
          : (a * report.rollDeg + (1 - a) * _emaRollDeg!);

      _lastSampleAt = now;

      // Use filtered values for gating + animations/messages
      final double yawAbs = _emaYawDeg!.abs();
      final double pitchAbs = _emaPitchDeg!.abs();
      final double rollAbs = _emaRollDeg!.abs();

      // ── Retroceso de etapas si una validación previa deja de sostenerse
      if (_stage == _FlowStage.pitch) {
        if (!_isHolding(_yawGate, yawAbs)) {
          _stage = _FlowStage.yaw;
          _yawGate.resetTransient();
          _yawGate.hasConfirmedOnce = false; // obliga a repetir dwell de 2000 ms
        }
      } else if (_stage == _FlowStage.roll) {
        if (!_isHolding(_yawGate, yawAbs)) {
          _stage = _FlowStage.yaw;
          _yawGate.resetTransient();
          _yawGate.hasConfirmedOnce = false;
          // opcional: también “olvida” pitch para ser estrictos:
          _pitchGate.resetTransient();
          _pitchGate.hasConfirmedOnce = false;
        } else if (!_isHolding(_pitchGate, pitchAbs)) {
          _stage = _FlowStage.pitch;
          _pitchGate.resetTransient();
          _pitchGate.hasConfirmedOnce = false;
        }
      } else if (_stage == _FlowStage.done) {
        // En "done" degrada al primer eje que se rompa (prioridad yaw → pitch → roll)
        if (!_isHolding(_yawGate, yawAbs)) {
          _stage = _FlowStage.yaw;
          _yawGate.resetTransient();
          _yawGate.hasConfirmedOnce = false;
          _pitchGate.resetTransient();
          _pitchGate.hasConfirmedOnce = false;
          _rollGate.resetTransient();
          _rollGate.hasConfirmedOnce = false;
        } else if (!_isHolding(_pitchGate, pitchAbs)) {
          _stage = _FlowStage.pitch;
          _pitchGate.resetTransient();
          _pitchGate.hasConfirmedOnce = false;
          _rollGate.resetTransient();
          _rollGate.hasConfirmedOnce = false;
        } else if (!_isHolding(_rollGate, rollAbs)) {
          _stage = _FlowStage.roll;
          _rollGate.resetTransient();
          _rollGate.hasConfirmedOnce = false;
        }
      }

      // Sequential gating:
      // axes already confirmed remain OK; only current stage axis is updated.
      yawOk   = _yawGate.hasConfirmedOnce;
      pitchOk = _pitchGate.hasConfirmedOnce;
      rollOk  = _rollGate.hasConfirmedOnce;

      switch (_stage) {
        case _FlowStage.yaw:
          yawOk = faceOk && _yawGate.update(yawAbs, now);
          if (yawOk) {
            _stage = _FlowStage.pitch;
            _pitchGate.resetTransient();
          }
          break;

        case _FlowStage.pitch:
          pitchOk = faceOk && _pitchGate.update(pitchAbs, now);
          if (pitchOk) {
            _stage = _FlowStage.roll;
            _rollGate.resetTransient();
          }
          break;

        case _FlowStage.roll:
          rollOk = faceOk && _rollGate.update(rollAbs, now);
          if (rollOk) {
            _stage = _FlowStage.done;
          }
          break;

        case _FlowStage.done:
          // keep state; already handled degradation above if needed
          break;
      }

      // Provide values to animation chooser
      yawDegForAnim = _emaYawDeg;
      pitchDegForAnim = _emaPitchDeg;
      rollDegForAnim = _emaRollDeg;
    }

    // Decide which axis to animate/hint: only the current stage if not OK.
    // NEW: suppress hint + animation while the current axis is in dwell.
    _Axis desiredAxis = _Axis.none;
    String? finalHint;

    if (faceOk) {
      if (_stage == _FlowStage.yaw && !yawOk && yawDegForAnim != null && !_yawGate.isDwell) {
        desiredAxis = _Axis.yaw;
        finalHint = (_emaYawDeg! > 0)
            ? 'Gira ligeramente la cabeza a la izquierda'
            : 'Gira ligeramente la cabeza a la derecha';
      } else if (_stage == _FlowStage.pitch && !pitchOk && pitchDegForAnim != null && !_pitchGate.isDwell) {
        desiredAxis = _Axis.pitch;
        finalHint = (_emaPitchDeg! > 0)
            ? 'Sube ligeramente la cabeza'
            : 'Baja ligeramente la cabeza';
      } else if (_stage == _FlowStage.roll && !rollOk && rollDegForAnim != null && !_rollGate.isDwell) {
        desiredAxis = _Axis.roll;
        finalHint = (_emaRollDeg! > 0)
            ? 'Rota ligeramente tu cabeza en sentido antihorario ⟲'
            : 'Rota ligeramente tu cabeza en sentido horario ⟳';
      }
    }

    // ───────────────────────────────────────────────────────────────────
    // Axis-specific animation loaders (unchanged behavior, per strip)
    if (desiredAxis == _Axis.yaw && yawDegForAnim != null) {
      // YAW animation (x:0..256)
      _TurnDir desiredTurn =
          (yawDegForAnim! > 0) ? _TurnDir.left : _TurnDir.right; // + → left, - → right

      // reset pitch/roll state so we can reload it next time if needed
      _activePitchUp = null;
      _activeRollPositive = null;

      if (desiredTurn != _activeTurn) {
        _activeTurn = desiredTurn;
        if (desiredTurn == _TurnDir.right) {
          _turnRightSeqLoaded = true;
          // ignore: discarded_futures
          seq.loadFromAssets(
            directory: 'assets/frames',
            pattern: 'frame_%04d.png',
            startNumber: 14,
            count: 22,
            xStart: 0,
            xEnd: 256,
          );
        } else {
          _turnLeftSeqLoaded = true;
          // ignore: discarded_futures
          seq.loadFromAssets(
            directory: 'assets/frames',
            pattern: 'frame_%04d.png',
            startNumber: 30,
            count: 21,
            xStart: 0,
            xEnd: 256,
            reverseOrder: true,
          );
        }
      }

      if (!showTurnRightSeq) {
        showTurnRightSeq = true;
        notifyListeners();
      }
      try { seq.play(); } catch (_) {}

    } else if (desiredAxis == _Axis.pitch && pitchDegForAnim != null) {
      // PITCH animation (x:256..512)
      final bool desiredPitchUp = pitchDegForAnim! > 0; // true = head up

      // reset yaw/roll state so we can reload it next time if needed
      _activeTurn = _TurnDir.none;
      _activeRollPositive = null;

      if (_activePitchUp != desiredPitchUp) {
        _activePitchUp = desiredPitchUp;

        if (desiredPitchUp) {
          // Head up (pitch > 0)
          // ignore: discarded_futures
          seq.loadFromAssets(
            directory: 'assets/frames',
            pattern: 'frame_%04d.png',
            startNumber: 30,
            count: 21,
            xStart: 256,
            xEnd: 512,
            reverseOrder: true,
          );
        } else {
          // Head down (pitch <= 0)
          // ignore: discarded_futures
          seq.loadFromAssets(
            directory: 'assets/frames',
            pattern: 'frame_%04d.png',
            startNumber: 14,
            count: 22,
            xStart: 256,
            xEnd: 512,
          );
        }
      }

      if (!showTurnRightSeq) {
        showTurnRightSeq = true; // reuse same visibility flag
        notifyListeners();
      }
      try { seq.play(); } catch (_) {}

    } else if (desiredAxis == _Axis.roll && rollDegForAnim != null) {
      // ROLL animation (x:512..768)
      final bool desiredRollPositive = rollDegForAnim! > 0; // true = CCW (antihorario)

      // Reset other axis states so they reload next time if chosen
      _activeTurn = _TurnDir.none;   // yaw
      _activePitchUp = null;         // pitch

      if (_activeRollPositive != desiredRollPositive) {
        _activeRollPositive = desiredRollPositive;

        if (desiredRollPositive) {
          // rollDeg > 0  → use (start 14, count 22), forward
          // ignore: discarded_futures
          seq.loadFromAssets(
            directory: 'assets/frames',
            pattern: 'frame_%04d.png',
            startNumber: 14,
            count: 22,
            xStart: 512,
            xEnd: 768,
          );
        } else {
          // rollDeg <= 0 → use (start 30, count 21), reverse
          // ignore: discarded_futures
          seq.loadFromAssets(
            directory: 'assets/frames',
            pattern: 'frame_%04d.png',
            startNumber: 30,
            count: 21,
            xStart: 512,
            xEnd: 768,
            reverseOrder: true,
          );
        }
      }

      if (!showTurnRightSeq) {
        showTurnRightSeq = true; // reuse the same visibility flag
        notifyListeners();
      }
      try { seq.play(); } catch (_) {}

    } else {
      // No axis selected → hide/pause overlay
      if (showTurnRightSeq) {
        try { seq.pause(); } catch (_) {}
        showTurnRightSeq = false;
        notifyListeners();
      }
      _activeTurn = _TurnDir.none;
      _activePitchUp = null;
      _activeRollPositive = null;
    }
    // ───────────────────────────────────────────────────────────────────

    // Track stability window (global) – already enforced by gates, keep zero hold
    final now = DateTime.now();
    final bool allChecksOk = faceOk && _stage == _FlowStage.done;

    if (allChecksOk) {
      _readySince ??= now;
    } else {
      _readySince = null;
    }

    // If we were counting down and any validation failed, stop now
    if (isCountingDown && !allChecksOk) {
      _stopCountdown();
    }

    // Update HUD (no countdown UI changes here)
    if (!isCountingDown) {
      final cur = hud.value;
      if (allChecksOk) {
        _setHud(
          PortraitUiModel(
            statusLabel: 'Ready',
            privacyLabel: cur.privacyLabel,
            primaryMessage: '¡Perfecto! ¡Permanece así!',
            secondaryMessage: null,
            checkFraming: Tri.ok,
            checkHead: Tri.ok,
            checkEyes: cur.checkEyes ?? Tri.almost,
            checkLighting: cur.checkLighting ?? Tri.almost,
            checkBackground: cur.checkBackground ?? Tri.almost,
            countdownSeconds: null,
            countdownProgress: null,
            ovalProgress: arcProgress,
          ),
        );
      } else {
        _setHud(
          PortraitUiModel(
            statusLabel: 'Adjusting',
            privacyLabel: cur.privacyLabel,
            primaryMessage:
                faceOk ? 'Mantén la cabeza recta' : 'Ubica tu rostro dentro del óvalo',
            secondaryMessage: _nullIfBlank(faceOk ? (finalHint ?? '') : ''),
            checkFraming: faceOk ? Tri.ok : Tri.almost,
            checkHead: faceOk ? (_stage == _FlowStage.done ? Tri.ok : Tri.almost) : Tri.pending,
            checkEyes: Tri.almost,
            checkLighting: Tri.almost,
            checkBackground: Tri.almost,
            countdownSeconds: null,
            countdownProgress: null,
            ovalProgress: arcProgress,
          ),
        );
      }
    }

    // Start countdown only when sequential rules are done *and* state has been stable
    if (!isCountingDown &&
        allChecksOk &&
        _readySince != null &&
        now.difference(_readySince!) >= _readyHold) {
      _startCountdown();
    }
  }

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

      final int remainingScaledMs = (totalScaledMs - elapsedScaled).clamp(0, totalScaledMs);
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
          poseService.latestFrame.value != null &&
          _stage == _FlowStage.done;
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
