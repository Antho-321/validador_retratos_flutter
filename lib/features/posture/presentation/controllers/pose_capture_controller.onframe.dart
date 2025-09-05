// lib/features/posture/presentation/controllers/pose_capture_controller.onframe.dart
part of 'pose_capture_controller.dart';

// ── Top-level helper types (must NOT be inside an extension) ───────────
class _EvalCtx {
  _EvalCtx({
    required this.now,
    required this.faceOk,
    required this.arcProgress,
    required this.inputs,
    required this.metrics,

    // Valores firmados (suavizados) SOLO para animaciones/HUD
    this.yawDegForAnim,
    this.pitchDegForAnim,
    this.rollDegForAnim,
  });

  final DateTime now;
  final bool faceOk;
  final double arcProgress;

  /// Frame inputs + metric registry (pluggable)
  final FrameInputs inputs;
  final MetricRegistry metrics;

  /// Valores suavizados para animaciones (no para gating)
  final double? yawDegForAnim;
  final double? pitchDegForAnim;
  final double? rollDegForAnim; // smoothed + unwrapped
}

class _HintAnim {
  const _HintAnim(this.axis, this.hint);
  final _Axis axis;
  final String? hint;
}

// Map domain GateSense → internal _GateSense
_GateSense _mapSense(GateSense s) =>
    s == GateSense.insideIsOk ? _GateSense.insideIsOk : _GateSense.outsideIsOk;

// ───────────────────────────────────────────────────────────────────────
// Helpers para “inside now” (calculados on-demand por regla)
// ───────────────────────────────────────────────────────────────────────

bool _insideNowScalar(_AxisGate g, double value) {
  final th = g.enterBand;
  final inside = g.sense == _GateSense.insideIsOk;
  return inside ? (value <= th) : (value >= th);
}

bool _insideNowSignedBand(
  _AxisGate g, {
  required double angleDeg,
  required double lo,
  required double hi,
}) {
  final dist = PoseCaptureController._signedDistanceToBand(angleDeg, lo, hi);
  return _insideNowScalar(g, dist);
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
  bool insideNowWith(double? m) {
    if (m == null) return true;
    return _insideNowScalar(gate, m);
  }
}

// ── Reglas concretas (ahora leen bandas desde el profile inyectado) ────

class _AzimutRule extends _ValidationRule {
  _AzimutRule(this.profile, _AxisGate gate)
      : super(
          id: 'azimut',
          gate: gate,
          blockInterruptionDuranteValidacion: true,
        );

  final ValidationProfile profile;

  // ✅ Métrica firmada: negativa dentro de [lo, hi], 0 en borde, positiva fuera.
  @override
  double? metric(_EvalCtx c) {
    final double? a = c.metrics.get(MetricKeys.azimutSigned, c.inputs);
    if (a == null) return null;

    final double delta = gate.hysteresis - gate.tighten;
    final double expand = (delta > 0) ? delta : 0.0;

    final double lo = (gate.firstAttemptDone
            ? (profile.azimutBand.lo - expand)
            : profile.azimutBand.lo)
        .toDouble();

    final double hi = (gate.firstAttemptDone
            ? (profile.azimutBand.hi + expand)
            : profile.azimutBand.hi)
        .toDouble();

    return PoseCaptureController._signedDistanceToBand(a, lo, hi);
  }

