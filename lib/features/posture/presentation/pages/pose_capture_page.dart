// lib/features/posture/presentation/pages/pose_capture_page.dart
import 'dart:async';
import 'dart:ui' show Size; // for LayoutBuilder size
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../services/pose_webrtc_service.dart';
import '../widgets/rtc_pose_overlay.dart' show PoseOverlayFast;
import '../widgets/portrait_validator_hud.dart'
    show PortraitValidatorHUD, PortraitUiController, PortraitUiModel, Tri;

import '../../domain/validators/portrait_validations.dart'
    show PortraitValidator;

/// Treat empty/whitespace strings as null so the HUD won't render the secondary line.
String? _nullIfBlank(String? s) => (s == null || s.trim().isEmpty) ? null : s;

class PoseCapturePage extends StatefulWidget {
  const PoseCapturePage({
    super.key,
    required this.poseService,

    /// Total logical duration of the countdown when [countdownSpeed] == 1.0.
    this.countdownDuration = const Duration(seconds: 3),

    /// Visual smoothness of the ring updates (frames per second).
    this.countdownFps = 30,

    /// Speed multiplier: 1.0 = normal; 2.0 = twice as fast (finishes in half the time).
    this.countdownSpeed = 1.6,
  })  : assert(countdownFps > 0, 'countdownFps must be > 0'),
        assert(countdownSpeed > 0, 'countdownSpeed must be > 0');

  final PoseWebRTCService poseService;
  final Duration countdownDuration;
  final int countdownFps;
  final double countdownSpeed;

  @override
  State<PoseCapturePage> createState() => _PoseCapturePageState();
}

class _PoseCapturePageState extends State<PoseCapturePage> {
  final bool _mirror = true; // front camera UX
  late final PortraitUiController _hud;

  // Centralized validator for all portrait rules (oval + yaw etc.).
  final PortraitValidator _validator = const PortraitValidator();

  // Keep current canvas size to map image↔canvas consistently.
  Size? _canvasSize;

  // Countdown state
  Timer? _countdownTicker;
  double _countdownProgress = 1.0; // 1 → 0
  int _countdownSeconds = 3;

  // Validation state
  bool _lastAllChecksOk = false;

  // Require stability before starting countdown (debounce)
  DateTime? _readySince;
  static const _readyHold = Duration(milliseconds: 250);

  // Throttle HUD updates to ~15 Hz
  DateTime _lastHudPush = DateTime.fromMillisecondsSinceEpoch(0);
  static const _hudMinInterval = Duration(milliseconds: 66);

