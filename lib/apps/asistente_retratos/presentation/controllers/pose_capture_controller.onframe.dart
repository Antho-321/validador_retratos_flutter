// lib/apps/asistente_retratos/presentation/controllers/pose_capture_controller.onframe.dart
part of 'pose_capture_controller.dart';

void _poseCtrlLog(String message) {
  if (kDebugMode) {
    debugPrint('[PoseCapture] $message');
  }
}

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

// Mensajes estáticos de “mantener” por regla
const Map<String, String> _maintainById = <String, String>{
  'azimut': 'Mantén el torso recto',
  'shoulders': 'Mantén los hombros nivelados',
  // default → “Mantén la cabeza recta”
};

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

// Helper común: en este modelo, el dwell siempre ocurre en band ampliado.
extension on _ValidationRule {
  bool get _showMaintainNow => gate.isDwell;
}

// ───────────────────────────────────────────────────────────────────────
// Versión simplificada: reglas basadas en closures
// ───────────────────────────────────────────────────────────────────────

class _ClosureRule extends _ValidationRule {
  _ClosureRule({
    required String id,
    required _AxisGate gate,
    required double? Function(_EvalCtx) metric,
    required _HintAnim Function(PoseCaptureController, _EvalCtx, bool) hint,
    Set<String> ignorePrevBreakOf = const {},
    bool blockInterruptionDuranteValidacion = false,
  })  : _metric = metric,
        _hint = hint,
        super(
          id: id,
          gate: gate,
          ignorePrevBreakOf: ignorePrevBreakOf,
          blockInterruptionDuranteValidacion: blockInterruptionDuranteValidacion,
        );

  final double? Function(_EvalCtx) _metric;
  final _HintAnim Function(PoseCaptureController, _EvalCtx, bool) _hint;

  @override
  double? metric(_EvalCtx c) => _metric(c);

  @override
  _HintAnim buildHint(PoseCaptureController ctrl, _EvalCtx c) =>
      _hint(ctrl, c, _showMaintainNow);
}

// ── Common metric helpers used by closures ─────────────────────────────

_AxisGate _gateFrom(dynamic g) => _AxisGate(
      baseDeadband: g.baseDeadband,
      sense: _mapSense(g.sense),
      tighten: g.tighten,
      hysteresis: g.hysteresis,
      dwell: g.dwell,
      extraRelaxAfterFirst: g.extraRelaxAfterFirst,
    );

double _metricSignedBand(
  double value,
  _AxisGate gate,
  double lo0,
  double hi0,
) {
  final double expand =
      (gate.hysteresis - gate.tighten).clamp(0.0, double.infinity);
  final double lo = gate.firstAttemptDone ? (lo0 - expand) : lo0;
  final double hi = gate.firstAttemptDone ? (hi0 + expand) : hi0;
  return PoseCaptureController._signedDistanceToBand(value, lo, hi);
}

// ── Rule builders (state captured in closures) ─────────────────────────

// AZIMUT
_ValidationRule makeAzimutRule(ValidationProfile p) {
  var lastDir = _TurnDir.right; // estado capturado

  final gate = _gateFrom(p.azimutGate);
  return _ClosureRule(
    id: 'azimut',
    gate: gate,
    blockInterruptionDuranteValidacion: true,
    metric: (c) {
      final double? a = c.metrics.get<double>(MetricKeys.azimutSigned, c.inputs);
      if (a == null) return null;
      return _metricSignedBand(
        a,
        gate,
        p.azimutBand.lo.toDouble(),
        p.azimutBand.hi.toDouble(),
      );
    },
    hint: (ctrl, c, maintain) {
      if (maintain) {
        ctrl._hideAnimationIfVisible();
        return const _HintAnim(_Axis.none, 'Mantén el torso recto');
      }

      // Mantener guía direccional hasta dwell (con deadzone y último lado)
      final a = c.metrics.get<double>(MetricKeys.azimutSigned, c.inputs);
      if (a != null) {
        final center = (p.azimutBand.lo + p.azimutBand.hi) / 2.0;
        if ((a - center).abs() > p.ui.azimutHintDeadzoneDeg) {
          lastDir = (a < center) ? _TurnDir.left : _TurnDir.right;
        }
      }

      ctrl._hideAnimationIfVisible(); // azimut no usa animación de frames
      final txt = (lastDir == _TurnDir.left)
          ? 'Gira ligeramente el torso moviendo el hombro izquierdo hacia atrás'
          : 'Gira ligeramente el torso moviendo el hombro derecho hacia atrás';
      return _HintAnim(_Axis.none, txt);
    },
  );
}