  @override
  _HintAnim buildHint(PoseCaptureController ctrl, _EvalCtx c) {
    // Si ya estás en dwell o “inside now”, muestra mantener
    final double? a = c.metrics.get(MetricKeys.azimutSigned, c.inputs);
    final bool insideNow = (a == null)
        ? true
        : _insideNowSignedBand(
            gate,
            angleDeg: a,
            lo: profile.azimutBand.lo.toDouble(),
            hi: profile.azimutBand.hi.toDouble(),
          );

    if (gate.isDwell || insideNow) {
      ctrl._hideAnimationIfVisible();
      return const _HintAnim(_Axis.none, 'Mantén el torso recto');
    }
    ctrl._hideAnimationIfVisible();

    if (a == null) {
      return const _HintAnim(
        _Axis.none,
        'Alinea el torso al frente (cuadra los hombros).',
      );
    }

    // Límites del estricto: [lo+tighten ; hi-tighten]
    final double strictLo = (profile.azimutBand.lo + gate.tighten).toDouble();
    final double strictHi = (profile.azimutBand.hi - gate.tighten).toDouble();

    if (!gate.firstAttemptDone) {
      // Antes de tocar el estricto:
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
      // Ya entraste en [strictLo; strictHi] ⇒ calmamos a "Mantén..."
      return const _HintAnim(_Axis.none, 'Mantén el torso recto');
    }

    // Después de tocar el estricto: usamos el band expandido para hints
    final double expand2 = (gate.hysteresis - gate.tighten);
    final double loExp =
        (profile.azimutBand.lo - (expand2 > 0 ? expand2 : 0.0)).toDouble();
    final double hiExp =
        (profile.azimutBand.hi + (expand2 > 0 ? expand2 : 0.0)).toDouble();

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
  _ShouldersRule(this.profile, _AxisGate gate)
      : super(
          id: 'shoulders',
          gate: gate,
          blockInterruptionDuranteValidacion: true,
        );

  final ValidationProfile profile;

  /// Métrica firmada: distancia a [lo, hi] (negativa dentro, 0 en borde, positiva fuera).
  @override
  double? metric(_EvalCtx c) {
    final double? s = c.metrics.get(MetricKeys.shouldersSigned, c.inputs);
    if (s == null) return null;

    final double delta = gate.hysteresis - gate.tighten;
    final double expand = (delta > 0) ? delta : 0.0;

    final double lo = (gate.firstAttemptDone
            ? (profile.shouldersBand.lo - expand)
            : profile.shouldersBand.lo)
        .toDouble();

    final double hi = (gate.firstAttemptDone
            ? (profile.shouldersBand.hi + expand)
            : profile.shouldersBand.hi)
        .toDouble();

    return PoseCaptureController._signedDistanceToBand(s, lo, hi);
  }

  @override
  _HintAnim buildHint(PoseCaptureController ctrl, _EvalCtx c) {
    final double? s = c.metrics.get(MetricKeys.shouldersSigned, c.inputs);
    final bool insideNow = (s == null)
        ? true
        : _insideNowSignedBand(
            gate,
            angleDeg: s,
            lo: profile.shouldersBand.lo.toDouble(),
            hi: profile.shouldersBand.hi.toDouble(),
          );

    if (insideNow || gate.isDwell) {
      ctrl._hideAnimationIfVisible();
      return const _HintAnim(_Axis.none, 'Mantén los hombros nivelados');
    }
    ctrl._hideAnimationIfVisible();

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
  double? metric(_EvalCtx c) => c.metrics.get(MetricKeys.yawAbs, c.inputs);

  @override
  _HintAnim buildHint(PoseCaptureController ctrl, _EvalCtx c) {
    final yawAbs = metric(c);
    final insideNow = insideNowWith(yawAbs);

    if (insideNow || gate.isDwell || c.yawDegForAnim == null) {
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
  double? metric(_EvalCtx c) => c.metrics.get(MetricKeys.pitchAbs, c.inputs);

  @override
  _HintAnim buildHint(PoseCaptureController ctrl, _EvalCtx c) {
    final pitchAbs = metric(c);
    final insideNow = insideNowWith(pitchAbs);

    if (insideNow || gate.isDwell || c.pitchDegForAnim == null) {
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
  double? metric(_EvalCtx c) =>
      c.metrics.get(MetricKeys.rollErr, c.inputs); // distancia a 180°

  @override
  _HintAnim buildHint(PoseCaptureController ctrl, _EvalCtx c) {
    final rollErr = metric(c);
    final insideNow = insideNowWith(rollErr);

    if (insideNow || gate.isDwell || c.rollDegForAnim == null) {
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
    final hint = ccwForUser
        ? 'Rota ligeramente tu cabeza en sentido horario ⟳'
        : 'Rota ligeramente tu cabeza en sentido antihorario ⟲';
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
      _hideAnimationIfVisible(); 
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
    final _HintAnim ha = _chooseHintAndUpdateAnimations(ctx);

    // 4) HUD + countdown
    _updateHudAndCountdown(ctx, ha);
  }

  // ─────────────────────────────────────────────────────────────────────
  // Estado/registro de reglas
  // ─────────────────────────────────────────────────────────────────────
  List<_ValidationRule> get _rules {
    final got = _rulesExp[this];
    if (got != null) return got;

    // Usa el perfil inyectado para construir gates y reglas
    final p = profile;

    final list = <_ValidationRule>[
      // AZIMUT
      _AzimutRule(
        p,
        _AxisGate(
          baseDeadband: p.azimutGate.baseDeadband,
          sense: _mapSense(p.azimutGate.sense),
          tighten: p.azimutGate.tighten,
          hysteresis: p.azimutGate.hysteresis,
          dwell: p.azimutGate.dwell,
          extraRelaxAfterFirst: p.azimutGate.extraRelaxAfterFirst,
        ),
      ),

      // SHOULDERS
      _ShouldersRule(
        p,
        _AxisGate(
          baseDeadband: p.shouldersGate.baseDeadband,
          sense: _mapSense(p.shouldersGate.sense),
          tighten: p.shouldersGate.tighten,
          hysteresis: p.shouldersGate.hysteresis,
          dwell: p.shouldersGate.dwell,
          extraRelaxAfterFirst: p.shouldersGate.extraRelaxAfterFirst,
        ),
      ),

      _YawRule(
        _AxisGate(
          baseDeadband: p.yaw.baseDeadband,
          sense: _mapSense(p.yaw.sense),
          tighten: p.yaw.tighten,
          hysteresis: p.yaw.hysteresis,
          dwell: p.yaw.dwell,
          extraRelaxAfterFirst: p.yaw.extraRelaxAfterFirst,
        ),
      ),

      _PitchRule(
        _AxisGate(
          baseDeadband: p.pitch.baseDeadband,
          sense: _mapSense(p.pitch.sense),
          tighten: p.pitch.tighten,
          hysteresis: p.pitch.hysteresis,
          dwell: p.pitch.dwell,
          extraRelaxAfterFirst: p.pitch.extraRelaxAfterFirst,
        ),
      ),

      _RollRule(
        _AxisGate(
          baseDeadband: p.roll.baseDeadband,
          sense: _mapSense(p.roll.sense),
          tighten: p.roll.tighten,
          hysteresis: p.roll.hysteresis,
          dwell: p.roll.dwell,
          extraRelaxAfterFirst: p.roll.extraRelaxAfterFirst,
        ),
      ),
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
  // (B) Evaluate current frame → build FrameInputs + HUD anim metrics
  // ─────────────────────────────────────────────────────────────────────
  _EvalCtx? _evaluateCurrentFrame(dynamic frame) {
    final faces = poseService.latestFaceLandmarks;
    final canvas = _canvasSize;
    final pose = poseService.latestPoseLandmarks; // image-space points
    final lms3d = poseService.latestPoseLandmarks3D; // List<PosePoint>?
    if (faces == null || faces.isEmpty || canvas == null) return null;

    final now = DateTime.now();

    // Mapea PosePoint → records ({x,y,z}) para cumplir FrameInputs
    final lms3dRec = lms3d?.map((p) => (x: p.x.toDouble(), y: p.y.toDouble(), z: (p.z ?? 0.0).toDouble())).toList();

    // Construye Inputs UNA sola vez para este frame
    final inputs = FrameInputs(
      now: now,
      landmarksImg: faces.first,
      poseLandmarksImg: pose,
      poseLandmarks3D: lms3dRec,
      imageSize: frame.imageSize,
      canvasSize: canvas,
      mirror: mirror,
      fit: BoxFit.cover,
    );

    // Limpia el registry (lazy cache por frame)
    _metricRegistry.clear();

    // Gates actuales (para pasar deadbands al validador HUD y suavizados)
    final yawGateNow = _findRule('yaw')!.gate;
    final pitchGateNow = _findRule('pitch')!.gate;
    final rollGateNow = _findRule('roll')!.gate;
    final shouldersGateNow = _findRule('shoulders')!.gate;

    final double yawDeadbandNow = yawGateNow.enterBand;
    final double pitchDeadbandNow = pitchGateNow.enterBand;
    final double rollDeadbandNow = rollGateNow.enterBand;

    // SHOULDERS: tolerancia SIMÉTRICA para el validador (para progreso/ok visual).
    final p = profile;
    final double shouldersExpandNow =
        math.max(0.0, shouldersGateNow.hysteresis - shouldersGateNow.tighten);
    final double loDepth = p.shouldersBand.lo.abs().toDouble();
    final double hiDepth = p.shouldersBand.hi.abs().toDouble();
    double shouldersTolSymNow = math.min(loDepth, hiDepth);
    if (shouldersGateNow.firstAttemptDone) {
      shouldersTolSymNow += shouldersExpandNow;
    }

    // Ejecuta el validador SOLO para HUD/animaciones (no para gating)
    final report = _validator.evaluate(
      landmarksImg: inputs.landmarksImg!, // ya comprobado arriba
      imageSize: inputs.imageSize,
      canvasSize: inputs.canvasSize,
      mirror: inputs.mirror,
      fit: inputs.fit,

      // Face-in-oval
      minFractionInside: p.face.minFractionInside,
      eps: p.face.eps,

      // Yaw
      enableYaw: true,
      yawDeadbandDeg: yawDeadbandNow,
      yawMaxOffDeg: p.yaw.maxOffDeg,

      // Pitch
      enablePitch: true,
      pitchDeadbandDeg: pitchDeadbandNow,
      pitchMaxOffDeg: p.pitch.maxOffDeg,

      // Roll
      enableRoll: true,
      rollDeadbandDeg: rollDeadbandNow,
      rollMaxOffDeg: p.roll.maxOffDeg,

      // Shoulders (nivelación)
      poseLandmarksImg: inputs.poseLandmarksImg,
      enableShoulders: true,
      shouldersDeadbandDeg: shouldersTolSymNow, // ← dinámico simétrico para UI
      shouldersMaxOffDeg: p.shouldersGate.maxOffDeg,
    );

    final bool faceOk = report.faceInOval;
    final double arcProgress = report.ovalProgress;

    // EMA para yaw/pitch (solo para animaciones)
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
    updateRollKinematics(report.rollDeg, now); // _emaRollDeg se sincroniza adentro

    // Devuelve contexto mínimo: inputs + registry + flags de HUD
    return _EvalCtx(
      now: now,
      faceOk: faceOk,
      arcProgress: arcProgress,
      inputs: inputs,
      metrics: _metricRegistry,
      yawDegForAnim: _emaYawDeg,
      pitchDegForAnim: _emaPitchDeg,
      rollDegForAnim: _emaRollDeg, // smoothed/unwrapped
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
        current.blockInterruptionDuranteValidacion &&
            !current.gate.hasConfirmedOnce;

    // Backtracking condicional: no si está en dwell ni si bloquea interrupción (primer dwell)
    final allowBacktrack = !current.gate.isDwell && !lockCurrentFirstDwell;
    if (allowBacktrack) {
      final prevBreak =
          _firstPrevNotHoldingFiltered(_curIdx, c, current);
      if (prevBreak != null) {
        _curIdx = _rules.indexOf(prevBreak);
        return;
      }
    }

    // Actualiza/Confirma el gate de la regla actual
    final m = current.metric(c);
    final confirmed =
        c.faceOk && (m != null) && current.gate.update(m, c.now);
    if (!confirmed) return;

    // Revisa rupturas previas tras confirmar (si aún aplica el lock del primer dwell, no retrocedas)
    final prevBreakAfter =
        _firstPrevNotHoldingFiltered(_curIdx, c, current);
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
    final bool wantCcwForUser =
        mirror ? (deltaTo180 < 0) : (deltaTo180 > 0);

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

    // global stability window (no extra hold; gates ya hacen dwell)
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
        _pushHudAdjusting(
            faceOk: c.faceOk,
            arcProgress: c.arcProgress,
            finalHint: ha.hint);
      }
    }

    if (!isCountingDown &&
        allChecksOk &&
        _readySince != null &&
        c.now.difference(_readySince!) >=
            PoseCaptureController._readyHold) {
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
    final defaultMsg =
        _isCurrentRule('azimut') ? 'Mantén el torso recto' : 'Mantén la cabeza recta';

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
  _RollMetrics updateRollKinematics(double rawRollDeg, DateTime now) {
    final m = _rollFilter.update(rawRollDeg, now);

    // Mantener compatibilidad
    _rollSmoothedDeg = m.smoothedDeg;
    _rollSmoothedAt = now;
    _lastRollDps = m.dps;

    // Usa el límite desde el ValidationProfile → UiTuning
    final rollMax = profile.ui.rollMaxDpsDuringDwell;
    final rule = _findRule('roll');
    if (rule != null && rule.gate.isDwell && m.dps.abs() > rollMax) {
      rule.gate.resetTransient();
    }

    // (Opcional) sincronizar _emaRollDeg si tu HUD lo muestra
    _emaRollDeg = m.smoothedDeg;

    return _RollMetrics(m.errDeg, m.dps);
  }
}