  void _setHud(PortraitUiModel next, {bool force = false}) {
    final now = DateTime.now();
    if (!force && now.difference(_lastHudPush) < _hudMinInterval) return;

    final cur = _hud.value;
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
      _hud.value = next;
      _lastHudPush = now;
    }
  }

  @override
  void initState() {
    super.initState();
    _hud = PortraitUiController(
      const PortraitUiModel(
        statusLabel: 'Adjusting',
        privacyLabel: 'On-device',
        primaryMessage: 'Ubica tu rostro dentro del óvalo',
        // secondaryMessage intentionally omitted (null)
        ovalProgress: 0.0, // start at 0%
      ),
    );

    // Listen to frames and drive a minimal readiness model.
    widget.poseService.latestFrame.addListener(_onFrame);
  }

  @override
  void dispose() {
    widget.poseService.latestFrame.removeListener(_onFrame);
    _stopCountdown();
    _hud.dispose();
    super.dispose();
  }

  // ─────────────────────────────────────────────────────────────────────

  void _onFrame() {
    final frame = widget.poseService.latestFrame.value;

    if (frame == null) {
      // Lost face → abort countdown and reset.
      _stopCountdown();
      final cur = _hud.value;
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
      return;
    }

    // Defaults when we can't evaluate.
    bool faceOk = false;
    bool yawOk = false;
    bool allChecksOk = false;
    double arcProgress = 0.0;
    String? yawMsg;

    final faces = widget.poseService.latestFaceLandmarks;
    final canvas = _canvasSize;

    if (faces != null && faces.isNotEmpty && canvas != null) {
      final report = _validator.evaluate(
        landmarksImg: faces.first,     // image-space points (px)
        imageSize: frame.imageSize,    // from latestFrame
        canvasSize: canvas,            // from LayoutBuilder
        mirror: _mirror,               // must match your preview overlay
        fit: BoxFit.cover,             // must match your preview overlay
        minFractionInside: 1.0,        // require ALL landmarks inside
        // (optional) tweak yaw thresholds here:
        yawDeadbandDeg: 2.2,
        yawMaxOffDeg: 20.0,
      );

      faceOk = report.faceInOval;
      yawOk = report.yawOk;
      allChecksOk = report.allChecksOk;
      arcProgress = report.ovalProgress; // already switches to yawProgress when faceOk

      // Build the hint only in UI layer using the sign of yawDeg
      if (faceOk && !yawOk) {
        yawMsg = report.yawDeg > 0
            ? 'Gira ligeramente la cabeza a la derecha'
            : 'Gira ligeramente la cabeza a la izquierda';
      }
    }

    // Track stability window
    final now = DateTime.now();
    if (allChecksOk) {
      _readySince ??= now;
    } else {
      _readySince = null;
    }

    // If we were counting down and any validation failed, stop now
    if (_isCountingDown && !allChecksOk) {
      _stopCountdown();
    }

    _lastAllChecksOk = allChecksOk;

    // Update HUD (no countdown UI changes here)
    if (!_isCountingDown) {
      final cur = _hud.value;
      if (allChecksOk) {
        // Clear secondary & countdown while "Ready"; _startCountdown() will set them.
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
            countdownSeconds: null,      // ensure no stale ring shows
            countdownProgress: null,     // ensure no stale ring shows
            ovalProgress: arcProgress,
          ),
        );
      } else {
        // Build a fresh model so countdown fields are truly null and hints update.
        _setHud(
          PortraitUiModel(
            statusLabel: 'Adjusting',
            privacyLabel: cur.privacyLabel,
            primaryMessage:
                faceOk ? 'Mantén la cabeza recta' : 'Ubica tu rostro dentro del óvalo',
            secondaryMessage: _nullIfBlank(faceOk ? yawMsg : ''),
            checkFraming: faceOk ? Tri.ok : Tri.almost,
            checkHead: faceOk ? (yawOk ? Tri.ok : Tri.almost) : Tri.pending,
            checkEyes: Tri.almost,
            checkLighting: Tri.almost,
            checkBackground: Tri.almost,
            countdownSeconds: null,    // hard-clear to avoid race with throttle
            countdownProgress: null,   // hard-clear to avoid race with throttle
            ovalProgress: arcProgress,
          ),
        );
      }
    }

    // Start countdown only when rules pass *and* state has been stable
    if (!_isCountingDown &&
        allChecksOk &&
        _readySince != null &&
        now.difference(_readySince!) >= _readyHold) {
      _startCountdown();
    }
  }

  bool get _isCountingDown => _countdownTicker != null;

  void _startCountdown() {
    _stopCountdown();
    _countdownProgress = 1.0;

    final int totalLogicalMs = widget.countdownDuration.inMilliseconds;
    int totalScaledMs =
        (totalLogicalMs / widget.countdownSpeed).round().clamp(1, 24 * 60 * 60 * 1000);

    // Start digits from the logical (unscaled) duration → 3
    _countdownSeconds = (totalLogicalMs / 1000.0).ceil();

    _setHud(_hud.value.copyWith(
      countdownSeconds: _countdownSeconds,
      countdownProgress: _countdownProgress,
    ), force: true);

    int tickMs = (1000 / widget.countdownFps).round().clamp(10, 1000);
    int elapsedScaled = 0;

    _countdownTicker = Timer.periodic(Duration(milliseconds: tickMs), (_) {
      elapsedScaled += tickMs;

      final remainingScaledMs = (totalScaledMs - elapsedScaled).clamp(0, totalScaledMs);
      _countdownProgress = remainingScaledMs / totalScaledMs;

      // Map scaled time → logical seconds (keeps 3→2→1 regardless of speed)
      final remainingLogicalMs =
          (remainingScaledMs / totalScaledMs * totalLogicalMs).round();
      final nextSeconds = (remainingLogicalMs / 1000.0).ceil().clamp(1, _countdownSeconds);

      if (nextSeconds != _countdownSeconds) {
        _countdownSeconds = nextSeconds;
      }

      _setHud(_hud.value.copyWith(
        countdownSeconds: _countdownSeconds,
        countdownProgress: _countdownProgress,
      ));

      if (widget.poseService.latestFrame.value == null || !_lastAllChecksOk) {
        _stopCountdown();
        return;
      }
      if (elapsedScaled >= totalScaledMs) {
        _stopCountdown();
      }
    });
  }

  void _stopCountdown() {
    _countdownTicker?.cancel();
    _countdownTicker = null;

    final cur = _hud.value;
    // Build a fresh model so countdown fields become truly null; push immediately.
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
        countdownSeconds: null,     // cleared for real
        countdownProgress: null,    // cleared for real
        ovalProgress: cur.ovalProgress,
      ),
      force: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final svc = widget.poseService;

    return LayoutBuilder( // get the actual canvas size
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        _canvasSize = size; // keep current canvas size for mapping

        return Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            children: [
              // 1) Full-screen local preview
              Positioned.fill(
                child: RTCVideoView(
                  svc.localRenderer,
                  mirror: _mirror,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                ),
              ),

              // 2) Low-latency landmarks overlay (your existing widget)
              Positioned.fill(
                child: IgnorePointer(
                  child: PoseOverlayFast(
                    latest: svc.latestFrame,
                    mirror: _mirror,
                    fit: BoxFit.cover,
                  ),
                ),
              ),

              // 3) Portrait HUD (face oval, checklist, guidance, countdown)
              Positioned.fill(
                child: IgnorePointer(
                  child: PortraitValidatorHUD(
                    modelListenable: _hud,
                    mirror: _mirror,
                    fit: BoxFit.cover,
                    showSafeBox: false, // hides the square around the oval
                  ),
                ),
              ),

              // 4) Optional remote PiP
              Positioned(
                left: 12,
                top: 12,
                width: 144,
                height: 192,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: RTCVideoView(
                    svc.remoteRenderer,
                    mirror: _mirror, // consider false if remote is not mirrored
                    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
