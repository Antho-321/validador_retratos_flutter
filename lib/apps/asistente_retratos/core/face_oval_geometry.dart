import 'dart:ui' show Offset, Rect, Size, Path;
import 'dart:math' as math;

const double kOvalWFrac  = 0.56;
const double kOvalHFrac  = 0.42;
const double kOvalCxFrac = 0.50;
const double kOvalCyFrac = 0.41;

Rect faceOvalRectFor(Size size) {
  final ovalW = size.width  * kOvalWFrac;
  final ovalH = size.height * kOvalHFrac;
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
