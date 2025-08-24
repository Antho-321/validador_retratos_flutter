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
import '../../domain/validators/yaw_pitch_roll.dart'
  show yawPitchRollFromFaceMesh;

/// Treat empty/whitespace strings as null so the HUD won't render the secondary line.
String? _nullIfBlank(String? s) => (s == null || s.trim().isEmpty) ? null : s;

class PoseCapturePage extends StatefulWidget {
  const PoseCapturePage({super.key, required this.poseService});
  final PoseWebRTCService poseService;

  @override
  State<PoseCapturePage> createState() => _PoseCapturePageState();
}

class _PoseCapturePageState extends State<PoseCapturePage> {
  final bool _mirror = true; // front camera UX
  late final PortraitUiController _hud;

  // Centralized validator for all portrait rules (starts with face-in-oval).
  final PortraitValidator _validator = const PortraitValidator();

  // Keep current canvas size to map image↔canvas consistently.
  Size? _canvasSize;

  // Countdown state
  Timer? _countdownTicker;
  double _countdownProgress = 1.0; // 1 → 0
  int _countdownSeconds = 3;

  // Add this field:
  bool _lastAllChecksOk = false;

  // Throttle HUD updates to ~15 Hz
  DateTime _lastHudPush = DateTime.fromMillisecondsSinceEpoch(0);
  static const _hudMinInterval = Duration(milliseconds: 66);

  void _setHud(PortraitUiModel next) {
    final now = DateTime.now();
    if (now.difference(_lastHudPush) < _hudMinInterval) return;

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
        cur.ovalProgress == next.ovalProgress; // ← include progress equality

    if (!same) {
      _hud.value = next;
      _lastHudPush = now;
    }
  }

  @override
  void initState() {
    super.initState();
    _hud = PortraitUiController(
      PortraitUiModel(
        statusLabel: 'Adjusting',
        privacyLabel: 'On-device',
        primaryMessage: 'Ubica tu rostro dentro del óvalo',
        secondaryMessage: _nullIfBlank(''),
        ovalProgress: 0.0, // ← start at 0%
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
      _setHud(_hud.value.copyWith(
        statusLabel: 'Searching',
        primaryMessage: 'Show your face in the oval',
        secondaryMessage: _nullIfBlank(null), // stays null
        checkFraming: Tri.pending,
        checkHead: Tri.pending,
        checkEyes: Tri.pending,
        checkLighting: Tri.pending,
        checkBackground: Tri.pending,
        countdownSeconds: null,
        countdownProgress: null,
        ovalProgress: 0.0, // ← reset green arc
      ));
      _lastAllChecksOk = false;
      return;
    }

    // Evaluate face-in-oval using the centralized validator.
    bool landmarksWithinFaceOval = false;
    double ovalProgress = 0.0;

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
      );
      landmarksWithinFaceOval = report.faceInOval;
      ovalProgress = report.ovalProgress; // smooth 0..1 for the HUD arc
    }

    // If face not found we already returned above.

    // 1) First rule: face inside oval (you already computed these)
    final faceOk = landmarksWithinFaceOval;
    double arcProgress = ovalProgress; // default to rule 1 progress

    // 2) Second rule: yaw in [-1.9°, +1.9°] — only evaluated if faceOk
    bool yawOk = false;
    double yawProgress = 0.0;
    String? yawMsg;

    if (faceOk) {
      // Compute yaw (degrees) from face landmarks (image-space)
      final imgW = frame.imageSize.width.toInt();
      final imgH = frame.imageSize.height.toInt();

      final ypr = yawPitchRollFromFaceMesh(faces!.first, imgH, imgW);
      double yawDeg = ypr.yaw;

      // If your preview is mirrored (front camera UX), flip sign for intuitive guidance
      if (_mirror) yawDeg = -yawDeg;

      // Pass condition: -1.9 <= yaw <= +1.9
      const double deadband = 1.9;  // “OK” cone
      const double maxOff   = 20.0; // where progress bottoms out

      if (yawDeg > deadband) {
        yawMsg = 'Gira la cabeza a la derecha';
      } else if (yawDeg < -deadband) {
        yawMsg = 'Gira la cabeza a la izquierda';
      } else {
        yawOk = true;
      }

      // Progress toward centered yaw: |yaw| ∈ [deadband, maxOff] → progress ∈ [1..0]
      final off = (yawDeg.abs() - deadband).clamp(0.0, maxOff);
      yawProgress = (1.0 - (off / maxOff)).clamp(0.0, 1.0);

      // While we’re in rule 2, drive the green arc with yawProgress (same visual as rule 1)
      arcProgress = yawProgress;
    }

