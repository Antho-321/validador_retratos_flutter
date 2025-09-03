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
    required this.azimutAbs,          // ⬅️ NEW

    // raw-for-UX directions
    this.yawDegForAnim,
    this.pitchDegForAnim,
    this.rollDegForAnim,
    this.shouldersDegSigned,
    this.azimutDegSigned,             // ⬅️ NEW

    // “inside now” flags at current enter-band
    required this.yawInsideNow,
    required this.pitchInsideNow,
    required this.rollInsideNow,
    required this.shouldersInsideNow,
    required this.azimutInsideNow,    // ⬅️ NEW
  });

  final DateTime now;
  final bool faceOk;
  final double arcProgress;

  final double yawAbs;
  final double pitchAbs;
  final double rollErr;          // error to 180°
  final double shouldersAbs;
  final double azimutAbs;        // |azimut| torso (deg) ⬅️ NEW

  final double? yawDegForAnim;
  final double? pitchDegForAnim;
  final double? rollDegForAnim;  // smoothed + unwrapped
  final double? shouldersDegSigned;
  final double? azimutDegSigned; // signo para hint direccional ⬅️ NEW

  final bool yawInsideNow;
  final bool pitchInsideNow;
  final bool rollInsideNow;
  final bool shouldersInsideNow;
  final bool azimutInsideNow;    // ⬅️ NEW
}

class _HintAnim {
  const _HintAnim(this.axis, this.hint);
  final _Axis axis;
  final String? hint;
}

// ── Bootstrap flag para forzar que el flujo inicie en TORSO ────────────
bool _flowBootstrapped = false;

