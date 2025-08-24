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

    // 🔒 Lock readiness to the containment result.
    final allChecksOk = landmarksWithinFaceOval;

    // In _onFrame(), after computing `allChecksOk`:
    _lastAllChecksOk = allChecksOk;

    if (!_isCountingDown) {
      // Adjusting UI while we wait for readiness gate.
      _setHud(_hud.value.copyWith(
        statusLabel: allChecksOk ? 'Ready' : 'Adjusting',
        primaryMessage:
            allChecksOk ? '¡Perfecto! ¡Permanece así!' : 'Ubica tu rostro dentro del óvalo',
        secondaryMessage: allChecksOk ? _nullIfBlank(null) : _nullIfBlank(''),
        checkFraming: allChecksOk ? Tri.ok : Tri.almost,
        checkHead: allChecksOk ? Tri.ok : Tri.almost,
        checkEyes: allChecksOk ? Tri.ok : Tri.almost,
        checkLighting: Tri.almost,
        checkBackground: Tri.almost,
        ovalProgress: ovalProgress, // ← send 0..1 to painter
      ));
    }

    if (allChecksOk && !_isCountingDown) {
      _startCountdown(); // auto-capture feel
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
