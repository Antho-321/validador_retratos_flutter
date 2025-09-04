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
    required this.azimutAbs, // |azimut| solo para UI/debug

    // raw-for-UX directions
    this.yawDegForAnim,
    this.pitchDegForAnim,
    this.rollDegForAnim,
    this.shouldersDegSigned,
    this.azimutDegSigned,

    // “inside now” flags at current enter-band
    required this.yawInsideNow,
    required this.pitchInsideNow,
    required this.rollInsideNow,
    required this.shouldersInsideNow,
    required this.azimutInsideNow,
  });

  final DateTime now;
  final bool faceOk;
  final double arcProgress;

  final double yawAbs;
  final double pitchAbs;
  final double rollErr; // error to 180°
  final double shouldersAbs;
  final double azimutAbs; // |azimut| (deg) para UI/debug

  final double? yawDegForAnim;
  final double? pitchDegForAnim;
  final double? rollDegForAnim; // smoothed + unwrapped
  final double? shouldersDegSigned;
  final double? azimutDegSigned; // firmado para hints

  final bool yawInsideNow;
  final bool pitchInsideNow;
  final bool rollInsideNow;
  final bool shouldersInsideNow;
  final bool azimutInsideNow;
}

class _HintAnim {
  const _HintAnim(this.axis, this.hint);
  final _Axis axis;
  final String? hint;
}

// ───────────────────────────────────────────────────────────────────────
// Reglas plug-in (arquitectura data-driven para añadir validaciones fácil)
// ───────────────────────────────────────────────────────────────────────

abstract class _ValidationRule {
  _ValidationRule({
    required this.id,
    required this.gate,
    this.ignorePrevBreakOf = const <String>{},
    this.blockInterruptionDuranteValidacion = false,
  });

  /// Identificador estable de la regla (p.ej., 'azimut', 'shoulders', 'yaw'...)
  final String id;

  /// Gate de estabilidad (deadband, hysteresis, dwell, tighten…)
  final _AxisGate gate;

  /// Si una ruptura previa proviene de un ID en este set, se ignora.
  final Set<String> ignorePrevBreakOf;

  /// Si true, mientras esta regla valida/dwell no permitas retroceder.
  final bool blockInterruptionDuranteValidacion;

  /// Métrica escalar evaluada por la regla. `null` = no bloquear (sin datos).
  double? metric(_EvalCtx c);

  /// Hint/animación cuando aún no está “inside” (puede usar `ctrl`).
  _HintAnim buildHint(PoseCaptureController ctrl, _EvalCtx c);

  /// Conveniencia: ¿está dentro del enter-band actual?
  bool insideNow(_EvalCtx c) {
    final m = metric(c);
    if (m == null) return true;
    final th = gate.enterBand;
    final inside = gate.sense == _GateSense.insideIsOk;
    return inside ? (m <= th) : (m >= th);
  }
}

// ── Reglas concretas ───────────────────────────────────────────────────

class _AzimutRule extends _ValidationRule {
  _AzimutRule(_AxisGate gate)
      : super(
          id: 'azimut',
          gate: gate,
          blockInterruptionDuranteValidacion: true,
        );

  // ✅ Métrica firmada: negativa dentro de [lo, hi], 0 en borde, positiva fuera.
  @override
  double? metric(_EvalCtx c) {
    final d = c.azimutDegSigned;
    if (d == null) return null;

    // Δ de expansión derivado del gate
    final double delta = gate.hysteresis - gate.tighten;
    final double expand = (delta > 0) ? delta : 0.0;

    // Antes de tocar el estricto → [3;10]
    // Después (firstAttemptDone=true) → [3-expand; 10+expand]
    final double lo = gate.firstAttemptDone
        ? PoseCaptureController._azimutBandLoDeg - expand
        : PoseCaptureController._azimutBandLoDeg;

    final double hi = gate.firstAttemptDone
        ? PoseCaptureController._azimutBandHiDeg + expand
        : PoseCaptureController._azimutBandHiDeg;

    return PoseCaptureController._signedDistanceToBand(d, lo, hi);
  }