// ── Extension with modular helpers ─────────────────────────────────────
extension _OnFrameLogicExt on PoseCaptureController {
  // Public entry (kept same name/signature via class method calling this)
  void _onFrameImpl() {
    // While capturing OR while a photo is displayed, ignore frame/HUD updates.
    if (isCapturing || capturedPng != null) return;

    final frame = poseService.latestFrame.value;

    // ── NUEVO: modo sin validaciones ────────────────────────────────
    if (!validationsEnabled) {
      // si las validaciones están OFF, la próxima vez que se enciendan
      // volveremos a arrancar el flujo desde TORSO
      _flowBootstrapped = false;

      if (frame == null) {
        _stopCountdown();
        final cur = hud.value;
        _setHud(
          PortraitUiModel(
            statusLabel: 'Searching',
            privacyLabel: cur.privacyLabel,
            primaryMessage: 'Vista previa (validaciones OFF)',
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
          force: true,
        );
      } else {
        if (isCountingDown) _stopCountdown(); // no auto-countdown en modo OFF
        final cur = hud.value;
        _setHud(
          PortraitUiModel(
            statusLabel: 'Preview',
            privacyLabel: cur.privacyLabel,
            primaryMessage: 'Validaciones desactivadas',
            secondaryMessage: null,
            checkFraming: Tri.ok,
            checkHead: Tri.almost,
            checkEyes: cur.checkEyes ?? Tri.almost,
            checkLighting: cur.checkLighting ?? Tri.almost,
            checkBackground: cur.checkBackground ?? Tri.almost,
            countdownSeconds: null,
            countdownProgress: null,
            ovalProgress: 1.0,
          ),
        );
      }
      return; // corte temprano: no evaluar nada más
    }
    // ── FIN modo sin validaciones ───────────────────────────────────

    if (frame == null) {
      _handleFaceLost();
      return;
    }

    // ── Bootstrap: forzar inicio del flujo en TORSO al (re)entrar ───
    if (!_flowBootstrapped) {
      _goToStage(_flowOrder.first); // _FlowStage.torso
      _flowBootstrapped = true;
    }

    // 1) Gather inputs + compute metrics and “inside now” flags
    final _EvalCtx? ctx = _evaluateCurrentFrame(frame);
    if (ctx == null) {
      // cannot evaluate due to missing deps (canvas/landmarks)
      _pushHudAdjusting(faceOk: false, arcProgress: 0.0, finalHint: null);
      return;
    }

    // 2) Advance state machine (with deferred backtracking) — genérico
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

    // al perder rostro, rebootstrap del flujo para arrancar en TORSO
    _flowBootstrapped = false;
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
    final double shouldersDeadbandNow = _shouldersGate.enterBand;

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

      // shoulders (nivelación)
      poseLandmarksImg: pose,
      enableShoulders: true,
      shouldersDeadbandDeg: shouldersDeadbandNow,
      shouldersMaxOffDeg: PoseCaptureController._maxOffDeg,
    );

    final now = DateTime.now();
    final bool faceOk = report.faceInOval;
    final double arcProgress = report.ovalProgress;

    // EMA for yaw/pitch
    final double dtMs = (_lastSampleAt == null)
        ? 16.0
        : now
            .difference(_lastSampleAt!)
            .inMilliseconds
            .toDouble()
            .clamp(1.0, 1000.0);
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

    // Azimut biacromial (torsión torso)
    final double? azimutDeg = _estimateAzimutBiacromial();
    final double azimutAbs = azimutDeg?.abs() ?? 0.0;

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
      azimutAbs: azimutAbs,                    // ⬅️ NEW
      yawDegForAnim: _emaYawDeg,
      pitchDegForAnim: _emaPitchDeg,
      rollDegForAnim: _emaRollDeg,             // smoothed/unwrapped
      shouldersDegSigned: report.shouldersDeg,
      azimutDegSigned: azimutDeg,              // ⬅️ NEW
      yawInsideNow: insideEnter(_yawGate, yawAbs),
      pitchInsideNow: insideEnter(_pitchGate, pitchAbs),
      rollInsideNow: insideEnter(_rollGate, rollErr),
      shouldersInsideNow: insideEnter(_shouldersGate, shouldersAbs),
      azimutInsideNow: (azimutDeg == null)     // si no hay 3D, no bloqueamos
          ? true
          : insideEnter(_azimutGate, azimutAbs),
    );
  }

  // ─────────────────────────────────────────────────────────────────────
  // (C) Motor de estado genérico impulsado por _flowOrder
  // ─────────────────────────────────────────────────────────────────────

  // Orden configurable del flujo (sin incluir 'done'). Reordena como gustes.
  List<_FlowStage> get _flowOrder => <_FlowStage>[
        _FlowStage.torso,      // ⬅️ torso primero
        _FlowStage.shoulders,
        _FlowStage.yaw,
        _FlowStage.pitch,
        _FlowStage.roll,
      ];

  _AxisGate _gateFor(_FlowStage s) {
    switch (s) {
      case _FlowStage.yaw:       return _yawGate;
      case _FlowStage.pitch:     return _pitchGate;
      case _FlowStage.roll:      return _rollGate;
      case _FlowStage.shoulders: return _shouldersGate;
      case _FlowStage.torso:     return _azimutGate;   // azimut biacromial
      case _FlowStage.done:
        throw StateError('No gate for DONE');
    }
  }

  double _metricFor(_FlowStage s, _EvalCtx c) {
    switch (s) {
      case _FlowStage.yaw:       return c.yawAbs;
      case _FlowStage.pitch:     return c.pitchAbs;
      case _FlowStage.roll:      return c.rollErr;       // error a 180°
      case _FlowStage.shoulders: return c.shouldersAbs;
      case _FlowStage.torso:     return c.azimutAbs;     // |azimut|
      case _FlowStage.done:
        throw StateError('No metric for DONE');
    }
  }

  void _goToStage(_FlowStage s) {
    if (s != _FlowStage.done) {
      _gateFor(s).resetTransient(); // limpiamos dwell/transitorios al entrar
    }
    _stage = s;
  }

  bool _allHolding(_EvalCtx c) {
    for (final s in _flowOrder) {
      final g = _gateFor(s);
      final m = _metricFor(s, c);
      if (!_isHolding(g, m)) return false;
    }
    return true;
  }

  _FlowStage? _firstPrevNotHolding(int uptoExclusiveIndex, _EvalCtx c) {
    // Busca de izquierda a derecha el primer stage previo que ya no “hold”.
    for (int i = 0; i < uptoExclusiveIndex; i++) {
      final s = _flowOrder[i];
      if (!_isHolding(_gateFor(s), _metricFor(s, c))) {
        return s;
      }
    }
    return null;
  }

  // Helper: no interrumpir mientras se valida shoulders o torso (azimut).
  bool _noInterruptionWhileValidating(_FlowStage s) =>
      s == _FlowStage.shoulders || s == _FlowStage.torso;

  // NEW: Ignorar rupturas previas según el stage actual.
  bool _shouldIgnorePrevBreak(_FlowStage cur, _FlowStage prev) {
    // 1) Mientras validas shoulders o torso: no interrumpas por ningún previo.
    if (cur == _FlowStage.shoulders || cur == _FlowStage.torso) return true;

    // 2) Mientras validas yaw/pitch/roll: ignora rupturas de shoulders y torso.
    if ((cur == _FlowStage.yaw || cur == _FlowStage.pitch || cur == _FlowStage.roll) &&
        (prev == _FlowStage.shoulders || prev == _FlowStage.torso)) {
      return true;
    }
    return false;
  }

  // NEW: Versión filtrada del "primer previo que no sostiene".
  _FlowStage? _firstPrevNotHoldingFiltered(
    int uptoExclusiveIndex,
    _EvalCtx c,
    bool Function(_FlowStage prev) shouldIgnore,
  ) {
    for (int i = 0; i < uptoExclusiveIndex; i++) {
      final s = _flowOrder[i];
      if (shouldIgnore(s)) continue; // saltar stages que decidimos ignorar
      if (!_isHolding(_gateFor(s), _metricFor(s, c))) {
        return s;
      }
    }
    return null;
  }

  // ⬇️ UPDATED: backtracking con filtros para no interrumpir indebidamente
  void _advanceFlowAndBacktrack(_EvalCtx c) {
    // 1) Si estamos en DONE, verificar que todos los stages siguen “holding”.
    if (_stage == _FlowStage.done) {
      if (!_allHolding(c)) {
        final s = _firstPrevNotHolding(_flowOrder.length, c)!;
        _goToStage(s);
      }
      return;
    }

    // 2) Asegurar que el stage actual pertenece al _flowOrder
    int idx = _flowOrder.indexOf(_stage);
    if (idx == -1) {
      _goToStage(_flowOrder.first);
      idx = 0;
    }

    // 3) Backtracking CONDICIONAL: solo si el stage actual NO está en dwell
    //    y respetando reglas de no-interrupción y filtrado por tipo de stage.
    final _FlowStage cur = _flowOrder[idx];
    final _AxisGate curGate = _gateFor(cur);

    final bool allowBacktrackNow =
        !curGate.isDwell && !_noInterruptionWhileValidating(cur);

    if (allowBacktrackNow) {
      final _FlowStage? prevBreak = _firstPrevNotHoldingFiltered(
        idx,
        c,
        (prev) => _shouldIgnorePrevBreak(cur, prev),
      );
      if (prevBreak != null) {
        _goToStage(prevBreak);
        return;
      }
    }

    // 4) Actualizar/confirmar el gate del stage actual.
    final _AxisGate gate = curGate;
    final double metric = _metricFor(cur, c);

    final bool confirmed = c.faceOk && gate.update(metric, c.now);
    if (!confirmed) {
      // Aún sin confirmar este stage: nos quedamos aquí.
      return;
    }

    // 5) Confirmado el actual: revalidar que los previos se mantienen (filtrado).
    final _FlowStage? prevBreakAfterConfirm = _firstPrevNotHoldingFiltered(
      idx,
      c,
      (prev) => _shouldIgnorePrevBreak(cur, prev),
    );
    if (prevBreakAfterConfirm != null && !_noInterruptionWhileValidating(cur)) {
      _goToStage(prevBreakAfterConfirm);
      return;
    }

    // 6) Avanzar al siguiente o terminar en DONE si era el último.
    final bool isLast = (idx == _flowOrder.length - 1);
    if (isLast) {
      _goToStage(_FlowStage.done);
    } else {
      final _FlowStage nextStage = _flowOrder[idx + 1];
      _goToStage(nextStage);
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

    // ⬇️ NEW: Torso azimuth hints (texto; sin animación)
    if (_stage == _FlowStage.torso &&
        !c.azimutInsideNow &&
        !_azimutGate.isDwell) {
      _hideAnimationIfVisible();
      String msg;
      if (c.azimutDegSigned != null) {
        msg = (c.azimutDegSigned! > 0)
            ? 'Gira ligeramente tu torso moviendo el hombro derecho hacia atrás'
            : 'Gira ligeramente tu torso moviendo el hombro izquierdo hacia atrás';
      } else {
        msg = 'Alinea el torso al frente (cuadra los hombros con la cámara).';
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
    final bool allChecksOk =
        c.faceOk &&
        _stage == _FlowStage.done;

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
}
