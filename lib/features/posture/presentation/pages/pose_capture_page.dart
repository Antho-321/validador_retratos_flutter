// lib/features/posture/presentation/pages/pose_capture_page.dart
import 'dart:async';
import 'dart:ui' show Offset, Size; // ← for _faceOvalPts & LayoutBuilder size
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../services/pose_webrtc_service.dart';
import '../widgets/rtc_pose_overlay.dart' show PoseOverlayFast;
import '../widgets/portrait_validator_hud.dart'
    show
        PortraitValidatorHUD,
        PortraitUiController,
        PortraitUiModel,
        Tri,
        faceOvalPointsFor,
        faceOvalRectFor; // ← add these

// If your polygon check lives elsewhere, import it here:
import '../../utils/geometry.dart' show areLandmarksWithinFaceOval, mapImagePointsToCanvas;

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

  // Cache the oval polygon (screen/canvas coordinates)
  List<Offset>? _faceOvalPts; // ← added

  // Keep current canvas size to map image→canvas like the painter.
  Size? _canvasSize; // ← added

  // Countdown state
  DateTime? _faceSince; // kept (cleared on face loss)
  Timer? _countdownTicker;
  double _countdownProgress = 1.0; // 1 → 0
  int _countdownSeconds = 3;

  @override
  void initState() {
    super.initState();
    _hud = PortraitUiController(
      PortraitUiModel(
        statusLabel: 'Adjusting',
        privacyLabel: 'On-device',
        primaryMessage: 'Centra tu rostro en el óvalo',
        // If this comes as '' or ' ', normalize to null so the pill shrinks.
        secondaryMessage: _nullIfBlank(''),
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

 

  /// Convenience: latest face landmarks already mapped to canvas coordinates.
  /// Returns null if any prerequisite is missing.
  List<Offset>? _latestFacePointsOnCanvas() {
    final frame = widget.poseService.latestFrame.value;
    final faces = widget.poseService.latestFaceLandmarks;
    final canvas = _canvasSize;
    if (frame == null || faces == null || faces.isEmpty || canvas == null) {
      return null;
    }
    // IMPORTANT: use the SAME fit & mirror that your overlay/HUD uses.
    return mapImagePointsToCanvas(
      faces.first, // one face (list of Offsets in image px)
      frame.imageSize, // source image size
      canvas, // current canvas size from LayoutBuilder
      mirror: _mirror,
      fit: BoxFit.cover,
    );
  }

  // ─────────────────────────────────────────────────────────────────────

  void _onFrame() {
    final frame = widget.poseService.latestFrame.value;

    if (frame == null) {
      // Lost face → abort countdown and reset.
      _faceSince = null;
      _stopCountdown();
      _hud.value = _hud.value.copyWith(
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
      );
      return;
    }

    // Compute polygon containment in the SAME canvas space.
    bool landmarksWithinFaceOval = false;
    if (_faceOvalPts != null) {
      final faceCanvasPts = _latestFacePointsOnCanvas();
      if (faceCanvasPts != null && faceCanvasPts.isNotEmpty) {
        landmarksWithinFaceOval =
            areLandmarksWithinFaceOval(_faceOvalPts!, faceCanvasPts);
      }
    }

    // 🔒 Lock readiness to the containment result.
    final allChecksOk = landmarksWithinFaceOval;

    if (!_isCountingDown) {
      // Adjusting UI while we wait for readiness gate.
      _hud.value = _hud.value.copyWith(
        statusLabel: allChecksOk ? 'Ready' : 'Adjusting',
        primaryMessage:
            allChecksOk ? 'Perfect! Hold still' : 'Center face in the oval',
        // If you ever pass ' ' (a space), this turns into null and hides the line.
        secondaryMessage:
            allChecksOk ? _nullIfBlank(null) : _nullIfBlank('Lower chin slightly'),
        checkFraming: allChecksOk ? Tri.ok : Tri.almost,
        checkHead: allChecksOk ? Tri.ok : Tri.almost,
        checkEyes: Tri.almost,
        checkLighting: Tri.almost,
        checkBackground: Tri.almost,
      );
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

    // Update HUD immediately
    _hud.value = _hud.value.copyWith(
      countdownSeconds: _countdownSeconds,
      countdownProgress: _countdownProgress,
    );

    // Tick 30 times per second for smooth ring, for 3 seconds total.
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

      _hud.value = _hud.value.copyWith(
        countdownSeconds: _countdownSeconds == 0 ? 1 : _countdownSeconds,
        countdownProgress: _countdownProgress,
      );

      // Abort if face lost (your real code should also abort if any rule fails)
      if (widget.poseService.latestFrame.value == null) {
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
    _hud.value =
        _hud.value.copyWith(countdownSeconds: null, countdownProgress: null);
  }

  @override
  Widget build(BuildContext context) {
    final svc = widget.poseService;

    return LayoutBuilder( // ← wrap to get the actual canvas size
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        _canvasSize = size; // ← keep current canvas size for mapping

        // Polygon matching the on-screen oval (in screen/canvas coordinates)
        _faceOvalPts = faceOvalPointsFor(size, samples: 180);

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
