// lib/apps/asistente_retratos/core/face_oval_geometry.dart

import 'dart:ui' show Offset, Rect, Size, Path, lerpDouble;
import 'dart:math' as math;

const double kOvalWFrac  = 0.48;
const double kOvalHFrac  = 0.42;
const double kOvalCxFrac = 0.50;
const double kOvalCyFrac = 0.41;

/// 0..1: 0 = óvalo original; 1 = círculo (misma área aproximada que el óvalo original).
///
/// Ajustá este valor para hacer el HUD más/menos circular sin tocar `kOvalWFrac`/`kOvalHFrac`.
const double kOvalCircularity = 0.2;

Rect faceOvalRectFor(Size size, {double circularity = kOvalCircularity}) {
  final ovalW0 = size.width * kOvalWFrac;
  final ovalH0 = size.height * kOvalHFrac;

  // Mezcla hacia un círculo de diámetro equivalente (misma área que la elipse base).
  final t = circularity.clamp(0.0, 1.0).toDouble();
  final circleD = math.sqrt(ovalW0 * ovalH0);
  final ovalW = lerpDouble(ovalW0, circleD, t)!;
  final ovalH = lerpDouble(ovalH0, circleD, t)!;

  final ovalCx = size.width  * kOvalCxFrac;
  final ovalCy = size.height * kOvalCyFrac;
  return Rect.fromCenter(center: Offset(ovalCx, ovalCy), width: ovalW, height: ovalH);
}

List<Offset> faceOvalPointsFor(Size size, {int samples = 120}) {
  final r = faceOvalRectFor(size);
  final rx = r.width / 2.0, ry = r.height / 2.0;
  final cx = r.center.dx,  cy = r.center.dy;
  return List.generate(samples, (i) {
    final t = (i * 2 * math.pi) / samples;
    return Offset(cx + rx * math.cos(t), cy + ry * math.sin(t));
  });
}

Path faceOvalPathFor(Size size) => Path()..addOval(faceOvalRectFor(size));