// SHOULDERS
_ValidationRule makeShouldersRule(ValidationProfile p) {
  var lastSign = 1; // 1 ⇒ baja der/sube izq; -1 ⇒ baja izq/sube der

  final gate = _gateFrom(p.shouldersGate);
  return _ClosureRule(
    id: 'shoulders',
    gate: gate,
    blockInterruptionDuranteValidacion: true,
    metric: (c) {
      final double? sv =
          c.metrics.get<double>(MetricKeys.shouldersSigned, c.inputs);
      if (sv == null) return null;
      return _metricSignedBand(
        sv,
        gate,
        p.shouldersBand.lo.toDouble(),
        p.shouldersBand.hi.toDouble(),
      );
    },
    hint: (ctrl, c, maintain) {
      if (maintain) {
        ctrl._hideAnimationIfVisible();
        return const _HintAnim(_Axis.none, 'Mantén los hombros nivelados');
      }

      final sv = c.metrics.get<double>(MetricKeys.shouldersSigned, c.inputs);
      if (sv != null && sv.abs() > p.ui.shouldersHintDeadzoneDeg) {
        lastSign = sv > 0 ? 1 : -1;
      }

      ctrl._hideAnimationIfVisible();
      final txt = (lastSign > 0)
          ? 'Baja un poco el hombro derecho o sube el izquierdo'
          : 'Baja un poco el hombro izquierdo o sube el derecho';
      return _HintAnim(_Axis.none, txt);
    },
  );
}

// Genérico para YAW / PITCH (mismo patrón, distintos assets/textos)
_ValidationRule makeHeadRule({
  required String id,
  required _Axis axis,
  required dynamic gateCfg, // p.yaw / p.pitch
  required MetricKey key, // MetricKeys.yawAbs / pitchAbs
  required double? Function(_EvalCtx) animAngle, // c.yawDegForAnim / pitch
  required double Function(dynamic ui) deadzoneOf, // (ui) => ui.yawHintDeadzoneDeg
  required void Function(PoseCaptureController, double) drive, // _driveYawAnimation/_drivePitchAnimation
  required String Function(double a) hintText, // texto según signo
}) {
  final gate = _gateFrom(gateCfg);
  return _ClosureRule(
    id: id,
    gate: gate,
    ignorePrevBreakOf: const {'azimut', 'shoulders'},
    blockInterruptionDuranteValidacion: true, // ⬅️ ACTIVADO
    metric: (c) => c.metrics.get<double>(key, c.inputs),
    hint: (ctrl, c, maintain) {
      if (maintain) {
        ctrl._hideAnimationIfVisible();
        return const _HintAnim(_Axis.none, 'Mantén la cabeza recta');
      }
      final a = animAngle(c);
      if (a != null && a.abs() > deadzoneOf(ctrl.profile.ui)) {
        drive(ctrl, a);
        return _HintAnim(axis, hintText(a));
      }
      ctrl._hideAnimationIfVisible();
      return _HintAnim(axis, null);
    },
  );
}

