// lib/apps/asistente_retratos/domain/validators/portrait_validations.dart
import 'dart:math' as math;

import '../metrics/pose_geometry.dart' as geom;
import '../metrics/metrics.dart';
import '../../core/face_oval_geometry.dart' show faceOvalRectFor;

/// Result type reused for yaw/pitch/roll checks.
class AngleCheck {
  final bool ok;
  final double progress; // 0..1
  final double offDeg; // exceso sobre el deadband
  const AngleCheck({required this.ok, required this.progress, required this.offDeg});
}

/// Generic angle validator used for yaw/pitch/roll.
/// - If [enabled] is false -> ok=true, progress=1.0, off=0.
/// - If |deg| <= deadband   -> ok=true, progress=1.0, off=0.
/// - Otherwise              -> ok=false, progress decae linealmente hasta 0 en [maxOffDeg].
AngleCheck checkAngle({
  required bool enabled,
  required double deg, // ángulo firmado (p.ej., yaw/pitch/roll)
  required double deadbandDeg, // tolerancia
  required double maxOffDeg, // cuánto exceso consideras “100% mal”
}) {
  if (!enabled) return const AngleCheck(ok: true, progress: 1.0, offDeg: 0.0);

  final abs = deg.abs();
  if (abs <= deadbandDeg) {
    return const AngleCheck(ok: true, progress: 1.0, offDeg: 0.0);
  }
  final off = (abs - deadbandDeg).clamp(0.0, maxOffDeg).toDouble();
  final progress = (1.0 - (off / maxOffDeg)).clamp(0.0, 1.0).toDouble();
  return AngleCheck(ok: false, progress: progress, offDeg: off);
}

/// Result para validar pertenencia a un rango [lo, hi] con progreso.
class BandCheck {
  final bool ok;
  final double progress; // 0..1
  final double offDeg; // exceso respecto al borde más cercano
  const BandCheck({required this.ok, required this.progress, required this.offDeg});
}

/// Progreso lineal: 1.0 dentro del rango; fuera decae a 0 con maxOffDeg.
BandCheck checkBand({
  required bool enabled,
  required double value,
  required double lo,
  required double hi,
  required double maxOffDeg,
}) {
  if (!enabled) return const BandCheck(ok: true, progress: 1.0, offDeg: 0.0);
  if (value >= lo && value <= hi) {
    return const BandCheck(ok: true, progress: 1.0, offDeg: 0.0);
  }
  final d = (value < lo) ? (lo - value) : (value - hi); // distancia al borde
  final off = d.clamp(0.0, maxOffDeg).toDouble();
  final progress = (1.0 - (off / maxOffDeg)).clamp(0.0, 1.0).toDouble();
  return BandCheck(ok: false, progress: progress, offDeg: off);
}

/// Identificadores comunes de reglas para el reporte/resultados.
class PortraitRuleIds {
  static const face = 'face';
  static const yaw = 'yaw';
  static const pitch = 'pitch';
  static const roll = 'roll';
  static const shoulders = 'shoulders';
  static const azimut = 'azimut';
}

/// Contexto inmutable para evaluar un conjunto de reglas.
/// Agrupa los parámetros usados anteriormente por `PortraitValidator.evaluate`.
class PortraitValidationContext {
  const PortraitValidationContext({
    required this.inputs,
    required this.metrics,
    this.minFractionInside = 1.0,
    this.eps = 1e-6,
    this.enableYaw = true,
    this.yawDeadbandDeg = 2.0,
    this.yawMaxOffDeg = 20.0,
    this.enablePitch = true,
    this.pitchDeadbandDeg = 2.0,
    this.pitchMaxOffDeg = 20.0,
    this.enableRoll = true,
    this.rollDeadbandDeg = 175,
    this.rollMaxOffDeg = 100.0,
    this.enableShoulders = false,
    this.shouldersDeadbandDeg = 5.0,
    this.shouldersMaxOffDeg = 20.0,
    this.enableAzimut = false,
    this.azimutDeg,
    this.azimutBandLo = 0.0,
    this.azimutBandHi = 0.0,
    this.azimutMaxOffDeg = 20.0,
    this.faceResult,
  });

  final FrameInputs inputs;
  final MetricRegistry metrics;

  // Face-in-oval params
  final double minFractionInside;
  final double eps;

  // Head rules
  final bool enableYaw;
  final double yawDeadbandDeg;
  final double yawMaxOffDeg;
  final bool enablePitch;
  final double pitchDeadbandDeg;
  final double pitchMaxOffDeg;
  final bool enableRoll;
  final double rollDeadbandDeg;
  final double rollMaxOffDeg;

  // Shoulders
  final bool enableShoulders;
  final double shouldersDeadbandDeg;
  final double shouldersMaxOffDeg;

