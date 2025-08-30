// ==========================
// lib/features/posture/presentation/controllers/pose_capture_controller.dart
// ==========================
import 'dart:async';
import 'dart:typed_data' show Uint8List, ByteBuffer, ByteData;
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

// NEW: which overlay animation is currently active
enum _Axis { none, yaw, pitch, roll }

/// Treat empty/whitespace strings as null so the HUD won't render the secondary line.
String? _nullIfBlank(String? s) => (s == null || s.trim().isEmpty) ? null : s;

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
  static const double _rollDeadbandDeg = 179; // small tilt tolerance
  static const double _maxOffDeg = 20.0;

  // Keep current canvas size to map image↔canvas consistently.
  Size? _canvasSize;
  void setCanvasSize(Size s) => _canvasSize = s;

  // Countdown state
  Timer? _countdownTicker;
  double _countdownProgress = 1.0; // 1 → 0
  int _countdownSeconds = 3;
  bool get isCountingDown => _countdownTicker != null;

  // Validation state
  bool _lastAllChecksOk = false;

  // Require stability before starting countdown (debounce)
  DateTime? _readySince;
  static const _readyHold = Duration(milliseconds: 250);

  // Throttle HUD updates to ~15 Hz
  DateTime _lastHudPush = DateTime.fromMillisecondsSinceEpoch(0);
  static const _hudMinInterval = Duration(milliseconds: 66);

  // Snapshot state (exposed)
  Uint8List? capturedPng; // captured bytes (from WebRTC track or boundary fallback)
  bool isCapturing = false; // Capture-mode flag to hide preview/HUD instantly at T=0

  // Early-fire latch so we shoot as soon as digits hit '1'
  bool _firedAtOne = false;

  // Hint trigger & visibility for sequence
  static const _kTurnRightHint = 'Gira ligeramente la cabeza a la derecha';
  static const _kTurnLeftHint  = 'Gira ligeramente la cabeza a la izquierda';
  bool _turnRightSeqLoaded = false;
  bool _turnLeftSeqLoaded = false;
  bool showTurnRightSeq = false; // used as generic overlay visibility

  // Which direction’s frames are currently loaded (for yaw)
  _TurnDir _activeTurn = _TurnDir.none;

  // NEW: track which pitch direction is active (true = pitch > 0, false = pitch <= 0)
  bool? _activePitchUp;

  // NEW: track roll sign to avoid reloading every frame (true => rollDeg > 0)
  bool? _activeRollPositive;

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
    _lastAllChecksOk = false;
    notifyListeners();
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
        _lastAllChecksOk = false;
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
          _lastAllChecksOk = false;
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
      _lastAllChecksOk = false;

      if (showTurnRightSeq) {
        showTurnRightSeq = false;
        try { seq.pause(); } catch (_) {}
        notifyListeners();
      }
      return;
    }

    // Defaults when we can't evaluate.
    bool faceOk = false;
    bool yawOk = false;
    bool pitchOk = false;
    bool rollOk = false;
    bool allChecksOk = false;
    double arcProgress = 0.0;

    String? yawMsg;
    String? pitchMsg;
    String? rollMsg;

    // Keep values available outside the block for the animation chooser
    double? yawDegForAnim;
    double? pitchDegForAnim;
    double? rollDegForAnim;

    double? yawProgressForAnim;
    double? pitchProgressForAnim;
    double? rollProgressForAnim;

    final faces = poseService.latestFaceLandmarks;
    final canvas = _canvasSize;

    if (faces != null && faces.isNotEmpty && canvas != null) {
      final report = _validator.evaluate(
        landmarksImg: faces.first, // image-space points (px)
        imageSize: frame.imageSize, // from latestFrame
        canvasSize: canvas, // from LayoutBuilder
        mirror: mirror, // must match your preview overlay
        fit: BoxFit.cover, // must match your preview overlay
        minFractionInside: 1.0, // require ALL landmarks inside

        // Yaw thresholds
        enableYaw: true,
        yawDeadbandDeg: _yawDeadbandDeg,
        yawMaxOffDeg: _maxOffDeg,

        // Pitch thresholds
        enablePitch: true,
        pitchDeadbandDeg: _pitchDeadbandDeg,
        pitchMaxOffDeg: _maxOffDeg,

        // Roll thresholds (now enabled)
        enableRoll: true,
        rollDeadbandDeg: _rollDeadbandDeg,
        rollMaxOffDeg: _maxOffDeg,
      );

      faceOk = report.faceInOval;
      yawOk = report.yawOk;
      pitchOk = report.pitchOk;
      rollOk = report.rollOk;
      allChecksOk = report.allChecksOk;
      arcProgress = report.ovalProgress; // switches to head progress when faceOk

      yawDegForAnim = report.yawDeg;
      pitchDegForAnim = report.pitchDeg;
      rollDegForAnim = report.rollDeg;

      yawProgressForAnim = report.yawProgress;
      pitchProgressForAnim = report.pitchProgress;
      rollProgressForAnim = report.rollProgress;

      // Build per-axis hints
      if (faceOk && (!yawOk || !pitchOk || !rollOk)) {
        // Yaw hint (left/right)
        if (!yawOk) {
          yawMsg = report.yawDeg > 0
              ? 'Gira ligeramente la cabeza a la izquierda'
              : 'Gira ligeramente la cabeza a la derecha';
        }

        // Pitch hint (up/down)
        if (!pitchOk) {
          pitchMsg = report.pitchDeg > 0
              ? 'Sube ligeramente la cabeza'
              : 'Baja ligeramente la cabeza';
        }

        // Roll hint (clockwise/counterclockwise)
        if (!rollOk) {
          final deadband = _rollDeadbandDeg;
          final absRoll = report.rollDeg.abs();
          if (absRoll < deadband) {
            if (report.rollDeg > 0) {
              rollMsg = 'Rota ligeramente tu cabeza en sentido antihorario ⟲';
            } else {
              rollMsg = 'Rota ligeramente tu cabeza en sentido horario ⟳';
            }
          }
        }
      }
    }

    // Choose the worst (lowest progress) offender for the single secondary hint
    String? combinedHint;
    if (faceOk && (!yawOk || !pitchOk || !rollOk)) {
      final issues = <MapEntry<double, String>>[];
      if (!yawOk && yawMsg != null && yawProgressForAnim != null) {
        issues.add(MapEntry(yawProgressForAnim!, yawMsg));
      }
      if (!pitchOk && pitchMsg != null && pitchProgressForAnim != null) {
        issues.add(MapEntry(pitchProgressForAnim!, pitchMsg));
      }
      if (!rollOk && rollMsg != null && rollProgressForAnim != null) {
        issues.add(MapEntry(rollProgressForAnim!, rollMsg));
      }
      if (issues.isNotEmpty) {
        issues.sort((a, b) => a.key.compareTo(b.key)); // ascending → worst first
        combinedHint = issues.first.value;
      }
    }

    // Use the combined hint
    if (combinedHint != null) {
      yawMsg = combinedHint;
      pitchMsg = combinedHint;
      rollMsg = combinedHint;
    }

    // Decide the final hint that will actually be shown in the HUD:
    final String? finalHint = faceOk ? (yawMsg ?? pitchMsg ?? rollMsg) : null;

    // ───────────────────────────────────────────────────────────────────
    // Pick the worst (lowest progress) failing axis among yaw/pitch/roll.
    _Axis desiredAxis = _Axis.none;

    if (faceOk && (!yawOk || !pitchOk || !rollOk)) {
      final candidates = <MapEntry<double, _Axis>>[];

      if (!yawOk)   candidates.add(MapEntry(yawProgressForAnim   ?? 0.5, _Axis.yaw));
      if (!pitchOk) candidates.add(MapEntry(pitchProgressForAnim ?? 0.5, _Axis.pitch));
      if (!rollOk)  candidates.add(MapEntry(rollProgressForAnim  ?? 0.5, _Axis.roll));

      if (candidates.isNotEmpty) {
        candidates.sort((a, b) => a.key.compareTo(b.key)); // ascending → worst first
        desiredAxis = candidates.first.value;
      }
    }

    if (desiredAxis == _Axis.yaw && yawDegForAnim != null) {
      // YAW animation (original behavior, x:0..256)
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
      // ROLL animation (new), using the 3rd strip: x:512..768
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
      _activeRollPositive = null; // ← reset roll state too
    }
    // ───────────────────────────────────────────────────────────────────

    // Track stability window
    final now = DateTime.now();
    if (allChecksOk) {
      _readySince ??= now;
    } else {
      _readySince = null;
    }

    // If we were counting down and any validation failed, stop now
    if (isCountingDown && !allChecksOk) {
      _stopCountdown();
    }

    _lastAllChecksOk = allChecksOk;

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
            checkHead: faceOk ? ((yawOk && pitchOk && rollOk) ? Tri.ok : Tri.almost) : Tri.pending,
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

    // Start countdown only when rules pass *and* state has been stable
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
      if (poseService.latestFrame.value == null || !_lastAllChecksOk) {
        _stopCountdown();
        return;
      }

      // Early fire: as soon as digits read "1", shoot immediately.
      if (!_firedAtOne && nextSeconds == 1) {
        final bool okToShoot =
            poseService.latestFrame.value != null && _lastAllChecksOk;
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
            poseService.latestFrame.value != null && _lastAllChecksOk;

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
    _lastAllChecksOk = false;

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
