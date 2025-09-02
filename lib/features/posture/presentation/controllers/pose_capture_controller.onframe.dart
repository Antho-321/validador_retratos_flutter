// lib/features/posture/presentation/controllers/pose_capture_controller.onframe.dart
part of 'pose_capture_controller.dart';

// ── Top-level helper types (must NOT be inside an extension) ───────────
class _EvalCtx {
  _EvalCtx({
    required this.now,
    required this.faceOk,
    required this.arcProgress,

    // filtered metrics for gating/UX
    required this.yawAbs,
    required this.pitchAbs,
    required this.rollErr,
    required this.shouldersAbs,

    // raw-for-UX directions
    this.yawDegForAnim,
    this.pitchDegForAnim,
    this.rollDegForAnim,
    this.shouldersDegSigned,

    // “inside now” flags at current enter-band
    required this.yawInsideNow,
    required this.pitchInsideNow,
    required this.rollInsideNow,
    required this.shouldersInsideNow,
  });

  final DateTime now;
  final bool faceOk;
  final double arcProgress;

  final double yawAbs;
  final double pitchAbs;
  final double rollErr;          // error to 180°
  final double shouldersAbs;

  final double? yawDegForAnim;
  final double? pitchDegForAnim;
  final double? rollDegForAnim;  // smoothed + unwrapped
  final double? shouldersDegSigned;

  final bool yawInsideNow;
  final bool pitchInsideNow;
  final bool rollInsideNow;
  final bool shouldersInsideNow;
}

class _HintAnim {
  const _HintAnim(this.axis, this.hint);
  final _Axis axis;
  final String? hint;
}

// ── Extension with modular helpers ─────────────────────────────────────
extension _OnFrameLogicExt on PoseCaptureController {
  // Public entry (kept same name/signature via class method calling this)
  void _onFrameImpl() {
    // While capturing OR while a photo is displayed, ignore frame/HUD updates.
    if (isCapturing || capturedPng != null) return;

    final frame = poseService.latestFrame.value;
    if (frame == null) {
      _handleFaceLost();
      return;
    }

    // 1) Gather inputs + compute metrics and “inside now” flags
    final _EvalCtx? ctx = _evaluateCurrentFrame(frame);
    if (ctx == null) {
      // cannot evaluate due to missing deps (canvas/landmarks)
      _pushHudAdjusting(faceOk: false, arcProgress: 0.0, finalHint: null);
      return;
    }

    // 2) Advance state machine (with deferred backtracking)
    _advanceFlowAndBacktrack(ctx);

    // 3) Decide hints + drive animations (suppressed during dwell)
    final _HintAnim ha = _chooseHintAndUpdateAnimations(ctx);

    // 4) Update HUD and countdown orchestration
    _updateHudAndCountdown(ctx, ha);
  }

  // ─────────────────────────────────────────────────────────────────────
  // (A) Face lost: reset everything consistently
  // ─────────────────────────────────────────────────────────────────────
  void _handleFaceLost() {
    _stopCountdown(); // from mixin

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
    _resetFlow(); // from mixin
    _emaYawDeg = _emaPitchDeg = _emaRollDeg = null;
    _lastSampleAt = null;

    // Reset roll kinematics (unwrap/EMA/dps)
    _rollSmoothedDeg = null;
    _rollSmoothedAt = null;
    _lastRollDps = null;
  }