  @override
  _HintAnim buildHint(PoseCaptureController ctrl, _EvalCtx c) {
    // Si ya estás en dwell o "inside now", muestra mantener
    if (gate.isDwell || c.azimutInsideNow) {
      ctrl._hideAnimationIfVisible();
      return const _HintAnim(_Axis.none, 'Mantén el torso recto');
    }
    ctrl._hideAnimationIfVisible();

    final a = c.azimutDegSigned;
    if (a == null) {
      return const _HintAnim(
        _Axis.none,
        'Alinea el torso al frente (cuadra los hombros).',
      );
    }

    // Límites del estricto: [5.5; 7.5] = [lo+tighten ; hi-tighten]
    final double strictLo = PoseCaptureController._azimutBandLoDeg + gate.tighten;
    final double strictHi = PoseCaptureController._azimutBandHiDeg - gate.tighten;

    if (!gate.firstAttemptDone) {
      // ⬅️ Antes de tocar el estricto:
      // dentro de [3;10] pero fuera de [5.5;7.5] → seguir mostrando "Gira..."
      if (a < strictLo) {
        return const _HintAnim(
          _Axis.none,
          'Gira ligeramente el torso moviendo el hombro izquierdo hacia atrás',
        );
      }
      if (a > strictHi) {
        return const _HintAnim(
          _Axis.none,
          'Gira ligeramente el torso moviendo el hombro derecho hacia atrás',
        );
      }
      // Ya entraste en [5.5;7.5] ⇒ calmamos a "Mantén..."
      return const _HintAnim(_Axis.none, 'Mantén el torso recto');
    }

    // ⬇️ Después de tocar el estricto: usamos el band expandido para hints
    final double expand = (gate.hysteresis - gate.tighten);
    final double loExp = PoseCaptureController._azimutBandLoDeg - (expand > 0 ? expand : 0.0);
    final double hiExp = PoseCaptureController._azimutBandHiDeg + (expand > 0 ? expand : 0.0);

    if (a < loExp) {
      return const _HintAnim(
        _Axis.none,
        'Gira ligeramente el torso moviendo el hombro izquierdo hacia atrás',
      );
    }
    if (a > hiExp) {
      return const _HintAnim(
        _Axis.none,
        'Gira ligeramente el torso moviendo el hombro derecho hacia atrás',
      );
    }

    // Dentro del band expandido ⇒ "Mantén..."
    return const _HintAnim(_Axis.none, 'Mantén el torso recto');
  }
}

class _ShouldersRule extends _ValidationRule {
  _ShouldersRule(_AxisGate gate)
      : super(
          id: 'shoulders',
          gate: gate,
          blockInterruptionDuranteValidacion: true,
        );

  @override
  double? metric(_EvalCtx c) => c.shouldersAbs;

  @override
  _HintAnim buildHint(PoseCaptureController ctrl, _EvalCtx c) {
    if (c.shouldersInsideNow || gate.isDwell) {
      ctrl._hideAnimationIfVisible();
      return const _HintAnim(_Axis.none, 'Mantén los hombros nivelados');
    }
    ctrl._hideAnimationIfVisible();

    // ✔️ Usar SHOULDERS, no azimut
    final s = c.shouldersDegSigned;
    if (s != null) {
      final msg = (s > 0)
          ? 'Baja un poco el hombro derecho o sube el izquierdo'
          : 'Baja un poco el hombro izquierdo o sube el derecho';
      return _HintAnim(_Axis.none, msg);
    }

    return const _HintAnim(
      _Axis.none,
      'Nivela los hombros, mantenlos horizontales.',
    );
  }
}

class _YawRule extends _ValidationRule {
  _YawRule(_AxisGate gate)
      : super(
          id: 'yaw',
          gate: gate,
          ignorePrevBreakOf: const {'azimut', 'shoulders'},
        );

  @override
  double? metric(_EvalCtx c) => c.yawAbs;

  @override
  _HintAnim buildHint(PoseCaptureController ctrl, _EvalCtx c) {
    if (c.yawInsideNow || gate.isDwell || c.yawDegForAnim == null) {
      ctrl._hideAnimationIfVisible();
      return const _HintAnim(_Axis.none, null);
    }
    ctrl._driveYawAnimation(c.yawDegForAnim!);
    final hint = (c.yawDegForAnim! > 0)
        ? 'Gira ligeramente la cabeza a la izquierda'
        : 'Gira ligeramente la cabeza a la derecha';
    return _HintAnim(_Axis.yaw, hint);
  }
}

