// lib/features/posture/presentation/controllers/pose_capture_controller.onframe.dart
part of 'pose_capture_controller.dart';

extension _OnFrameLogicExt on PoseCaptureController {
  // Updated _onFrame() body:
  // - Roll unwrap + error-to-180° gating
  // - Backtrack to previous axes only after current axis finishes
  // - Hints decided by *current* metric vs band (not hasConfirmedOnce)
  // - Actionable hint promoted to primaryMessage
  // - NEW: Shoulders stage with the same gating mechanics
  void _onFrameImpl() {
    // ── begin: original _onFrame body (with fixes) ───────────
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

      // Reset roll kinematics (unwrap/EMA/dps)
      _rollSmoothedDeg = null;
      _rollSmoothedAt = null;
      _lastRollDps = null;

      return;
    }

    // Defaults when we can't evaluate.
    bool faceOk = false;
    double arcProgress = 0.0;

    // Keep values available outside the block for the animation chooser
    double? yawDegForAnim;
    double? pitchDegForAnim;
    double? rollDegForAnim; // smoothed, unwrapped roll (not the error)
    double? shouldersDegForHint; // NEW: signed, to decide left/right hint

    // For hint decisions (current position vs thresholds)
    bool? yawInsideNow;
    bool? pitchInsideNow;
    bool? rollInsideNow;
    bool? shouldersInsideNow; // NEW

    final faces = poseService.latestFaceLandmarks;
    final canvas = _canvasSize;
    // Pose landmarks (image-space). Adjust getter if your service differs.
    final pose = poseService.latestPoseLandmarks;

    // Use current enter-bands so progress bars match what we are enforcing
    final double _yawDeadbandNow = _yawGate.enterBand;
    final double _pitchDeadbandNow = _pitchGate.enterBand;
    final double _rollDeadbandNow = _rollGate.enterBand; // roll uses error-to-180° deadband