  // ─────────────────────────────────────────────────────────────────────
  // (B) Evaluate current frame → compute metrics, enter-bands, EMA/unwrap
  // ─────────────────────────────────────────────────────────────────────
  _EvalCtx? _evaluateCurrentFrame(dynamic frame) {
    final faces = poseService.latestFaceLandmarks;
    final canvas = _canvasSize;
    final pose = poseService.latestPoseLandmarks; // image-space points

    if (faces == null || faces.isEmpty || canvas == null) return null;

    // Use *current* enter-bands so progress bars match what we enforce
    final double yawDeadbandNow = _yawGate.enterBand;
    final double pitchDeadbandNow = _pitchGate.enterBand;
    final double rollDeadbandNow = _rollGate.enterBand; // roll uses error-to-180°

    final report = _validator.evaluate(
      landmarksImg: faces.first,
      imageSize: frame.imageSize,
      canvasSize: canvas,
      mirror: mirror,
      fit: BoxFit.cover,
      minFractionInside: 1.0,

      enableYaw: true,
      yawDeadbandDeg: yawDeadbandNow,
      yawMaxOffDeg: PoseCaptureController._maxOffDeg,

      enablePitch: true,
      pitchDeadbandDeg: pitchDeadbandNow,
      pitchMaxOffDeg: PoseCaptureController._maxOffDeg,

      // roll: deadband is tolerance of error to 180°
      enableRoll: true,
      rollDeadbandDeg: rollDeadbandNow,
      rollMaxOffDeg: PoseCaptureController._maxOffDeg,

      // NEW shoulders
      poseLandmarksImg: pose,
      enableShoulders: true,
      shouldersDeadbandDeg: _shouldersGate.enterBand,
      shouldersMaxOffDeg: PoseCaptureController._maxOffDeg,
    );

    final now = DateTime.now();
    final bool faceOk = report.faceInOval;
    final double arcProgress = report.ovalProgress;

    // EMA for yaw/pitch
    final double dtMs = (_lastSampleAt == null)
        ? 16.0
        : now.difference(_lastSampleAt!).inMilliseconds.toDouble().clamp(1.0, 1000.0);
    final double a = 1 - math.exp(-dtMs / PoseCaptureController._emaTauMs);
    _lastSampleAt ??= now;

    _emaYawDeg = (_emaYawDeg == null)
        ? report.yawDeg
        : (a * report.yawDeg + (1 - a) * _emaYawDeg!);
    _emaPitchDeg = (_emaPitchDeg == null)
        ? report.pitchDeg
        : (a * report.pitchDeg + (1 - a) * _emaPitchDeg!);
    _lastSampleAt = now;

    // Roll kinematics (unwrap + EMA + dps + error-to-180°)
    final _RollMetrics rollM = updateRollKinematics(report.rollDeg, now);

    final double yawAbs       = _emaYawDeg!.abs();
    final double pitchAbs     = _emaPitchDeg!.abs();
    final double rollErr      = rollM.errDeg;              // metric = distance to 180°
    final double shouldersAbs = report.shouldersDeg.abs();

    // Helper: inside *enter* band now
    bool insideEnter(_AxisGate g, double metric) {
      final th = g.enterBand;
      final inside = g.sense == _GateSense.insideIsOk;
      return inside ? (metric <= th) : (metric >= th);
    }

    return _EvalCtx(
      now: now,
      faceOk: faceOk,
      arcProgress: arcProgress,
      yawAbs: yawAbs,
      pitchAbs: pitchAbs,
      rollErr: rollErr,
      shouldersAbs: shouldersAbs,
      yawDegForAnim: _emaYawDeg,
      pitchDegForAnim: _emaPitchDeg,
      rollDegForAnim: _emaRollDeg,              // smoothed/unwrapped
      shouldersDegSigned: report.shouldersDeg,  // for side-specific hint
      yawInsideNow: insideEnter(_yawGate, yawAbs),
      pitchInsideNow: insideEnter(_pitchGate, pitchAbs),
      rollInsideNow: insideEnter(_rollGate, rollErr),
      shouldersInsideNow: insideEnter(_shouldersGate, shouldersAbs),
    );
  }