class _PitchRule extends _ValidationRule {
  _PitchRule(_AxisGate gate)
      : super(
          id: 'pitch',
          gate: gate,
          ignorePrevBreakOf: const {'azimut', 'shoulders'},
        );

  @override
  double? metric(_EvalCtx c) => c.pitchAbs;

  @override
  _HintAnim buildHint(PoseCaptureController ctrl, _EvalCtx c) {
    if (c.pitchInsideNow || gate.isDwell || c.pitchDegForAnim == null) {
      ctrl._hideAnimationIfVisible();
      return const _HintAnim(_Axis.none, null);
    }
    ctrl._drivePitchAnimation(c.pitchDegForAnim!);
    final hint =
        (c.pitchDegForAnim! > 0) ? 'Sube ligeramente la cabeza' : 'Baja ligeramente la cabeza';
    return _HintAnim(_Axis.pitch, hint);
  }
}

class _RollRule extends _ValidationRule {
  _RollRule(_AxisGate gate)
      : super(
          id: 'roll',
          gate: gate,
          ignorePrevBreakOf: const {'azimut', 'shoulders'},
        );

  @override
  double? metric(_EvalCtx c) => c.rollErr; // distancia a 180° (≤ umbral = OK)

  @override
  _HintAnim buildHint(PoseCaptureController ctrl, _EvalCtx c) {
    if (c.rollInsideNow || gate.isDwell || c.rollDegForAnim == null) {
      ctrl._hideAnimationIfVisible();
      return const _HintAnim(_Axis.none, null);
    }
    final delta = ctrl._deltaToNearest180(c.rollDegForAnim!);
    if (delta.abs() <= PoseCaptureController._rollHintDeadzoneDeg) {
      ctrl._hideAnimationIfVisible();
      return const _HintAnim(_Axis.none, null);
    }
    ctrl._driveRollAnimation(delta);
    final ccwForUser = ctrl.mirror ? (delta < 0) : (delta > 0);
    final hint =
        ccwForUser ? 'Rota ligeramente tu cabeza en sentido horario ⟳' : 'Rota ligeramente tu cabeza en sentido antihorario ⟲';
    return _HintAnim(_Axis.roll, hint);
  }
}

// ── Estado por instancia para reglas usando Expando (sin tocar la clase) ──
final Expando<List<_ValidationRule>> _rulesExp = Expando('_rules');
final Expando<int> _idxExp = Expando('_idx');

// ── Extension with modular helpers ─────────────────────────────────────
extension _OnFrameLogicExt on PoseCaptureController {
  // Public entry (kept same name/signature via class method calling this)
  void _onFrameImpl() {
    // While capturing OR while a photo is displayed, ignore frame/HUD updates.
    if (isCapturing || capturedPng != null) return;

    final frame = poseService.latestFrame.value;

    // ── Modo sin validaciones ──────────────────────────────────────────
    if (!validationsEnabled) {
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
      return; // corte temprano
    }
    // ── FIN modo sin validaciones ──────────────────────────────────────

    if (frame == null) {
      _handleFaceLost();
      return;
    }

    // Asegura reglas inicializadas
    _ensureRules();

    // 1) Gather inputs + compute metrics and “inside now” flags
    final _EvalCtx? ctx = _evaluateCurrentFrame(frame);
    if (ctx == null) {
      _pushHudAdjusting(faceOk: false, arcProgress: 0.0, finalHint: null);
      return;
    }

    // 2) Motor genérico (avanzar / retroceder)
    _advanceFlowAndBacktrack(ctx);

    // 3) Hint/animación de la regla actual
    final _HintAnim ha = _isDone
        ? const _HintAnim(_Axis.none, null)
        : _currentRule.buildHint(this, ctx);

    // 4) HUD + countdown
    _updateHudAndCountdown(ctx, ha);
  }