  // Azimut
  final bool enableAzimut;
  final double? azimutDeg;
  final double azimutBandLo;
  final double azimutBandHi;
  final double azimutMaxOffDeg;

  final RuleResult? faceResult;

  PortraitValidationContext copyWithFaceResult(RuleResult? result) {
    return PortraitValidationContext(
      inputs: inputs,
      metrics: metrics,
      minFractionInside: minFractionInside,
      eps: eps,
      enableYaw: enableYaw,
      yawDeadbandDeg: yawDeadbandDeg,
      yawMaxOffDeg: yawMaxOffDeg,
      enablePitch: enablePitch,
      pitchDeadbandDeg: pitchDeadbandDeg,
      pitchMaxOffDeg: pitchMaxOffDeg,
      enableRoll: enableRoll,
      rollDeadbandDeg: rollDeadbandDeg,
      rollMaxOffDeg: rollMaxOffDeg,
      enableShoulders: enableShoulders,
      shouldersDeadbandDeg: shouldersDeadbandDeg,
      shouldersMaxOffDeg: shouldersMaxOffDeg,
      enableAzimut: enableAzimut,
      azimutDeg: azimutDeg,
      azimutBandLo: azimutBandLo,
      azimutBandHi: azimutBandHi,
      azimutMaxOffDeg: azimutMaxOffDeg,
      faceResult: result,
    );
  }

  bool get hasValidFrameGeometry {
    final face = inputs.landmarksImg;
    return face != null &&
        face.isNotEmpty &&
        inputs.imageSize.width > 0 &&
        inputs.imageSize.height > 0 &&
        inputs.canvasSize.width > 0 &&
        inputs.canvasSize.height > 0;
  }

  bool get faceInsideOval => faceResult?.ok ?? false;
  double get fractionInsideOval => faceResult?.value ?? 0.0;
}

/// Resultado de una regla individual.
class RuleResult {
  const RuleResult({
    required this.enabled,
    required this.ok,
    required this.progress,
    this.value,
    this.offDeg,
    this.extra = const {},
  });

  factory RuleResult.disabled({double value = 0.0}) =>
      RuleResult(enabled: false, ok: true, progress: 1.0, value: value);

  final bool enabled;
  final bool ok;
  final double progress;
  final double? value;
  final double? offDeg;
  final Map<String, Object?> extra;

  double get valueAsDouble => (value ?? 0.0).toDouble();
}

/// Contrato para reglas de validación de retratos.
abstract class PortraitRule {
  const PortraitRule();

  String get id;

  RuleResult evaluate(PortraitValidationContext context);
}

/// Implementación base para reglas simples basadas en closures.
class SimplePortraitRule extends PortraitRule {
  const SimplePortraitRule({required this.id, required RuleResult Function(PortraitValidationContext) evaluate})
      : _evaluate = evaluate;

  @override
  final String id;
  final RuleResult Function(PortraitValidationContext) _evaluate;

  @override
  RuleResult evaluate(PortraitValidationContext context) => _evaluate(context);
}

/// Report of all portrait checks (expand as you add rules).
class PortraitValidationReport {
  const PortraitValidationReport({
    required Map<String, RuleResult> results,
    required this.ovalProgress,
    required this.allChecksOk,
  }) : _results = results;

  factory PortraitValidationReport.empty() => const PortraitValidationReport(
        results: {},
        ovalProgress: 0.0,
        allChecksOk: false,
      );

  final Map<String, RuleResult> _results;
  final double ovalProgress;
  final bool allChecksOk;

  RuleResult? _result(String id) => _results[id];

  Map<String, RuleResult> get results => Map.unmodifiable(_results);

  bool get faceInOval => _result(PortraitRuleIds.face)?.ok ?? false;
  double get fractionInsideOval => _result(PortraitRuleIds.face)?.valueAsDouble ?? 0.0;

  bool get yawOk => _result(PortraitRuleIds.yaw)?.ok ?? false;
  double get yawDeg => _result(PortraitRuleIds.yaw)?.valueAsDouble ?? 0.0;
  double get yawProgress => _result(PortraitRuleIds.yaw)?.progress ?? 0.0;

  bool get pitchOk => _result(PortraitRuleIds.pitch)?.ok ?? false;
  double get pitchDeg => _result(PortraitRuleIds.pitch)?.valueAsDouble ?? 0.0;
  double get pitchProgress => _result(PortraitRuleIds.pitch)?.progress ?? 0.0;

  bool get rollOk => _result(PortraitRuleIds.roll)?.ok ?? false;
  double get rollDeg => _result(PortraitRuleIds.roll)?.valueAsDouble ?? 0.0;
  double get rollProgress => _result(PortraitRuleIds.roll)?.progress ?? 0.0;