  // ─────────────────────────────────────────────────────────────────────
  // (C) State machine: advance stage and deferred backtracking
  // ─────────────────────────────────────────────────────────────────────
  void _advanceFlowAndBacktrack(_EvalCtx c) {
    switch (_stage) {
      case _FlowStage.yaw: {
        final bool confirmed = c.faceOk && _yawGate.update(c.yawAbs, c.now);
        if (confirmed) {
          _stage = _FlowStage.pitch;
          _pitchGate.resetTransient();
        }
        break;
      }

      case _FlowStage.pitch: {
        if (_pitchGate.isConfirmed && !_isHolding(_yawGate, c.yawAbs)) {
          _yawGate.resetTransient();
          _stage = _FlowStage.yaw;
          break;
        }
        final bool confirmed = c.faceOk && _pitchGate.update(c.pitchAbs, c.now);
        if (confirmed) {
          if (!_isHolding(_yawGate, c.yawAbs)) {
            _yawGate.resetTransient();
            _stage = _FlowStage.yaw;
          } else {
            _stage = _FlowStage.roll;
            _rollGate.resetTransient();
          }
        }
        break;
      }

      case _FlowStage.roll: {
        if (_rollGate.isConfirmed) {
          if (!_isHolding(_yawGate, c.yawAbs)) {
            _yawGate.resetTransient();
            _stage = _FlowStage.yaw; break;
          }
          if (!_isHolding(_pitchGate, c.pitchAbs)) {
            _pitchGate.resetTransient();
            _stage = _FlowStage.pitch; break;
          }
        }
        final bool confirmed = c.faceOk && _rollGate.update(c.rollErr, c.now);
        if (confirmed) {
          if (!_isHolding(_yawGate, c.yawAbs)) {
            _yawGate.resetTransient();
            _stage = _FlowStage.yaw;
          } else if (!_isHolding(_pitchGate, c.pitchAbs)) {
            _pitchGate.resetTransient();
            _stage = _FlowStage.pitch;
          } else {
            _stage = _FlowStage.shoulders;
            _shouldersGate.resetTransient();
          }
        }
        break;
      }

      case _FlowStage.shoulders: {
        if (_shouldersGate.isConfirmed) {
          if (!_isHolding(_yawGate, c.yawAbs)) {
            _yawGate.resetTransient(); _stage = _FlowStage.yaw; break;
          }
          if (!_isHolding(_pitchGate, c.pitchAbs)) {
            _pitchGate.resetTransient(); _stage = _FlowStage.pitch; break;
          }
          if (!_isHolding(_rollGate, c.rollErr)) {
            _rollGate.resetTransient(); _stage = _FlowStage.roll; break;
          }
        }
        final bool confirmed = c.faceOk && _shouldersGate.update(c.shouldersAbs, c.now);
        if (confirmed) {
          if (!_isHolding(_yawGate, c.yawAbs)) {
            _yawGate.resetTransient(); _stage = _FlowStage.yaw;
          } else if (!_isHolding(_pitchGate, c.pitchAbs)) {
            _pitchGate.resetTransient(); _stage = _FlowStage.pitch;
          } else if (!_isHolding(_rollGate, c.rollErr)) {
            _rollGate.resetTransient(); _stage = _FlowStage.roll;
          } else {
            _stage = _FlowStage.done;
          }
        }
        break;
      }

      case _FlowStage.done: {
        if (!_isHolding(_yawGate, c.yawAbs)) {
          _yawGate.resetTransient(); _stage = _FlowStage.yaw;
        } else if (!_isHolding(_pitchGate, c.pitchAbs)) {
          _pitchGate.resetTransient(); _stage = _FlowStage.pitch;
        } else if (!_isHolding(_rollGate, c.rollErr)) {
          _rollGate.resetTransient(); _stage = _FlowStage.roll;
        } else if (!_isHolding(_shouldersGate, c.shouldersAbs)) {
          _shouldersGate.resetTransient(); _stage = _FlowStage.shoulders;
        }
        break;
      }
    }
  }

  // ─────────────────────────────────────────────────────────────────────
  // (D) Choose hint + drive animation (suppressed during dwell)
  // ─────────────────────────────────────────────────────────────────────
  _HintAnim _chooseHintAndUpdateAnimations(_EvalCtx c) {
    if (!c.faceOk) {
      _hideAnimationIfVisible();
      return const _HintAnim(_Axis.none, null);
    }

    // Shoulders take priority in shoulders stage
    if (_stage == _FlowStage.shoulders && !c.shouldersInsideNow && !_shouldersGate.isDwell) {
      _hideAnimationIfVisible();
      String msg;
      if (c.shouldersDegSigned != null) {
        // positive ⇒ left shoulder lower than right
        msg = (c.shouldersDegSigned! > 0)
            ? 'Baja el hombro derecho o sube el izquierdo, un poco.'
            : 'Baja el hombro izquierdo o sube el derecho, un poco.';
      } else {
        msg = 'Nivela los hombros, mantenlos horizontales.';
      }
      return _HintAnim(_Axis.none, msg);
    }

    // Yaw
    if (_stage == _FlowStage.yaw &&
        c.yawDegForAnim != null &&
        !c.yawInsideNow &&
        !_yawGate.isDwell) {
      _driveYawAnimation(c.yawDegForAnim!);
      final hint = (c.yawDegForAnim! > 0)
          ? 'Gira ligeramente la cabeza a la izquierda'
          : 'Gira ligeramente la cabeza a la derecha';
      return _HintAnim(_Axis.yaw, hint);
    }

    // Pitch
    if (_stage == _FlowStage.pitch &&
        c.pitchDegForAnim != null &&
        !c.pitchInsideNow &&
        !_pitchGate.isDwell) {
      _drivePitchAnimation(c.pitchDegForAnim!);
      final hint = (c.pitchDegForAnim! > 0)
          ? 'Sube ligeramente la cabeza'
          : 'Baja ligeramente la cabeza';
      return _HintAnim(_Axis.pitch, hint);
    }

    // Roll (use delta to nearest 180°; honor deadzone)
    if (_stage == _FlowStage.roll &&
        c.rollDegForAnim != null &&
        !c.rollInsideNow &&
        !_rollGate.isDwell) {
      final double delta = this._deltaToNearest180(c.rollDegForAnim!);
      if (delta.abs() <= PoseCaptureController._rollHintDeadzoneDeg) {
        _hideAnimationIfVisible();
        return const _HintAnim(_Axis.none, null);
      }
      _driveRollAnimation(delta); // will mirror internally
      final bool ccwForUser = mirror ? (delta < 0) : (delta > 0);
      final hint = ccwForUser
          ? 'Rota ligeramente tu cabeza en sentido horario ⟳'
          : 'Rota ligeramente tu cabeza en sentido antihorario ⟲';
      return _HintAnim(_Axis.roll, hint);
    }

    _hideAnimationIfVisible();
    return const _HintAnim(_Axis.none, null);
  }

