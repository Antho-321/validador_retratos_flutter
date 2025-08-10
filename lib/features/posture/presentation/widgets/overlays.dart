// lib/features/posture/presentation/widgets/overlays.dart
import 'package:flutter/material.dart';

class CircularMaskPainter extends CustomPainter {
  const CircularMaskPainter({required this.circleCenter, required this.circleRadius});
  final Offset circleCenter;
  final double circleRadius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.black.withOpacity(0.5);
    final full = Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    final hole = Path()..addOval(Rect.fromCircle(center: circleCenter, radius: circleRadius));
    final mask = Path.combine(PathOperation.difference, full, hole);
    canvas.drawPath(mask, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}

class TopShade extends StatelessWidget {
  const TopShade({super.key});
  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: Container(
          height: 140,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xCC000000), Colors.transparent],
            ),
          ),
        ),
      );
}

class ProgressRing extends StatelessWidget {
  const ProgressRing({super.key, required this.value, required this.color});
  final double value;
  final Color color;
  @override
  Widget build(BuildContext context) => SizedBox(
        width: 80,
        height: 80,
        child: Stack(
          alignment: Alignment.center,
          children: [
            CircularProgressIndicator(
              value: value,
              strokeWidth: 6,
              backgroundColor: Colors.white24,
              valueColor: AlwaysStoppedAnimation(color),
            ),
            Text(
              '${(value * 100).round()}%',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      );
}

class SkeletonPainter extends CustomPainter {
  SkeletonPainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;

    final pts = <Offset>[
      Offset(0.3, 0.55),
      Offset(0.7, 0.55),
      Offset(0.5, 0.35),
      Offset(0.5, 0.8),
    ].map((p) => Offset(p.dx * size.width, p.dy * size.height)).toList();

    canvas
      ..drawLine(pts[0], pts[1], paint)
      ..drawLine(pts[2], pts[0], paint)
      ..drawLine(pts[2], pts[1], paint)
      ..drawLine(pts[2], pts[3], paint);

    for (final p in pts) {
      canvas.drawCircle(p, 6, paint..color = color);
      paint.color = Colors.white;
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}