// ROLL (lógica especial con delta a 180°)
_ValidationRule makeRollRule(ValidationProfile p) {
  final gate = _gateFrom(p.roll);
  return _ClosureRule(
    id: 'roll',
    gate: gate,
    ignorePrevBreakOf: const {'azimut', 'shoulders'},
    blockInterruptionDuranteValidacion: true, // ⬅️ ACTIVADO
    metric: (c) => c.metrics.get<double>(MetricKeys.rollErr, c.inputs),
    hint: (ctrl, c, maintain) {
      if (maintain) {
        ctrl._hideAnimationIfVisible();
        return const _HintAnim(_Axis.none, 'Mantén la cabeza recta');
      }

      final a = c.rollDegForAnim;
      if (a != null) {
        final delta = ctrl._deltaToNearest180(a);
        if (delta.abs() > p.ui.rollHintDeadzoneDeg) {
          ctrl._driveRollAnimation(delta);
          final cwForUser = ctrl.mirror ? (delta < 0) : (delta > 0);
          final txt = cwForUser
              ? 'Rota ligeramente tu cabeza en sentido horario ⟳'
              : 'Rota ligeramente tu cabeza en sentido antihorario ⟲';
          return _HintAnim(_Axis.roll, txt);
        }
      }

      // Sin señal suficiente → opcional: nada o recordar último estado
      ctrl._hideAnimationIfVisible();
      return const _HintAnim(_Axis.roll, null);
    },
  );
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
        _setHud(
          const PortraitUiModel(
            primaryMessage: 'Vista previa (validaciones OFF)',
            secondaryMessage: null,
            countdownSeconds: null,
            countdownProgress: null,
            ovalProgress: 0.0,
          ),
          force: true,
        );
      } else {
        if (isCountingDown) _stopCountdown(); // no auto-countdown en modo OFF
        _setHud(
          const PortraitUiModel(
            primaryMessage: 'Validaciones desactivadas',
            secondaryMessage: null,
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

    // Yaw / Pitch por helper genérico
    final yawRule = makeHeadRule(
      id: 'yaw',
      axis: _Axis.yaw,
      gateCfg: p.yaw,
      key: MetricKeys.yawAbs,
      animAngle: (c) => c.yawDegForAnim,
      deadzoneOf: (ui) => ui.yawHintDeadzoneDeg,
      drive: (ctrl, a) => ctrl._driveYawAnimation(a),
      hintText: (a) =>
          (a > 0) ? 'Gira ligeramente la cabeza a la izquierda' : 'Gira ligeramente la cabeza a la derecha',
    );

    final pitchRule = makeHeadRule(
      id: 'pitch',
      axis: _Axis.pitch,
      gateCfg: p.pitch,
      key: MetricKeys.pitchAbs,
      animAngle: (c) => c.pitchDegForAnim,
      deadzoneOf: (ui) => ui.pitchHintDeadzoneDeg,
      drive: (ctrl, a) => ctrl._drivePitchAnimation(a),
      hintText: (a) =>
          (a > 0) ? 'Sube ligeramente la cabeza' : 'Baja ligeramente la cabeza',
    );

    final list = <_ValidationRule>[
      makeAzimutRule(p),
      makeShouldersRule(p),
      yawRule,
      pitchRule,
      makeRollRule(p),
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

  // Helper para saber si una regla es la actual
  bool _isCurrentRule(String id) => !_isDone && _currentRule.id == id;

  // ─────────────────────────────────────────────────────────────────────
  // (A) Face lost: reset everything consistently
  // ─────────────────────────────────────────────────────────────────────
  void _handleFaceLost() {
    _stopCountdown(); // from mixin

    _setHud(
      const PortraitUiModel(
        primaryMessage: 'Ubica tu rostro dentro del óvalo',
        secondaryMessage: null,
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
    if (canvas == null) {
      _poseCtrlLog('Skipping frame: canvas size not ready yet');
      return null;
    }
    if (faces == null || faces.isEmpty) {
      final poseCount = pose?.length ?? 0;
      _poseCtrlLog(
          'Skipping frame: no face landmarks (poseLandmarks=$poseCount)');
      return null;
    }

    final now = DateTime.now();

    // Mapea PosePoint → records ({x,y,z}) para cumplir FrameInputs
    final lms3dRec = lms3d
        ?.map((p) => (x: p.x.toDouble(), y: p.y.toDouble(), z: (p.z ?? 0.0).toDouble()))
        .toList();

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

    // ⬇️ NUEVO: azimut 3D para HUD/progreso (si hay 3D)
    double? azDegHUD;
    if (lms3dRec != null) {
      final double zToPx = _zToPxScale ?? inputs.imageSize.width; // mismo fallback
      azDegHUD = geom.estimateAzimutBiacromial3D(
        poseLandmarks3D: lms3dRec,
        zToPx: zToPx,
        mirror: inputs.mirror,
      );
    }

    // Limpia el registry (lazy cache por frame)
    _metricRegistry.clear();

    // Gates actuales (para pasar deadbands al validador HUD y suavizados)
    final yawGateNow = _findRule('yaw')!.gate;
    final pitchGateNow = _findRule('pitch')!.gate;
    final rollGateNow = _findRule('roll')!.gate;
    final shouldersGateNow = _findRule('shoulders')!.gate;
    final azimutGateNow = _findRule('azimut')!.gate; // ⬅️ NUEVO

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

    // ⬇️ NUEVO: banda dinámica para azimut (relajar tras primer intento)
    final double azExpandNow =
        math.max(0.0, azimutGateNow.hysteresis - azimutGateNow.tighten);
    double azLoNow = p.azimutBand.lo.toDouble();
    double azHiNow = p.azimutBand.hi.toDouble();
    if (azimutGateNow.firstAttemptDone) {
      azLoNow -= azExpandNow;
      azHiNow += azExpandNow;
    }

    // ⬇️ progresos del anillo contextuales a la regla ACTUAL
    final bool doneNow = _isDone;
    final String? curId = doneNow ? null : _currentRule.id;

    final bool uiEnableHead  = !doneNow && (curId == 'yaw' || curId == 'pitch' || curId == 'roll');
    final bool uiEnableYaw   = uiEnableHead;
    final bool uiEnablePitch = uiEnableHead;
    final bool uiEnableRoll  = uiEnableHead;

    final bool uiEnableShoulders = !doneNow && (curId == 'shoulders');
    final bool uiEnableAzimut    = !doneNow && (curId == 'azimut') && (azDegHUD != null);

    // Ejecuta el validador SOLO para HUD/animaciones (no para gating)
    final report = _validator.evaluate(
      faceLandmarksImg: inputs.landmarksImg!, // ya comprobado arriba
      imageSize: inputs.imageSize,
      canvasSize: inputs.canvasSize,
      mirror: inputs.mirror,
      fit: inputs.fit,

      // Face-in-oval
      minFractionInside: p.face.minFractionInside,
      eps: p.face.eps,

      // Yaw/Pitch/Roll (solo si la etapa actual es de cabeza)
      enableYaw: uiEnableYaw,
      yawDeadbandDeg: yawDeadbandNow,
      yawMaxOffDeg: p.yaw.maxOffDeg,

      enablePitch: uiEnablePitch,
      pitchDeadbandDeg: pitchDeadbandNow,
      pitchMaxOffDeg: p.pitch.maxOffDeg,

      enableRoll: uiEnableRoll,
      rollDeadbandDeg: rollDeadbandNow,
      rollMaxOffDeg: p.roll.maxOffDeg,

      // Shoulders (solo cuando corresponde)
      poseLandmarksImg: inputs.poseLandmarksImg,
      enableShoulders: uiEnableShoulders,
      shouldersDeadbandDeg: shouldersTolSymNow, // dinámico simétrico para UI
      shouldersMaxOffDeg: p.shouldersGate.maxOffDeg,

      // Azimut (solo cuando corresponde y hay 3D)
      enableAzimut: uiEnableAzimut,
      azimutDeg: azDegHUD,
      azimutBandLo: azLoNow,
      azimutBandHi: azHiNow,
      azimutMaxOffDeg: p.azimutGate.maxOffDeg,
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

    final double rawYaw = report.yawDeg;
    final double rawPitch = report.pitchDeg;
    final double rawRoll = report.rollDeg;

    _emaYawDeg = (_emaYawDeg == null)
        ? rawYaw
        : (a * rawYaw + (1 - a) * _emaYawDeg!);
    _emaPitchDeg = (_emaPitchDeg == null)
        ? rawPitch
        : (a * rawPitch + (1 - a) * _emaPitchDeg!);
    _lastSampleAt = now;

    // Roll kinematics (unwrap + EMA + dps + error-to-180°)
    final _RollMetrics rollMetrics = updateRollKinematics(rawRoll, now);

    if (pose == null || pose.isEmpty) {
      _poseCtrlLog(
          'Frame ${now.millisecondsSinceEpoch}: pose landmarks missing; relying on face only');
    }

    _poseCtrlLog(
      'Frame ${now.millisecondsSinceEpoch}: Δt=${dtMs.toStringAsFixed(1)}ms, '
      'faceOk=$faceOk, arc=${arcProgress.toStringAsFixed(2)}, '
      'yaw=${rawYaw.toStringAsFixed(2)}→${_emaYawDeg?.toStringAsFixed(2)}, '
      'pitch=${rawPitch.toStringAsFixed(2)}→${_emaPitchDeg?.toStringAsFixed(2)}, '
      'roll=${rawRoll.toStringAsFixed(2)}→${_emaRollDeg?.toStringAsFixed(2)}, '
      'rollDps=${rollMetrics.dps.toStringAsFixed(1)}, '
      'pose2D=${pose?.length ?? 0}, pose3D=${lms3dRec?.length ?? 0}',
    );

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

    // Bloquear retroceso durante el primer dwell si la regla lo pide
    final bool lockCurrentFirstDwell =
        current.blockInterruptionDuranteValidacion &&
            !current.gate.hasConfirmedOnce;

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

  // ⚠️ Requiere que la clase PoseCaptureController tenga:
  //     _Axis _animAxis = _Axis.none;
  // para llevar el “eje activo” del overlay.

  void _driveYawAnimation(double yawDeg) {
    final desiredTurn = (yawDeg > 0) ? _TurnDir.left : _TurnDir.right;
    _activePitchUp = null;
    _activeRollPositive = null;

    final bool switchingAxis = _animAxis != _Axis.yaw;
    if (switchingAxis) _hideAnimationIfVisible(); // forzar blank antes de cambiar de eje

    if (desiredTurn != _activeTurn || switchingAxis) {
      _activeTurn = desiredTurn;
      if (desiredTurn == _TurnDir.right) {
        _turnRightSeqLoaded = true;
        // ignore: discarded_futures
        seq
            .loadFromAssets(
              directory: 'assets/frames',
              pattern: 'frame_%04d.png',
              startNumber: 14,
              count: 22,
              xStart: 0,
              xEnd: 256,
            )
            .then((_) {
          _animAxis = _Axis.yaw;
          _ensureAnimVisible();
        });
      } else {
        _turnLeftSeqLoaded = true;
        // ignore: discarded_futures
        seq
            .loadFromAssets(
              directory: 'assets/frames',
              pattern: 'frame_%04d.png',
              startNumber: 30,
              count: 21,
              xStart: 0,
              xEnd: 256,
              reverseOrder: true,
            )
            .then((_) {
          _animAxis = _Axis.yaw;
          _ensureAnimVisible();
        });
      }
    } else {
      _ensureAnimVisible();
    }
  }

  void _drivePitchAnimation(double pitchDeg) {
    final bool desiredPitchUp = pitchDeg > 0;
    _activeTurn = _TurnDir.none;
    _activeRollPositive = null;

    final bool switchingAxis = _animAxis != _Axis.pitch;
    if (switchingAxis) _hideAnimationIfVisible(); // forzar blank antes de cambiar de eje

    if (_activePitchUp != desiredPitchUp || switchingAxis) {
      _activePitchUp = desiredPitchUp;
      if (desiredPitchUp) {
        // ignore: discarded_futures
        seq
            .loadFromAssets(
              directory: 'assets/frames',
              pattern: 'frame_%04d.png',
              startNumber: 30,
              count: 21,
              xStart: 256,
              xEnd: 512,
              reverseOrder: true,
            )
            .then((_) {
          _animAxis = _Axis.pitch;
          _ensureAnimVisible();
        });
      } else {
        // ignore: discarded_futures
        seq
            .loadFromAssets(
              directory: 'assets/frames',
              pattern: 'frame_%04d.png',
              startNumber: 14,
              count: 22,
              xStart: 256,
              xEnd: 512,
            )
            .then((_) {
          _animAxis = _Axis.pitch;
          _ensureAnimVisible();
        });
      }
    } else {
      _ensureAnimVisible();
    }
  }

  void _driveRollAnimation(double deltaTo180) {
    // Map delta to user-perceived rotation with mirror
    final bool wantCcwForUser = mirror ? (deltaTo180 < 0) : (deltaTo180 > 0);

    _activeTurn = _TurnDir.none;

    final bool switchingAxis = _animAxis != _Axis.roll;
    if (switchingAxis) _hideAnimationIfVisible(); // forzar blank antes de cambiar de eje

    // reuse _activeRollPositive to track “CCW-for-user”
    if (_activeRollPositive != wantCcwForUser || switchingAxis) {
      _activeRollPositive = wantCcwForUser;

      if (wantCcwForUser) {
        // CCW
        // ignore: discarded_futures
        seq
            .loadFromAssets(
              directory: 'assets/frames',
              pattern: 'frame_%04d.png',
              startNumber: 30,
              count: 21,
              xStart: 512,
              xEnd: 768,
              reverseOrder: true,
            )
            .then((_) {
          _animAxis = _Axis.roll;
          _ensureAnimVisible();
        });
      } else {
        // CW
        // ignore: discarded_futures
        seq
            .loadFromAssets(
              directory: 'assets/frames',
              pattern: 'frame_%04d.png',
              startNumber: 14,
              count: 22,
              xStart: 512,
              xEnd: 768,
            )
            .then((_) {
          _animAxis = _Axis.roll;
          _ensureAnimVisible();
        });
      }
    } else {
      _ensureAnimVisible();
    }
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
    _animAxis = _Axis.none; // ⇐ clave: limpiar eje activo al ocultar
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
          finalHint: ha.hint,
        );
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
    _setHud(
      PortraitUiModel(
        primaryMessage: '¡Perfecto! ¡Permanece así!',
        secondaryMessage: null,
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
    final bool maintainNow = !_isDone && _currentRule._showMaintainNow;

    final String maintainMsg = !_isDone
        ? (_maintainById[_currentRule.id] ?? 'Mantén la cabeza recta')
        : 'Mantén la cabeza recta';

    // Forzamos a String (no null). Usa '' para “no mostrar nada”.
    final String effectiveMsg = faceOk
        ? (_nullIfBlank(finalHint) ??
            (maintainNow ? maintainMsg : '')) // nunca null
        : 'Ubica tu rostro dentro del óvalo';

    _setHud(
      PortraitUiModel(
        primaryMessage: effectiveMsg,
        secondaryMessage: null,
        countdownSeconds: null,
        countdownProgress: null,
        ovalProgress: arcProgress,
      ),
    );
  }
}

// ───────────────────────────────────────────────────────────────────────
/* (F) Cinemática de ROLL (mantener compatibilidad con HUD/velocidades) */
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
