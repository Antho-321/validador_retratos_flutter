// lib/features/posture/presentation/controllers/pose_capture_controller.onframe.dart
part of 'pose_capture_controller.dart';

extension _OnFrameLogicExt on PoseCaptureController {
  // Updated _onFrame() body:
  // - Roll unwrap + error-to-180° gating
  // - Backtrack to previous axes only after current axis finishes
  // - Hints decided by *current* metric vs band (not hasConfirmedOnce)
  // - Actionable hint promoted to primaryMessage
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

    // For hint decisions (current position vs thresholds)
    bool? yawInsideNow;
    bool? pitchInsideNow;
    bool? rollInsideNow;

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

      // Helper para saber si *ahora mismo* estoy dentro del umbral de entrada
      bool _insideEnter(_AxisGate g, double metric) {
        final th = g.enterBand;
        final inside = g.sense == _GateSense.insideIsOk;
        return inside ? (metric <= th) : (metric >= th);
      }

      yawInsideNow   = _insideEnter(_yawGate, yawAbs);
      pitchInsideNow = _insideEnter(_pitchGate, pitchAbs);
      rollInsideNow  = _insideEnter(_rollGate, rollErr);

      // ── Máquina de estados con backtrack diferido ─────────────────────
      switch (_stage) {
        case _FlowStage.yaw: {
          // Validar YAW normalmente (entra a dwell, espera dwell, confirma).
          final bool confirmedNow = faceOk && _yawGate.update(yawAbs, now);

          if (confirmedNow) {
            _stage = _FlowStage.pitch;
            // No reseteamos yaw ni pitch completo; pitch comienza su intento fresco:
            _pitchGate.resetTransient(); // mantiene knowledge del tighten post-primer-intento
          }
          break;
        }

        case _FlowStage.pitch: {
          // Mientras pitch esté en searching/dwell, NO interrumpimos por YAW.
          // Si pitch ya estaba confirmado y yaw dejó de sostenerse, retrocedemos.
          if (_pitchGate.isConfirmed && !_isHolding(_yawGate, yawAbs)) {
            _yawGate.resetTransient();
            _stage = _FlowStage.yaw;
            break;
          }

          final bool confirmedNow = faceOk && _pitchGate.update(pitchAbs, now);

          if (confirmedNow) {
            // Pitch terminó. AHORA exigimos que YAW siga sosteniéndose.
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
          // Mientras roll esté en searching/dwell, NO interrumpimos por YAW/PITCH.
          // Si roll ya estaba confirmado y Y/P dejan de sostenerse, retrocedemos.
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
            // Roll terminó. AHORA exigimos sostener YAW y PITCH.
            if (!_isHolding(_yawGate, yawAbs)) {
              _yawGate.resetTransient();
              _stage = _FlowStage.yaw;
            } else if (!_isHolding(_pitchGate, pitchAbs)) {
              _pitchGate.resetTransient();
              _stage = _FlowStage.pitch;
            } else {
              _stage = _FlowStage.done;
            }
          }
          break;
        }

        case _FlowStage.done: {
          // Ya no hay “validación actual”; aquí sí se puede retroceder inmediatamente
          // si algún eje deja de sostenerse (comportamiento esperado tras completar todo).
          if (!_isHolding(_yawGate, yawAbs)) {
            _yawGate.resetTransient();
            _stage = _FlowStage.yaw;
          } else if (!_isHolding(_pitchGate, pitchAbs)) {
            _pitchGate.resetTransient();
            _stage = _FlowStage.pitch;
          } else if (!_isHolding(_rollGate, rollErr)) {
            _rollGate.resetTransient();
            _stage = _FlowStage.roll;
          }
          break;
        }
      }

      // Valores para el selector de animaciones (signo usa _emaRollDeg suavizado)
      yawDegForAnim = _emaYawDeg;
      pitchDegForAnim = _emaPitchDeg;
      rollDegForAnim = _emaRollDeg;
    }

    // Choose axis animation/hint (suppress during dwell).
    // IMPORTANT: Decide by *current* metric vs enter band, not hasConfirmedOnce.
    _Axis desiredAxis = _Axis.none;
    String? finalHint;

    if (faceOk) {
      if (_stage == _FlowStage.yaw &&
          yawDegForAnim != null &&
          yawInsideNow == false && // actualmente fuera del umbral
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