    if (faces != null && faces.isNotEmpty && canvas != null) {
      final report = _validator.evaluate(
        landmarksImg: faces.first,
        imageSize: frame.imageSize,
        canvasSize: canvas,
        mirror: mirror,
        fit: BoxFit.cover,
        minFractionInside: 1.0,

        enableYaw: true,
        yawDeadbandDeg: _yawDeadbandNow,
        yawMaxOffDeg: PoseCaptureController._maxOffDeg,

        enablePitch: true,
        pitchDeadbandDeg: _pitchDeadbandNow,
        pitchMaxOffDeg: PoseCaptureController._maxOffDeg,

        // Para roll: deadband = tolerancia del error relativo a 180°
        enableRoll: true,
        rollDeadbandDeg: _rollDeadbandNow,
        rollMaxOffDeg: PoseCaptureController._maxOffDeg,

        // NEW: Shoulders tilt rule
        poseLandmarksImg: pose, // or pose?.first if your service returns multiple
        enableShoulders: true,
        shouldersDeadbandDeg: _shouldersGate.enterBand,
        shouldersMaxOffDeg: PoseCaptureController._maxOffDeg,
      );

      faceOk = report.faceInOval;
      arcProgress = report.ovalProgress;

      final now = DateTime.now();

      // ── EMA para YAW y PITCH (señales directas en grados)
      final dtMs = (() {
        if (_lastSampleAt == null) return 16.0;
        return now
            .difference(_lastSampleAt!)
            .inMilliseconds
            .toDouble()
            .clamp(1.0, 1000.0);
      })();
      final a = 1 - math.exp(-dtMs / PoseCaptureController._emaTauMs);
      _lastSampleAt ??= now;

      _emaYawDeg = (_emaYawDeg == null)
          ? report.yawDeg
          : (a * report.yawDeg + (1 - a) * _emaYawDeg!);
      _emaPitchDeg = (_emaPitchDeg == null)
          ? report.pitchDeg
          : (a * report.pitchDeg + (1 - a) * _emaPitchDeg!);

      _lastSampleAt = now;

      // ── Cinemática de ROLL: unwrap + EMA propia + dps + error a 180°
      final _RollMetrics rollM = updateRollKinematics(report.rollDeg, now);
      // updateRollKinematics también sincroniza _emaRollDeg con la señal suavizada

      // Usar valores filtrados para gating + animaciones/mensajes
      final double yawAbs       = _emaYawDeg!.abs();
      final double pitchAbs     = _emaPitchDeg!.abs();
      final double rollErr      = rollM.errDeg;              // métrica de roll (distancia a 180°)
      final double shouldersAbs = report.shouldersDeg.abs(); // NEW
      shouldersDegForHint = report.shouldersDeg;             // NEW (signo para el mensaje)

      // Helper para saber si *ahora mismo* estoy dentro del umbral de entrada
      bool _insideEnter(_AxisGate g, double metric) {
        final th = g.enterBand;
        final inside = g.sense == _GateSense.insideIsOk;
        return inside ? (metric <= th) : (metric >= th);
      }

      yawInsideNow        = _insideEnter(_yawGate, yawAbs);
      pitchInsideNow      = _insideEnter(_pitchGate, pitchAbs);
      rollInsideNow       = _insideEnter(_rollGate, rollErr);
      shouldersInsideNow  = _insideEnter(_shouldersGate, shouldersAbs); // NEW

      // ── Máquina de estados con backtrack diferido ─────────────────────
      switch (_stage) {
        case _FlowStage.yaw: {
          final bool confirmedNow = faceOk && _yawGate.update(yawAbs, now);

          if (confirmedNow) {
            _stage = _FlowStage.pitch;
            _pitchGate.resetTransient();
          }
          break;
        }

        case _FlowStage.pitch: {
          if (_pitchGate.isConfirmed && !_isHolding(_yawGate, yawAbs)) {
            _yawGate.resetTransient();
            _stage = _FlowStage.yaw;
            break;
          }

          final bool confirmedNow = faceOk && _pitchGate.update(pitchAbs, now);

          if (confirmedNow) {
            if (!_isHolding(_yawGate, yawAbs)) {
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
            if (!_isHolding(_yawGate, yawAbs)) {
              _yawGate.resetTransient();
              _stage = _FlowStage.yaw;
              break;
            }
            if (!_isHolding(_pitchGate, pitchAbs)) {
              _pitchGate.resetTransient();
              _stage = _FlowStage.pitch;
              break;
            }
          }

          final bool confirmedNow = faceOk && _rollGate.update(rollErr, now);

          if (confirmedNow) {
            if (!_isHolding(_yawGate, yawAbs)) {
              _yawGate.resetTransient();
              _stage = _FlowStage.yaw;
            } else if (!_isHolding(_pitchGate, pitchAbs)) {
              _pitchGate.resetTransient();
              _stage = _FlowStage.pitch;
            } else {
              _stage = _FlowStage.shoulders; // NEW
              _shouldersGate.resetTransient();
            }
          }
          break;
        }

        case _FlowStage.shoulders: {
          if (_shouldersGate.isConfirmed) {
            if (!_isHolding(_yawGate, yawAbs)) {
              _yawGate.resetTransient();
              _stage = _FlowStage.yaw;
              break;
            }
            if (!_isHolding(_pitchGate, pitchAbs)) {
              _pitchGate.resetTransient();
              _stage = _FlowStage.pitch;
              break;
            }
            if (!_isHolding(_rollGate, rollErr)) {
              _rollGate.resetTransient();
              _stage = _FlowStage.roll;
              break;
            }
          }

          final bool shouldersConfirmed =
              faceOk && _shouldersGate.update(shouldersAbs, now);

          if (shouldersConfirmed) {
            if (!_isHolding(_yawGate, yawAbs)) {
              _yawGate.resetTransient();
              _stage = _FlowStage.yaw;
            } else if (!_isHolding(_pitchGate, pitchAbs)) {
              _pitchGate.resetTransient();
              _stage = _FlowStage.pitch;
            } else if (!_isHolding(_rollGate, rollErr)) {
              _rollGate.resetTransient();
              _stage = _FlowStage.roll;
            } else {
              _stage = _FlowStage.done;
            }
          }
          break;
        }

        case _FlowStage.done: {
          if (!_isHolding(_yawGate, yawAbs)) {
            _yawGate.resetTransient();
            _stage = _FlowStage.yaw;
          } else if (!_isHolding(_pitchGate, pitchAbs)) {
            _pitchGate.resetTransient();
            _stage = _FlowStage.pitch;
          } else if (!_isHolding(_rollGate, rollErr)) {
            _rollGate.resetTransient();
            _stage = _FlowStage.roll;
          } else if (!_isHolding(_shouldersGate, shouldersAbs)) { // NEW
            _shouldersGate.resetTransient();
            _stage = _FlowStage.shoulders;
          }
          break;
        }
      }

      // Valores para el selector de animaciones
      yawDegForAnim = _emaYawDeg;
      pitchDegForAnim = _emaPitchDeg;
      rollDegForAnim = _emaRollDeg; // suavizado/desenvuelto
    }

    // Choose axis animation/hint (suppress during dwell).
    // IMPORTANT: Decide by *current* metric vs enter band, not hasConfirmedOnce.
    _Axis desiredAxis = _Axis.none;
    String? finalHint;

    if (faceOk) {
      if (_stage == _FlowStage.shoulders &&
          shouldersInsideNow == false &&
          !_shouldersGate.isDwell) {
        desiredAxis = _Axis.none;
        if (shouldersDegForHint != null) {
          // Convención: positivo ⇒ hombro izquierdo más bajo que el derecho.
          finalHint = (shouldersDegForHint! > 0)
              ? 'Baja el hombro derecho o sube el izquierdo, un poco.'
              : 'Baja el hombro izquierdo o sube el derecho, un poco.';
        } else {
          finalHint = 'Nivela los hombros, mantenlos horizontales.';
        }

      } else if (_stage == _FlowStage.yaw &&
          yawDegForAnim != null &&
          yawInsideNow == false &&
          !_yawGate.isDwell) {
        desiredAxis = _Axis.yaw;
        finalHint = (_emaYawDeg! > 0)
            ? 'Gira ligeramente la cabeza a la izquierda'
            : 'Gira ligeramente la cabeza a la derecha';

      } else if (_stage == _FlowStage.pitch &&
          pitchDegForAnim != null &&
          pitchInsideNow == false &&
          !_pitchGate.isDwell) {
        desiredAxis = _Axis.pitch;
        finalHint = (_emaPitchDeg! > 0)
            ? 'Sube ligeramente la cabeza'
            : 'Baja ligeramente la cabeza';

      } else if (_stage == _FlowStage.roll &&
          rollDegForAnim != null &&
          rollInsideNow == false &&
          !_rollGate.isDwell) {
        // FIX: decide direction by shortest delta to nearest 180°, not by sign(roll)
        final double delta = this._deltaToNearest180(rollDegForAnim!);
        if (delta.abs() > PoseCaptureController._rollHintDeadzoneDeg) {
          desiredAxis = _Axis.roll;
          // Map to user-perceived (mirrored) rotation: true ⇒ CCW for user.
          final bool ccwForUser = mirror ? (delta < 0) : (delta > 0);
          finalHint = ccwForUser
              ? 'Rota ligeramente tu cabeza en sentido horario ⟳'
              : 'Rota ligeramente tu cabeza en sentido antihorario ⟲';
        } else {
          desiredAxis = _Axis.none; // near-perfect → no flip-flop
        }
      }
    }

    // Axis-specific animation loaders
    if (desiredAxis == _Axis.yaw && yawDegForAnim != null) {
      _TurnDir desiredTurn =
          (yawDegForAnim! > 0) ? _TurnDir.left : _TurnDir.right;

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
      final bool desiredPitchUp = pitchDegForAnim! > 0;

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

      if (!showTurnRightSeq) {
        showTurnRightSeq = true;
        notifyListeners();
      }
      try { seq.play(); } catch (_) {}

    } else if (desiredAxis == _Axis.roll && rollDegForAnim != null) {
      // Drive roll animation by required correction (delta) + mirror,
      // not by the raw roll sign.
      final double delta = _deltaToNearest180(rollDegForAnim!);
      final bool wantCcwForUser = mirror ? (delta < 0) : (delta > 0);

      _activeTurn = _TurnDir.none;
      _activePitchUp = null;

      // Reuse _activeRollPositive to track "CCW-for-user" state.
      if (_activeRollPositive != wantCcwForUser) {
        _activeRollPositive = wantCcwForUser;

        if (wantCcwForUser) {
          // CCW animation for the user (swap branches if your sprite is opposite)
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
          // CW animation for the user
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

      if (!showTurnRightSeq) {
        showTurnRightSeq = true;
        notifyListeners();
      }
      try { seq.play(); } catch (_) {}

    } else {
      if (showTurnRightSeq) {
        try { seq.pause(); } catch (_) {}
        showTurnRightSeq = false;
        notifyListeners();
      }
      _activeTurn = _TurnDir.none;
      _activePitchUp = null;
      _activeRollPositive = null;
    }

    // Global stability window
    final now = DateTime.now();
    final bool allChecksOk = faceOk && _stage == _FlowStage.done;

    if (allChecksOk) {
      _readySince ??= now;
    } else {
      _readySince = null;
    }

    if (isCountingDown && !allChecksOk) {
      _stopCountdown();
    }

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
            primaryMessage: faceOk
                ? (finalHint ?? 'Mantén la cabeza recta')
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
    }

    if (!isCountingDown &&
        allChecksOk &&
        _readySince != null &&
        now.difference(_readySince!) >= PoseCaptureController._readyHold) {
      _startCountdown();
    }
    // ── end: original _onFrame body ───────────────────────────
  }
}