  // ─────────────────────────────────────────────────────────────────────
  // Estado/registro de reglas
  // ─────────────────────────────────────────────────────────────────────
  List<_ValidationRule> get _rules {
    final got = _rulesExp[this];
    if (got != null) return got;

    final list = <_ValidationRule>[
      // AZIMUT: métrica firmada (negativa dentro) ⇒ baseDeadband = 0.0 con tighten
      _AzimutRule(_AxisGate(
        baseDeadband: 0.0,                 // 0 ⇒ borde (queremos < 0 en “estricto”)
        sense: _GateSense.insideIsOk,      // métrica ≤ umbral pasa
        tighten: 2.5,                      // primer intento más estricto
        hysteresis: 3,
        dwell: const Duration(milliseconds: 1000),
        extraRelaxAfterFirst: 0.2,
      )),
      _ShouldersRule(_AxisGate(
        baseDeadband: PoseCaptureController._shouldersDeadbandDeg,
        sense: _GateSense.insideIsOk,
        tighten: 1.6,
        hysteresis: 0.2,
        dwell: const Duration(milliseconds: 1000),
        extraRelaxAfterFirst: 0.2,
      )),
      _YawRule(_AxisGate(
        baseDeadband: PoseCaptureController._yawDeadbandDeg,
        tighten: 1.4,
        hysteresis: 0.2,
        dwell: const Duration(milliseconds: 1000),
        extraRelaxAfterFirst: 0.2,
      )),
      _PitchRule(_AxisGate(
        baseDeadband: PoseCaptureController._pitchDeadbandDeg,
        tighten: 1.4,
        hysteresis: 0.2,
        dwell: const Duration(milliseconds: 1000),
        extraRelaxAfterFirst: 0.2,
      )),
      _RollRule(_AxisGate(
        baseDeadband: PoseCaptureController._rollErrorDeadbandDeg,
        sense: _GateSense.insideIsOk,
        tighten: 0.4,
        hysteresis: 0.3,
        dwell: const Duration(milliseconds: 1000),
        extraRelaxAfterFirst: 0.4,
      )),
    ];

    _rulesExp[this] = list;
    _idxExp[this] = 0;
    return list;
  }

  void _ensureRules() {
    // fuerza inicialización perezosa
    // ignore: unused_local_variable
    final _ = _rules;
    _idxExp[this] ??= 0;
  }

  int get _curIdx => _idxExp[this] ?? 0;
  set _curIdx(int v) => _idxExp[this] = v;

  bool get _isDone => _curIdx >= _rules.length;

  _ValidationRule get _currentRule => _rules[_curIdx];

  _ValidationRule? _findRule(String id) {
    for (final r in _rules) {
      if (r.id == id) return r;
    }
    return null;
  }