  void _driveYawAnimation(double yawDeg) {
    final desiredTurn = (yawDeg > 0) ? _TurnDir.left : _TurnDir.right;
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
    _ensureAnimVisible();
  }

  void _drivePitchAnimation(double pitchDeg) {
    final bool desiredPitchUp = pitchDeg > 0;
    _activeTurn = _TurnDir.none;
    _activeRollPositive = null;

    if (_activePitchUp != desiredPitchUp) {
      _activePitchUp = desiredPitchUp;
      if (desiredPitchUp) {
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
    _ensureAnimVisible();
  }

  void _driveRollAnimation(double deltaTo180) {
    // Map delta to user-perceived rotation with mirror
    final bool wantCcwForUser = mirror ? (deltaTo180 < 0) : (deltaTo180 > 0);

    _activeTurn = _TurnDir.none;
    // reuse _activeRollPositive to track “CCW-for-user”
    if (_activeRollPositive != wantCcwForUser) {
      _activeRollPositive = wantCcwForUser;

      if (wantCcwForUser) {
        // CCW
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
      } else {
        // CW
        // ignore: discarded_futures
        seq.loadFromAssets(
          directory: 'assets/frames',
          pattern: 'frame_%04d.png',
          startNumber: 14,
          count: 22,
          xStart: 512,
          xEnd: 768,
        );
      }
    }
    _ensureAnimVisible();
  }

  void _ensureAnimVisible() {
    if (!showTurnRightSeq) {
      showTurnRightSeq = true;
      notifyListeners();
    }
    try { seq.play(); } catch (_) {}
  }

  void _hideAnimationIfVisible() {
    if (showTurnRightSeq) {
      try { seq.pause(); } catch (_) {}
      showTurnRightSeq = false;
      notifyListeners();
    }
    _activeTurn = _TurnDir.none;
    _activePitchUp = null;
    _activeRollPositive = null;
  }

  // ─────────────────────────────────────────────────────────────────────
  // (E) HUD + countdown coordination
  // ─────────────────────────────────────────────────────────────────────
  void _updateHudAndCountdown(_EvalCtx c, _HintAnim ha) {
    final bool allChecksOk = c.faceOk && _stage == _FlowStage.done;

    // global stability window (no extra hold; gates already enforce dwell)
    if (allChecksOk) {
      _readySince ??= c.now;
    } else {
      _readySince = null;
    }

    if (isCountingDown && !allChecksOk) {
      _stopCountdown();
    }

    if (!isCountingDown) {
      if (allChecksOk) {
        _pushHudReady(arc: c.arcProgress);
      } else {
        _pushHudAdjusting(faceOk: c.faceOk, arcProgress: c.arcProgress, finalHint: ha.hint);
      }
    }

    if (!isCountingDown &&
        allChecksOk &&
        _readySince != null &&
        c.now.difference(_readySince!) >= PoseCaptureController._readyHold) {
      _startCountdown();
    }
  }

  void _pushHudReady({required double arc}) {
    final cur = hud.value;
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
        ovalProgress: arc,
      ),
    );
  }

  void _pushHudAdjusting({
    required bool faceOk,
    required double arcProgress,
    required String? finalHint,
  }) {
    final cur = hud.value;
    _setHud(
      PortraitUiModel(
        statusLabel: 'Adjusting',
        privacyLabel: cur.privacyLabel,
        primaryMessage: faceOk
            ? (_nullIfBlank(finalHint) ?? 'Mantén la cabeza recta')
            : 'Ubica tu rostro dentro del óvalo',
        secondaryMessage: null, // el mensaje accionable es primario
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

  // (Optional) If you still want an extension-scoped _onFrame mirror:
  // void _onFrame() => this._onFrameImpl();
}