  bool get shouldersOk => _result(PortraitRuleIds.shoulders)?.ok ?? false;
  double get shouldersDeg => _result(PortraitRuleIds.shoulders)?.valueAsDouble ?? 0.0;
  double get shouldersProgress => _result(PortraitRuleIds.shoulders)?.progress ?? 0.0;

  bool get azimutOk => _result(PortraitRuleIds.azimut)?.ok ?? false;
  double get azimutDeg => _result(PortraitRuleIds.azimut)?.valueAsDouble ?? 0.0;
  double get azimutProgress => _result(PortraitRuleIds.azimut)?.progress ?? 0.0;
}

/// Stateless validator you can keep as a field (e.g., `const PortraitValidator()`).
class PortraitValidator {
  const PortraitValidator({required List<PortraitRule> rules}) : _rules = rules;

  final List<PortraitRule> _rules;

  PortraitValidationReport evaluate(PortraitValidationContext context) {
    if (!context.hasValidFrameGeometry) {
      return PortraitValidationReport.empty();
    }

    final results = <String, RuleResult>{};
    PortraitRule? faceRule;
    final otherRules = <PortraitRule>[];

    for (final rule in _rules) {
      if (rule.id == PortraitRuleIds.face && faceRule == null) {
        faceRule = rule;
      } else {
        otherRules.add(rule);
      }
    }

    RuleResult? faceResult;
    if (faceRule != null) {
      faceResult = faceRule.evaluate(context);
      results[faceRule.id] = faceResult;
    }

    for (final rule in otherRules) {
      final ctx = context.copyWithFaceResult(faceResult);
      final result = rule.evaluate(ctx);
      results[rule.id] = result;
    }

    final faceOk = faceResult?.ok ?? false;
    final faceProgress = faceResult?.progress ?? 0.0;

    double combinedProgress = 1.0;
    final parts = <double>[];
    results.forEach((id, res) {
      if (!res.enabled) return;
      if (id == PortraitRuleIds.face) return;
      parts.add(res.progress);
    });
    if (parts.isNotEmpty) {
      combinedProgress = parts.reduce(math.min);
    }
    final ringProgress = faceOk ? combinedProgress : faceProgress;

    final allOk = results.entries
        .where((e) => e.value.enabled)
        .every((e) => e.value.ok);

    return PortraitValidationReport(
      results: results,
      ovalProgress: ringProgress,
      allChecksOk: allOk && faceOk,
    );
  }
}

/// Reglas por defecto utilizadas por el HUD y las métricas.
const List<PortraitRule> defaultPortraitRules = <PortraitRule>[
  FaceInOvalRule(),
  YawRule(),
  PitchRule(),
  RollRule(),
  ShouldersRule(),
  AzimutRule(),
];

class FaceInOvalRule extends PortraitRule {
  const FaceInOvalRule();

  @override
  String get id => PortraitRuleIds.face;

  @override
  RuleResult evaluate(PortraitValidationContext context) {
    final lms = context.inputs.landmarksImg!;
    final mapped = geom.mapImagePointsToCanvas(
      points: lms,
      imageSize: context.inputs.imageSize,
      canvasSize: context.inputs.canvasSize,
      mirror: context.inputs.mirror,
      fit: context.inputs.fit,
    );

    final oval = faceOvalRectFor(context.inputs.canvasSize);
    final rx = oval.width / 2.0;
    final ry = oval.height / 2.0;
    final cx = oval.center.dx;
    final cy = oval.center.dy;
    final rx2 = rx * rx;
    final ry2 = ry * ry;

    int inside = 0;
    for (final p in mapped) {
      final dx = p.dx - cx;
      final dy = p.dy - cy;
      final v = (dx * dx) / (rx2 + context.eps) + (dy * dy) / (ry2 + context.eps);
      if (v <= 1.0 + context.eps) inside++;
    }
    final fracInside = inside / mapped.length;
    final faceOk = fracInside >= context.minFractionInside.clamp(0.0, 1.0);

    return RuleResult(
      enabled: true,
      ok: faceOk,
      progress: fracInside,
      value: fracInside,
      extra: {'fractionInside': fracInside},
    );
  }
}

class YawRule extends PortraitRule {
  const YawRule();

  @override
  String get id => PortraitRuleIds.yaw;

  @override
  RuleResult evaluate(PortraitValidationContext context) {
    if (!context.enableYaw) {
      return RuleResult.disabled();
    }
    if (!context.faceInsideOval) {
      return const RuleResult(enabled: true, ok: false, progress: 0.0, value: 0.0);
    }

    final yaw = context.metrics.get<double>(MetricKeys.yawSigned, context.inputs);
    if (yaw == null || yaw.isNaN) {
      return const RuleResult(enabled: true, ok: false, progress: 0.0, value: 0.0);
    }
    final res = checkAngle(
      enabled: true,
      deg: yaw,
      deadbandDeg: context.yawDeadbandDeg,
      maxOffDeg: context.yawMaxOffDeg,
    );
    return RuleResult(
      enabled: true,
      ok: res.ok,
      progress: res.progress,
      value: yaw,
      offDeg: res.offDeg,
    );
  }
}