  // ⬇️ Helper para saber si una regla es la actual
  bool _isCurrentRule(String id) => !_isDone && _currentRule.id == id;

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
      try {
        seq.pause();
      } catch (_) {}
      notifyListeners();
    }

    // Reset flujo + filtros
    _resetFlow();

    _emaYawDeg = _emaPitchDeg = _emaRollDeg = null;
    _lastSampleAt = null;

    // Reset roll kinematics (unwrap/EMA/dps)
    _rollSmoothedDeg = null;
    _rollSmoothedAt = null;
    _lastRollDps = null;
  }

  // Reset del flujo basado en reglas
  void _resetFlow() {
    _ensureRules();
    _curIdx = 0;
    for (final r in _rules) {
      r.gate.resetForNewStage();
    }
  }

  // ─────────────────────────────────────────────────────────────────────
  // (B) Evaluate current frame → compute metrics, enter-bands, EMA/unwrap
  // ─────────────────────────────────────────────────────────────────────
  _EvalCtx? _evaluateCurrentFrame(dynamic frame) {
    final faces = poseService.latestFaceLandmarks;
    final canvas = _canvasSize;
    final pose = poseService.latestPoseLandmarks; // image-space points
    if (faces == null || faces.isEmpty || canvas == null) return null;

    // Deadbands actuales (usar gates de las reglas)
    final yawDeadbandNow = (_findRule('yaw')?.gate.enterBand) ?? 2.2;
    final pitchDeadbandNow = (_findRule('pitch')?.gate.enterBand) ?? 2.2;
    final rollDeadbandNow = (_findRule('roll')?.gate.enterBand) ?? 1.7;
    final shouldersDeadbandNow = (_findRule('shoulders')?.gate.enterBand) ?? 1.8;

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

      // roll: deadband es tolerancia de error a 180°
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

    // EMA para yaw/pitch
    final double dtMs = (_lastSampleAt == null)
        ? 16.0
        : now.difference(_lastSampleAt!).inMilliseconds.toDouble().clamp(1.0, 1000.0);
    final double a = 1 - math.exp(-dtMs / PoseCaptureController._emaTauMs);
    _lastSampleAt ??= now;

    _emaYawDeg = (_emaYawDeg == null) ? report.yawDeg : (a * report.yawDeg + (1 - a) * _emaYawDeg!);
    _emaPitchDeg =
        (_emaPitchDeg == null) ? report.pitchDeg : (a * report.pitchDeg + (1 - a) * _emaPitchDeg!);
    _lastSampleAt = now;

    // Roll kinematics (unwrap + EMA + dps + error-to-180°)
    final _RollMetrics rollM = updateRollKinematics(report.rollDeg, now);

    // Azimut biacromial (torsión azimut)
    final double? azimutDeg = _estimateAzimutBiacromial();
    final double azimutAbs = azimutDeg?.abs() ?? 0.0;

    final double yawAbs = _emaYawDeg!.abs();
    final double pitchAbs = _emaPitchDeg!.abs();
    final double rollErr = rollM.errDeg; // metric = distance to 180°
    final double shouldersAbs = report.shouldersDeg.abs();

    // Helper: inside *enter* band now
    bool insideEnter(_AxisGate g, double metric) {
      final th = g.enterBand;
      final inside = g.sense == _GateSense.insideIsOk;
      return inside ? (metric <= th) : (metric >= th);
    }

    // Gates de las reglas para "inside now"
    final yawGateNow = _findRule('yaw')!.gate;
    final pitchGateNow = _findRule('pitch')!.gate;
    final rollGateNow = _findRule('roll')!.gate;
    final shouldersGateNow = _findRule('shoulders')!.gate;
    final azimutGateNow = _findRule('azimut')!.gate;

    // ✅ Azimut: usa la distancia firmada también para el flag "inside now".
    final double? azMetricSigned = (azimutDeg == null)
        ? null
        : PoseCaptureController._signedDistanceToBand(
            azimutDeg,
            PoseCaptureController._azimutBandLoDeg,
            PoseCaptureController._azimutBandHiDeg,
          );

    final bool azInside = (azMetricSigned == null)
        ? true // sin Z ⇒ no bloquea
        : insideEnter(azimutGateNow, azMetricSigned);

    return _EvalCtx(
      now: now,
      faceOk: faceOk,
      arcProgress: arcProgress,
      yawAbs: yawAbs,
      pitchAbs: pitchAbs,
      rollErr: rollErr,
      shouldersAbs: shouldersAbs,
      azimutAbs: azimutAbs, // solo UI/debug
      yawDegForAnim: _emaYawDeg,
      pitchDegForAnim: _emaPitchDeg,
      rollDegForAnim: _emaRollDeg, // smoothed/unwrapped
      shouldersDegSigned: report.shouldersDeg,
      azimutDegSigned: azimutDeg,
      yawInsideNow: insideEnter(yawGateNow, yawAbs),
      pitchInsideNow: insideEnter(pitchGateNow, pitchAbs),
      rollInsideNow: insideEnter(rollGateNow, rollErr),
      shouldersInsideNow: insideEnter(shouldersGateNow, shouldersAbs),
      azimutInsideNow: azInside,
    );
  }

  // ─────────────────────────────────────────────────────────────────────
  // (C) Motor de estado genérico impulsado por reglas
  // ─────────────────────────────────────────────────────────────────────

  bool _ruleHolds(_ValidationRule r, _EvalCtx c) {
    final m = r.metric(c);
    if (m == null) return true;
    final exit = r.gate.exitBand;
    final relax = r.gate.hasConfirmedOnce ? r.gate.extraRelaxAfterFirst : 0.0;
    final inside = r.gate.sense == _GateSense.insideIsOk;
    return inside ? (m <= exit + relax) : (m >= exit - relax);
  }

  _ValidationRule? _firstPrevNotHoldingFiltered(
    int uptoExclusive,
    _EvalCtx c,
    _ValidationRule cur,
  ) {
    for (int i = 0; i < uptoExclusive; i++) {
      final prev = _rules[i];
      if (cur.ignorePrevBreakOf.contains(prev.id)) continue;
      if (!_ruleHolds(prev, c)) return prev;
    }
    return null;
  }

  void _advanceFlowAndBacktrack(_EvalCtx c) {
    if (_isDone) {
      // En DONE, mantener que todo “hold”; si algo cae, retrocede al primero
      for (int i = 0; i < _rules.length; i++) {
        if (!_ruleHolds(_rules[i], c)) {
          _curIdx = i;
          return;
        }
      }
      return;
    }

    if (_curIdx < 0 || _curIdx >= _rules.length) _curIdx = 0;

    final current = _rules[_curIdx];

    // ⬅️ NEW: bloquear retroceso durante el primer dwell de la regla actual si así lo pide
    final bool lockCurrentFirstDwell =
        current.blockInterruptionDuranteValidacion && !current.gate.hasConfirmedOnce;

    // Backtracking condicional: no si está en dwell ni si bloquea interrupción (primer dwell)
    final allowBacktrack = !current.gate.isDwell && !lockCurrentFirstDwell;
    if (allowBacktrack) {
      final prevBreak = _firstPrevNotHoldingFiltered(_curIdx, c, current);
      if (prevBreak != null) {
        _curIdx = _rules.indexOf(prevBreak);
        return;
      }
    }

    // Actualiza/Confirma el gate de la regla actual
    final m = current.metric(c);
    final confirmed = c.faceOk && (m != null) && current.gate.update(m, c.now);
    if (!confirmed) return;

    // Revisa rupturas previas tras confirmar (si aún aplica el lock del primer dwell, no retrocedas)
    final prevBreakAfter = _firstPrevNotHoldingFiltered(_curIdx, c, current);
    if (prevBreakAfter != null && !lockCurrentFirstDwell) {
      _curIdx = _rules.indexOf(prevBreakAfter);
      return;
    }

    // Avanza o termina
    if (_curIdx == _rules.length - 1) {
      _curIdx = _rules.length; // DONE
    } else {
      _curIdx++;
    }
  }

  // ─────────────────────────────────────────────────────────────────────
  // (D) Hint + animación
  // ─────────────────────────────────────────────────────────────────────
  _HintAnim _chooseHintAndUpdateAnimations(_EvalCtx c) {
    if (!c.faceOk) {
      _hideAnimationIfVisible();
      return const _HintAnim(_Axis.none, null);
    }
    if (_isDone) {
      _hideAnimationIfVisible();
      return const _HintAnim(_Axis.none, null);
    }
    return _currentRule.buildHint(this, c);
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
    try {
      seq.play();
    } catch (_) {}
  }

  void _hideAnimationIfVisible() {
    if (showTurnRightSeq) {
      try {
        seq.pause();
      } catch (_) {}
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
    final bool allChecksOk = c.faceOk && _isDone;

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

    // ⬇️ Fallback específico por regla actual (azimut vs. cabeza)
    final defaultMsg = _isCurrentRule('azimut')
        ? 'Mantén el torso recto'
        : 'Mantén la cabeza recta';

    _setHud(
      PortraitUiModel(
        statusLabel: 'Adjusting',
        privacyLabel: cur.privacyLabel,
        primaryMessage: faceOk
            ? (_nullIfBlank(finalHint) ?? defaultMsg)
            : 'Ubica tu rostro dentro del óvalo',
        secondaryMessage: null, // el mensaje accionable es primario
        checkFraming: faceOk ? Tri.ok : Tri.almost,
        checkHead: faceOk ? (_isDone ? Tri.ok : Tri.almost) : Tri.pending,
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

// ───────────────────────────────────────────────────────────────────────
// (F) Cinemática de ROLL (mantener compatibilidad con HUD/velocidades)
// ───────────────────────────────────────────────────────────────────────
extension _RollMathKinematics on PoseCaptureController {
  /// Actualiza cinemática de roll usando el filtro modular (unwrap + EMA + dps)
  /// y mantiene sincronizados los campos legados usados por HUD/onframe.
  _RollMetrics updateRollKinematics(double rawRollDeg, DateTime now) {
    final m = _rollFilter.update(rawRollDeg, now);

    // Mantener compatibilidad
    _rollSmoothedDeg = m.smoothedDeg;
    _rollSmoothedAt = now;
    _lastRollDps = m.dps;

    // Si el usuario se mueve demasiado durante dwell, reinicia intento
    final rollMax = _tuning.rollMaxDpsDuringDwell;
    final rule = _findRule('roll');
    if (rule != null && rule.gate.isDwell && m.dps.abs() > rollMax) {
      rule.gate.resetTransient();
    }

    // (Opcional) sincronizar _emaRollDeg si tu HUD lo muestra
    _emaRollDeg = m.smoothedDeg;

    return _RollMetrics(m.errDeg, m.dps);
  }
}
