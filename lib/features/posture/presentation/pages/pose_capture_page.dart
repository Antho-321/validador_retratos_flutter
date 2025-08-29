// lib/features/posture/presentation/pages/pose_capture_page.dart
import 'dart:async';
import 'dart:typed_data' show Uint8List, ByteBuffer, ByteData;
import 'dart:ui' show Size; // for LayoutBuilder size
import 'dart:ui' as ui show Image, ImageByteFormat;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../services/pose_webrtc_service.dart';
import '../widgets/rtc_pose_overlay.dart' show PoseOverlayFast;
import '../widgets/portrait_validator_hud.dart'
    show PortraitValidatorHUD, PortraitUiController, PortraitUiModel, Tri;
import '../widgets/frame_sequence_overlay.dart'
    show FrameSequenceOverlay, FrameSequenceController, FramePlayMode;

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

  // ── Frame sequence overlay controller ─────────────────────────────
  late final FrameSequenceController seq;

  // Centralized validator for all portrait rules (oval + yaw/pitch/roll).
  final PortraitValidator _validator = const PortraitValidator();

  // Angle thresholds (deg)
  static const double _yawDeadbandDeg = 2.2;
  static const double _pitchDeadbandDeg = 2.2;
  static const double _rollDeadbandDeg = 179; // small tilt tolerance
  static const double _maxOffDeg = 20.0;

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

  // Snapshot state
  final GlobalKey _previewKey = GlobalKey(); // wraps only the camera preview
  Uint8List? _capturedPng; // captured bytes (from WebRTC track or boundary fallback)

  // Capture-mode flag to hide preview/HUD instantly at T=0
  bool _isCapturing = false;

  // Early-fire latch so we shoot as soon as digits hit '1'
  bool _firedAtOne = false;

  // ── NEW: Hint trigger & visibility for sequence ──────────────────
  static const _kTurnRightHint = 'Gira ligeramente la cabeza a la derecha';
  bool _turnRightSeqLoaded = false;
  bool _showTurnRightSeq = false; // only render while hint is shown

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

    // HUD controller
    _hud = PortraitUiController(
      const PortraitUiModel(
        statusLabel: 'Adjusting',
        privacyLabel: 'On-device',
        primaryMessage: 'Ubica tu rostro dentro del óvalo',
        // secondaryMessage intentionally omitted (null)
        ovalProgress: 0.0, // start at 0%
      ),
    );

    // Init sequence controller (do NOT load frames yet; we’ll load on hint)
    seq = FrameSequenceController(
      fps: 30,
      playMode: FramePlayMode.forward,
      loop: true,
      autoplay: true,
    );

    // Start receiving pose frames.
    widget.poseService.latestFrame.addListener(_onFrame);
  }

  @override
  void dispose() {
    widget.poseService.latestFrame.removeListener(_onFrame);
    _stopCountdown();
    seq.dispose();
    _hud.dispose();
    super.dispose();
  }

  // ─────────────────────────────────────────────────────────────────────
  /// Preferred still capture: grab a frame directly from the local WebRTC video track.
  /// Falls back to boundary snapshot if `captureFrame` isn't available.
  Future<void> _captureFromWebRtcTrack() async {
    try {
      MediaStream? stream =
          widget.poseService.localRenderer.srcObject ?? widget.poseService.localStream;
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

      if (!mounted) return;
      if (bytes.isNotEmpty) {
        setState(() {
          _capturedPng = bytes;   // if your plugin returns encoded PNG/JPEG
          _isCapturing = false;
          // Clear stability latch so we don't instantly re-arm.
          _readySince = null;
          _lastAllChecksOk = false;
        });
        return;
      }
    } catch (e) {
      // ignore: avoid_print
      print('captureFrame failed, falling back to boundary: $e');
    }

    await _captureSnapshot();
    if (mounted) {
      setState(() {
        _isCapturing = false;
        // Also clear stability on fallback path.
        _readySince = null;
        _lastAllChecksOk = false;
      });
    }
  }

  void _onFrame() {
    // While capturing OR while a photo is displayed, ignore frame/HUD updates.
    if (_isCapturing || _capturedPng != null) return;

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

      // Also hide/stop the sequence if it was showing
      if (_showTurnRightSeq) {
        _showTurnRightSeq = false;
        // If your controller supports it, pause/stop to save cycles:
        try { seq.pause(); } catch (_) {}
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

    final faces = widget.poseService.latestFaceLandmarks;
    final canvas = _canvasSize;

    if (faces != null && faces.isNotEmpty && canvas != null) {
      final report = _validator.evaluate(
        landmarksImg: faces.first, // image-space points (px)
        imageSize: frame.imageSize, // from latestFrame
        canvasSize: canvas, // from LayoutBuilder
        mirror: _mirror, // must match your preview overlay
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
            if (report.rollDeg < 0) {
              rollMsg = 'Gira ligeramente tu cabeza en sentido horario ⟳';
            } else {
              rollMsg = 'Gira ligeramente tu cabeza en sentido antihorario ⟲';
            }
          }
        }
      }

      // Choose the worst (lowest progress) offender for the single secondary hint
      String? combinedHint;
      if (faceOk && (!yawOk || !pitchOk || !rollOk)) {
        final issues = <MapEntry<double, String>>[];
        if (!yawOk && yawMsg != null) {
          issues.add(MapEntry(report.yawProgress, yawMsg));
        }
        if (!pitchOk && pitchMsg != null) {
          issues.add(MapEntry(report.pitchProgress, pitchMsg));
        }
        if (!rollOk && rollMsg != null) {
          issues.add(MapEntry(report.rollProgress, rollMsg));
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
    }

    // Decide the final hint that will actually be shown in the HUD:
    final String? finalHint = faceOk ? (yawMsg ?? pitchMsg ?? rollMsg) : null;

    // ── Animate only while the specific hint is active ──────────────
    if (finalHint == _kTurnRightHint) {
      if (!_turnRightSeqLoaded) {
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
      }
      if (!_showTurnRightSeq) {
        setState(() => _showTurnRightSeq = true);
      }
      // Keep it running while visible (if API available)
      try { seq.play(); } catch (_) {}
    } else {
      // Hint disappeared → stop/pause and hide overlay
      if (_showTurnRightSeq) {
        try { seq.pause(); } catch (_) {}
        setState(() => _showTurnRightSeq = false);
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
            countdownSeconds: null, // ensure no stale ring shows
            countdownProgress: null, // ensure no stale ring shows
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
            secondaryMessage: _nullIfBlank(faceOk ? (finalHint ?? '') : ''),
            checkFraming: faceOk ? Tri.ok : Tri.almost,
            checkHead: faceOk ? ((yawOk && pitchOk && rollOk) ? Tri.ok : Tri.almost) : Tri.pending,
            checkEyes: Tri.almost,
            checkLighting: Tri.almost,
            checkBackground: Tri.almost,
            countdownSeconds: null, // hard-clear to avoid race with throttle
            countdownProgress: null, // hard-clear to avoid race with throttle
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

    // reset early-fire latch
    _firedAtOne = false;

    final int totalLogicalMs = widget.countdownDuration.inMilliseconds;
    final int totalScaledMs =
        (totalLogicalMs / widget.countdownSpeed).round().clamp(1, 24 * 60 * 60 * 1000);

    // Start digits from the logical (unscaled) duration → e.g., 3
    _countdownSeconds = (totalLogicalMs / 1000.0).ceil();

    _setHud(
      _hud.value.copyWith(
        countdownSeconds: _countdownSeconds,
        countdownProgress: _countdownProgress,
      ),
      force: true,
    );

    final int tickMs = (1000 / widget.countdownFps).round().clamp(10, 1000);
    int elapsedScaled = 0;

    _countdownTicker = Timer.periodic(Duration(milliseconds: tickMs), (_) {
      elapsedScaled += tickMs;

      final int remainingScaledMs =
          (totalScaledMs - elapsedScaled).clamp(0, totalScaledMs);
      _countdownProgress = remainingScaledMs / totalScaledMs;

      // Map scaled time → logical seconds (keeps 3→2→1 regardless of speed)
      final int remainingLogicalMs =
          (remainingScaledMs / totalScaledMs * totalLogicalMs).round();
      final int nextSeconds =
          (remainingLogicalMs / 1000.0).ceil().clamp(1, _countdownSeconds);

      if (nextSeconds != _countdownSeconds) {
        _countdownSeconds = nextSeconds;
      }

      _setHud(
        _hud.value.copyWith(
          countdownSeconds: _countdownSeconds,
          countdownProgress: _countdownProgress,
        ),
      );

      // Abort if stream died or validations failed mid-countdown.
      if (widget.poseService.latestFrame.value == null || !_lastAllChecksOk) {
        _stopCountdown();
        return;
      }

      // ── Early fire: as soon as digits read "1", shoot immediately.
      if (!_firedAtOne && nextSeconds == 1) {
        final bool okToShoot =
            widget.poseService.latestFrame.value != null && _lastAllChecksOk;
        if (okToShoot) {
          if (mounted) setState(() => _isCapturing = true);
          _firedAtOne = true;
          unawaited(_captureFromWebRtcTrack());
          _stopCountdown(); // stop ring now; we've taken the shot
          return; // prevent falling through to "finished" path this tick
        }
      }

      // Countdown finished → capture, then stop. (Fallback if not fired at "1")
      if (!_firedAtOne && elapsedScaled >= totalScaledMs) {
        final bool okToShoot =
            widget.poseService.latestFrame.value != null && _lastAllChecksOk;

        if (okToShoot) {
          // Hide preview/HUD immediately at T=0
          if (mounted) setState(() => _isCapturing = true);

          // Call WebRTC-track capture immediately (skip extra frame delay).
          unawaited(_captureFromWebRtcTrack());
        }

        _stopCountdown();
      }
    });
  }

  void _stopCountdown() {
    _countdownTicker?.cancel();
    _countdownTicker = null;

    // Clear stability so we don't re-arm immediately after a stop.
    _readySince = null;
    _lastAllChecksOk = false;

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
        countdownSeconds: null, // cleared for real
        countdownProgress: null, // cleared for real
        ovalProgress: cur.ovalProgress,
      ),
      force: true,
    );
  }

  Future<void> _captureSnapshot() async {
    try {
      final ctx = _previewKey.currentContext;
      if (ctx == null) return;

      final boundary = ctx.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) return;

      // Match on-screen sharpness.
      final dpr = MediaQuery.of(context).devicePixelRatio;
      final ui.Image image = await boundary.toImage(pixelRatio: dpr);

      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) return;

      if (!mounted) return;
      setState(() {
        _capturedPng = byteData.buffer.asUint8List();
        _isCapturing = false;
        // Clear stability latch after snapshot too.
        _readySince = null;
        _lastAllChecksOk = false;
      });
    } catch (e) {
      // ignore: avoid_print
      print('Snapshot failed: $e');
      if (mounted) {
        setState(() => _isCapturing = false); // recover UI on failure
      }
    }
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
              // Live preview + overlays only when NOT capturing and no photo shown
              if (!_isCapturing && _capturedPng == null) ...[
                // 1) Full-screen local preview (wrapped for snapshot)
                Positioned.fill(
                  child: RepaintBoundary(
                    key: _previewKey,
                    child: RTCVideoView(
                      svc.localRenderer,
                      mirror: _mirror,
                      objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                    ),
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
                      messageGap: 0.045,
                    ),
                  ),
                ),

                // 4) Frame sequence animation overlay (ONLY while hint is active)
                if (_showTurnRightSeq)
                  Positioned(
                    left: 0,
                    right: 0,
                    // ~65% desde arriba: queda por debajo de los textos del HUD.
                    top: constraints.maxHeight * 0.75,
                    child: IgnorePointer(
                      child: SizedBox(
                        // Área de la animación (ajusta a gusto)
                        height: constraints.maxHeight * 0.25,
                        child: Center(
                          child: Transform.scale(
                            scale: 0.60,
                            child: FrameSequenceOverlay(
                              controller: seq,
                              mirror: false,
                              fit: BoxFit.contain,
                              opacity: 1.0,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),

                // 5) Optional remote PiP
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
                      objectFit:
                          RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                    ),
                  ),
                ),
              ],

              // Capture in progress (hidden live UI, image not ready yet)
              if (_isCapturing && _capturedPng == null)
                const Positioned.fill(
                  child: ColoredBox(
                    color: Colors.black,
                    child: Center(child: CircularProgressIndicator()),
                  ),
                ),

              // Captured photo overlay (tap/close → return to live)
              if (_capturedPng != null)
                Positioned.fill(
                  child: Container(
                    color: Colors.black,
                    alignment: Alignment.center,
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: GestureDetector(
                            onTap: () => setState(() {
                              _capturedPng = null;
                              _isCapturing = false; // restore live UI
                              // Ensure a fresh readiness window after closing.
                              _readySince = null;
                              _lastAllChecksOk = false;
                            }),
                            child: Center(
                              child: Image.memory(
                                _capturedPng!,
                                fit: BoxFit.contain,
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          top: 16,
                          right: 16,
                          child: Material(
                            color: Colors.black54,
                            shape: const CircleBorder(),
                            child: IconButton(
                              icon: const Icon(Icons.close, color: Colors.white),
                              onPressed: () => setState(() {
                                _capturedPng = null;
                                _isCapturing = false;
                                _readySince = null;
                                _lastAllChecksOk = false;
                              }),
                              tooltip: 'Cerrar',
                            ),
                          ),
                        ),
                      ],
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