    // Gate “all checks” by both rules
    final allChecksOk = faceOk && yawOk;
    _lastAllChecksOk = allChecksOk;

    // Update HUD (no countdown UI changes here)
    if (!_isCountingDown) {
      if (allChecksOk) {
        // ⚠️ Force-clear the secondary line by creating a new model
        final cur = _hud.value;
        _setHud(PortraitUiModel(
          statusLabel: 'Ready',
          privacyLabel: cur.privacyLabel,
          primaryMessage: '¡Perfecto! ¡Permanece así!',
          secondaryMessage: null, // ← cleared for real
          checkFraming: Tri.ok,
          checkHead: Tri.ok,
          checkEyes: cur.checkEyes ?? Tri.almost,
          checkLighting: cur.checkLighting ?? Tri.almost,
          checkBackground: cur.checkBackground ?? Tri.almost,
          countdownSeconds: cur.countdownSeconds,
          countdownProgress: cur.countdownProgress,
          ovalProgress: arcProgress,
        ));
      } else {
        // Normal path keeps using copyWith
        _setHud(_hud.value.copyWith(
          statusLabel: 'Adjusting',
          primaryMessage:
              faceOk ? 'Mantén la cabeza recta' : 'Ubica tu rostro dentro del óvalo',
          secondaryMessage: _nullIfBlank(faceOk ? yawMsg : ''),
          checkFraming: faceOk ? Tri.ok : Tri.almost,
          checkHead: faceOk ? (yawOk ? Tri.ok : Tri.almost) : Tri.pending,
          checkEyes: Tri.almost,
          checkLighting: Tri.almost,
          checkBackground: Tri.almost,
          ovalProgress: arcProgress,
        ));
      }
    }

    // Start countdown only when both rules pass
    if (allChecksOk && !_isCountingDown) {
      _startCountdown();
    }
  }

  bool get _isCountingDown => _countdownTicker != null;

  void _startCountdown() {
    _stopCountdown();
    _countdownProgress = 1.0;
    _countdownSeconds = 3;

    // Update HUD immediately (keep current ovalProgress)
    _setHud(_hud.value.copyWith(
      countdownSeconds: _countdownSeconds,
      countdownProgress: _countdownProgress,
    ));

    // Tick ~30 fps for smooth ring, for 3 seconds total.
    const totalMs = 3000;
    const tickMs = 33;
    int elapsed = 0;

    _countdownTicker =
        Timer.periodic(const Duration(milliseconds: tickMs), (t) {
      elapsed += tickMs;
      final remainingMs = (totalMs - elapsed).clamp(0, totalMs);
      _countdownProgress = remainingMs / totalMs;

      final nextSeconds = (remainingMs / 1000.0).ceil();
      if (nextSeconds != _countdownSeconds) {
        _countdownSeconds = nextSeconds;
      }

      _setHud(_hud.value.copyWith(
        countdownSeconds: _countdownSeconds == 0 ? 1 : _countdownSeconds,
        countdownProgress: _countdownProgress,
        // ovalProgress unchanged here
      ));

      // Abort if face lost OR any validation fails while counting down
      if (widget.poseService.latestFrame.value == null || !_lastAllChecksOk) {
        _stopCountdown();
        return;
      }

      if (elapsed >= totalMs) {
        // 🔸 Here you would trigger the actual capture.
        // e.g., await widget.poseService.captureStill();
        _stopCountdown();
        // Keep UI in adjusting state; your review screen can take over here.
      }
    });
  }

  void _stopCountdown() {
    _countdownTicker?.cancel();
    _countdownTicker = null;
    _setHud(_hud.value.copyWith(
      countdownSeconds: null,
      countdownProgress: null,
      // keep ovalProgress as-is so the arc remains visible after cancel
    ));
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