class PitchRule extends PortraitRule {
  const PitchRule();

  @override
  String get id => PortraitRuleIds.pitch;

  @override
  RuleResult evaluate(PortraitValidationContext context) {
    if (!context.enablePitch) {
      return RuleResult.disabled();
    }
    if (!context.faceInsideOval) {
      return const RuleResult(enabled: true, ok: false, progress: 0.0, value: 0.0);
    }

    final pitch = context.metrics.get<double>(MetricKeys.pitchSigned, context.inputs);
    if (pitch == null || pitch.isNaN) {
      return const RuleResult(enabled: true, ok: false, progress: 0.0, value: 0.0);
    }
    final res = checkAngle(
      enabled: true,
      deg: pitch,
      deadbandDeg: context.pitchDeadbandDeg,
      maxOffDeg: context.pitchMaxOffDeg,
    );
    return RuleResult(
      enabled: true,
      ok: res.ok,
      progress: res.progress,
      value: pitch,
      offDeg: res.offDeg,
    );
  }
}

class RollRule extends PortraitRule {
  const RollRule();

  @override
  String get id => PortraitRuleIds.roll;

  @override
  RuleResult evaluate(PortraitValidationContext context) {
    if (!context.enableRoll) {
      return RuleResult.disabled();
    }
    if (!context.faceInsideOval) {
      return const RuleResult(enabled: true, ok: false, progress: 0.0, value: 0.0);
    }

    final roll = context.metrics.get<double>(MetricKeys.rollSigned, context.inputs);
    if (roll == null || roll.isNaN) {
      return const RuleResult(enabled: true, ok: false, progress: 0.0, value: 0.0);
    }

    final absRoll = roll.abs();
    if (absRoll >= context.rollDeadbandDeg) {
      return RuleResult(enabled: true, ok: true, progress: 1.0, value: roll);
    }
    final progress = (absRoll / context.rollDeadbandDeg).clamp(0.0, 1.0);
    return RuleResult(
      enabled: true,
      ok: false,
      progress: progress,
      value: roll,
      offDeg: context.rollDeadbandDeg - absRoll,
    );
  }
}

class ShouldersRule extends PortraitRule {
  const ShouldersRule();

  @override
  String get id => PortraitRuleIds.shoulders;

  @override
  RuleResult evaluate(PortraitValidationContext context) {
    if (!context.enableShoulders) {
      return RuleResult.disabled();
    }
    if (!context.faceInsideOval || context.inputs.poseLandmarksImg == null) {
      return const RuleResult(enabled: true, ok: false, progress: 0.0, value: 0.0);
    }

    final shoulders =
        context.metrics.get<double>(MetricKeys.shouldersSigned, context.inputs);
    if (shoulders == null || shoulders.isNaN) {
      return const RuleResult(enabled: true, ok: false, progress: 0.0, value: 0.0);
    }
    final normalized = _normalizeTilt90(shoulders);
    final res = checkAngle(
      enabled: true,
      deg: normalized,
      deadbandDeg: context.shouldersDeadbandDeg,
      maxOffDeg: context.shouldersMaxOffDeg,
    );
    return RuleResult(
      enabled: true,
      ok: res.ok,
      progress: res.progress,
      value: normalized,
      offDeg: res.offDeg,
    );
  }
}

class AzimutRule extends PortraitRule {
  const AzimutRule();

  @override
  String get id => PortraitRuleIds.azimut;

  @override
  RuleResult evaluate(PortraitValidationContext context) {
    if (!context.enableAzimut) {
      return RuleResult.disabled();
    }
    if (!context.faceInsideOval) {
      return const RuleResult(enabled: true, ok: false, progress: 0.0, value: 0.0);
    }

    final double? azimut = context.azimutDeg ??
        context.metrics.get<double>(MetricKeys.azimutSigned, context.inputs);
    if (azimut == null || azimut.isNaN) {
      return const RuleResult(enabled: true, ok: false, progress: 0.0, value: 0.0);
    }
    final res = checkBand(
      enabled: true,
      value: azimut,
      lo: context.azimutBandLo,
      hi: context.azimutBandHi,
      maxOffDeg: context.azimutMaxOffDeg,
    );
    return RuleResult(
      enabled: true,
      ok: res.ok,
      progress: res.progress,
      value: azimut,
      offDeg: res.offDeg,
    );
  }
}

double _normalizeTilt90(double a) {
  double x = a;
  if (x > 90.0) x -= 180.0;
  if (x <= -90.0) x += 180.0;
  return x; // (-90..90]
}
