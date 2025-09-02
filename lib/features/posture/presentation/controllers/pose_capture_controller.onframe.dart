// lib/features/posture/presentation/controllers/pose_capture_controller.onframe.dart
part of 'pose_capture_controller.dart';

extension _OnFrameLogicExt on PoseCaptureController {
  // Updated _onFrame() body integrating roll unwrap + error-to-180° gating.
  void _onFrameImpl() {
    // ── begin: original _onFrame body (with roll integration) ───────────
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
    bool yawOk = false;
    bool pitchOk = false;
    bool rollOk = false;
    double arcProgress = 0.0;

    // Keep values available outside the block for the animation chooser
    double? yawDegForAnim;
    double? pitchDegForAnim;
    double? rollDegForAnim; // smoothed, unwrapped roll (not the error)

    final faces = poseService.latestFaceLandmarks;
    final canvas = _canvasSize;

    // Use current enter-bands so progress bars match what we are enforcing
    final double _yawDeadbandNow = _yawGate.enterBand;
    final double _pitchDeadbandNow = _pitchGate.enterBand;
    final double _rollDeadbandNow = _rollGate.enterBand; // NOTE: roll uses error-to-180° deadband

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

        // Para roll, el validador recibe el deadband que ahora representa la
        // tolerancia de error respecto a 180°. El gating usa esta misma métrica.
        enableRoll: true,
        rollDeadbandDeg: _rollDeadbandNow,
        rollMaxOffDeg: PoseCaptureController._maxOffDeg,
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
      final double yawAbs   = _emaYawDeg!.abs();
      final double pitchAbs = _emaPitchDeg!.abs();
      final double rollErr  = rollM.errDeg; // métrica de roll para el gate (distancia a 180°)

      // Stage rollback si una validación previa dejó de sostenerse
      if (_stage == _FlowStage.pitch) {
        if (!_isHolding(_yawGate, yawAbs)) {
          _stage = _FlowStage.yaw;
          _yawGate.resetForNewStage();
        }
      } else if (_stage == _FlowStage.roll) {
        if (!_isHolding(_yawGate, yawAbs)) {
          _stage = _FlowStage.yaw;
          _yawGate.resetForNewStage();
          _pitchGate.resetForNewStage();
        } else if (!_isHolding(_pitchGate, pitchAbs)) {
          _stage = _FlowStage.pitch;
          _pitchGate.resetForNewStage();
        }
      } else if (_stage == _FlowStage.done) {
        if (!_isHolding(_yawGate, yawAbs)) {
          _stage = _FlowStage.yaw;
          _yawGate.resetForNewStage();
          _pitchGate.resetForNewStage();
          _rollGate.resetForNewStage();
        } else if (!_isHolding(_pitchGate, pitchAbs)) {
          _stage = _FlowStage.pitch;
          _pitchGate.resetForNewStage();
          _rollGate.resetForNewStage();
        } else if (!_isHolding(_rollGate, rollErr)) {
          _stage = _FlowStage.roll;
          _rollGate.resetForNewStage();
        }
      }

      // Sequential gating (usar hasConfirmedOnce para checks previos)
      yawOk   = _yawGate.hasConfirmedOnce;
      pitchOk = _pitchGate.hasConfirmedOnce;
      rollOk  = _rollGate.hasConfirmedOnce;

      switch (_stage) {
        case _FlowStage.yaw:
          yawOk = faceOk && _yawGate.update(yawAbs, now);
          if (yawOk) {
            _stage = _FlowStage.pitch;
            _pitchGate.resetForNewStage();
          }
          break;
        case _FlowStage.pitch:
          pitchOk = faceOk && _pitchGate.update(pitchAbs, now);
          if (pitchOk) {
            _stage = _FlowStage.roll;
            _rollGate.resetForNewStage();
          }
          break;
        case _FlowStage.roll:
          // IMPORTANTE: para roll usamos la **métrica de error** (no |roll|)
          rollOk = faceOk && _rollGate.update(rollErr, now);
          if (rollOk) {
            _stage = _FlowStage.done;
          }
          break;
        case _FlowStage.done:
          break;
      }

      // Valores para el selector de animaciones (signo usa _emaRollDeg suavizado)
      yawDegForAnim = _emaYawDeg;
      pitchDegForAnim = _emaPitchDeg;
      rollDegForAnim = _emaRollDeg;
    }

    // Choose axis animation/hint (suppress during dwell)
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
      final bool desiredRollPositive = rollDegForAnim! > 0;

      _activeTurn = _TurnDir.none;
      _activePitchUp = null;

      if (_activeRollPositive != desiredRollPositive) {
        _activeRollPositive = desiredRollPositive;

        if (desiredRollPositive) {
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

    if (!isCountingDown &&
        allChecksOk &&
        _readySince != null &&
        now.difference(_readySince!) >= PoseCaptureController._readyHold) {
      _startCountdown();
    }
    // ── end: original _onFrame body ───────────────────────────
  }
}
