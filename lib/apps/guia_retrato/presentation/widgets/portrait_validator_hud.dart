import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'dart:math' as math;

import '../../core/face_oval_geometry.dart'
  show faceOvalRectFor, faceOvalPointsFor, faceOvalPathFor;

/// Trata cadenas vacías como null para no reservar espacio visual.
String? _nullIfBlank(String? s) => (s == null || s.trim().isEmpty) ? null : s;

/// Verde de éxito del proyecto (coincide con otros componentes).
const Color kProgressGreen = Color(0xFF4DC274);

/// ─────────────────────────────────────────────────────────────────────
/// Modelo UI simplificado: solo lo que sí se muestra en pantalla.
/// ─────────────────────────────────────────────────────────────────────
class PortraitUiModel {
  const PortraitUiModel({
    this.primaryMessage = 'Ubica tu rostro dentro del óvalo',
    this.secondaryMessage,
    this.countdownSeconds,
    this.countdownProgress,
    this.ovalProgress,
  });

  final String primaryMessage;
  final String? secondaryMessage;

  /// Visibles si ambos son no-null.
  final int? countdownSeconds;     // 3,2,1,0
  final double? countdownProgress; // 1→0

  /// 0..1 de perímetro del óvalo en verde.
  final double? ovalProgress;

  PortraitUiModel copyWith({
    String? primaryMessage,
    String? secondaryMessage,
    int? countdownSeconds,
    double? countdownProgress,
    double? ovalProgress,
  }) {
    return PortraitUiModel(
      primaryMessage: primaryMessage ?? this.primaryMessage,
      secondaryMessage: secondaryMessage ?? this.secondaryMessage,
      countdownSeconds: countdownSeconds ?? this.countdownSeconds,
      countdownProgress: countdownProgress ?? this.countdownProgress,
      ovalProgress: ovalProgress ?? this.ovalProgress,
    );
  }
}

/// Controlador simple (sin cambios conceptuales).
class PortraitUiController extends ValueNotifier<PortraitUiModel> {
  PortraitUiController([PortraitUiModel? initial])
      : super(initial ?? const PortraitUiModel());
}

/// Widget principal de HUD (chips/checklist eliminados).
class PortraitValidatorHUD extends StatelessWidget {
  const PortraitValidatorHUD({
    super.key,
    required this.modelListenable,

    // Los siguientes se dejan por compatibilidad pero NO se usan:
    this.mirror = true,
    this.fit = BoxFit.cover,
    this.showGhost = true,
    this.showSafeBox = true,
    this.showChecklist = false, // ← DEPRECATED/IGNORED

    this.belowMessages,
    this.messageGap = 0.0125,
    this.keepAboveCountdownRing = true,

    // NEW: permite personalizar el rect del óvalo
    Rect Function(Size size)? ovalRectFor,
  }) : ovalRectFor = ovalRectFor ?? faceOvalRectFor;

  final ValueListenable<PortraitUiModel> modelListenable;

  // Compat: parámetros ignorados (no romper llamadas existentes).
  final bool mirror;         // unused
  final BoxFit fit;          // unused
  final bool showGhost;      // lo usamos igual para ghost on/off
  final bool showSafeBox;    // idem
  final bool showChecklist;  // deprecated/ignored

  final Widget? belowMessages;
  final double messageGap;
  final bool keepAboveCountdownRing;

  // NEW
  final Rect Function(Size size) ovalRectFor;

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.of(context).size;
    final safe = MediaQuery.of(context).padding;

    // Métricas del anillo de cuenta regresiva
    const ringSize = 92.0;
    const ringBottom = 16.0;

    return ValueListenableBuilder<PortraitUiModel>(
      valueListenable: modelListenable,
      builder: (context, model, _) {
        final Rect ovalRect = ovalRectFor(screen); // NEW
        final double gapPx =
            screen.height * messageGap.clamp(0.0, 1.0).toDouble();

        final desiredTop = ovalRect.bottom + gapPx; // usa el rect personalizado
        final ringTop = screen.height - (ringBottom + safe.bottom + ringSize);
        final messagesTop = keepAboveCountdownRing
            ? math.min(desiredTop, ringTop - 8)
            : desiredTop;

        return Stack(
          children: [
            // 1) Ghost target (óvalo y caja segura)
            Positioned.fill(
              child: CustomPaint(
                painter: _GhostPainter(
                  ovalRect: ovalRect,           // NEW
                  color: Colors.white,
                  opacity: 0.85,
                  strokeWidth: 2.0,
                  showGhost: showGhost,
                  showSafeBox: showSafeBox,
                  shadeOutsideOval: true,
                  shadeOpacity: 0.30,
                  progress: ((model.ovalProgress ?? 0).clamp(0.0, 1.0)).toDouble(),
                ),
              ),
            ),

            // 2) Mensajes (anclados bajo el óvalo)
            Positioned(
              left: 12,
              right: 12,
              top: messagesTop,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _GuidancePill(
                    primary: model.primaryMessage,
                    secondary: model.secondaryMessage,
                  ),
                  if (belowMessages != null) ...[
                    const SizedBox(height: 8),
                    Center(child: belowMessages!),
                  ],
                ],
              ),
            ),

            // 3) Anillo de cuenta regresiva (opcional)
            if (model.countdownSeconds != null && model.countdownProgress != null)
              Positioned(
                bottom: ringBottom + safe.bottom,
                left: 0,
                right: 0,
                child: Center(
                  child: _CountdownRing(
                    seconds: model.countdownSeconds!,
                    progress: model.countdownProgress!.clamp(0.0, 1.0),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Pintor del óvalo/área segura
class _GhostPainter extends CustomPainter {
  _GhostPainter({
    required this.ovalRect,        // NEW
    required this.color,
    required this.opacity,
    required this.strokeWidth,
    required this.showGhost,
    this.showSafeBox = true,
    this.shadeOutsideOval = true,
    this.shadeOpacity = 0.30,
    this.progress = 0.0,
  });

  final Rect ovalRect;            // NEW
  final Color color;
  final double opacity;
  final double strokeWidth;
  final bool showGhost;

  final bool showSafeBox;
  final bool shadeOutsideOval;
  final double shadeOpacity;
  final double progress; // 0..1

  @override
  void paint(Canvas canvas, Size size) {
    if (!showGhost) return;

    if (shadeOutsideOval) {
      final mask = Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(Offset.zero & size)
        ..addOval(ovalRect);
      final maskPaint = Paint()..color = Colors.black.withOpacity(shadeOpacity);
      canvas.drawPath(mask, maskPaint);
    }

    final base = Paint()
      ..color = color.withOpacity(opacity)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..isAntiAlias = true;

    canvas.drawOval(ovalRect, base);

    final p = progress.clamp(0.0, 1.0);
    if (p > 0) {
      final arcPaint = Paint()
        ..color = kProgressGreen
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth + 3
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true;

      const startAngle = -math.pi / 2;
      final sweepAngle = p * 2 * math.pi;
      canvas.drawArc(ovalRect, startAngle, sweepAngle, false, arcPaint);
    }

    if (showSafeBox) {
      final safeRect = Rect.fromLTWH(
        size.width * 0.08,
        size.height * 0.16,
        size.width * 0.84,
        size.height * 0.64,
      );
      final r = const Radius.circular(16);
      final rr = RRect.fromRectAndCorners(
        safeRect,
        topLeft: r, topRight: r, bottomLeft: r, bottomRight: r,
      );
      canvas.drawRRect(rr, base..strokeWidth = strokeWidth);
    }
  }

  @override
  bool shouldRepaint(covariant _GhostPainter old) =>
      old.ovalRect != ovalRect || // NEW
      old.opacity != opacity ||
      old.strokeWidth != strokeWidth ||
      old.color != color ||
      old.showGhost != showGhost ||
      old.showSafeBox != showSafeBox ||
      old.shadeOutsideOval != shadeOutsideOval ||
      old.shadeOpacity != shadeOpacity ||
      old.progress != progress;
}

/// Pastilla de guía (principal + opcional secundaria)
class _GuidancePill extends StatelessWidget {
  const _GuidancePill({required this.primary, this.secondary});

  final String primary;
  final String? secondary;

  @override
  Widget build(BuildContext context) {
    final String? secondaryText = _nullIfBlank(secondary);

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      child: Container(
        key: ValueKey<String>(primary + (secondaryText ?? '')),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFFFFF1B8),
          borderRadius: BorderRadius.circular(16),
          boxShadow: const [
            BoxShadow(color: Colors.black26, blurRadius: 8, offset: Offset(0, 4))
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(mainAxisSize: MainAxisSize.min, children: const [
              Icon(Icons.north_east_rounded, color: Colors.black87, size: 18),
              SizedBox(width: 8),
            ]),
            Text(
              primary,
              style: const TextStyle(
                color: Colors.black87, fontSize: 16, fontWeight: FontWeight.w700),
            ),
            if (secondaryText != null) ...[
              const SizedBox(height: 6),
              Text(
                secondaryText,
                style: const TextStyle(
                    color: Colors.black87, fontSize: 13, fontWeight: FontWeight.w500),
              ),
            ]
          ],
        ),
      ),
    );
  }
}

/// Anillo de cuenta regresiva
class _CountdownRing extends StatelessWidget {
  const _CountdownRing({required this.seconds, required this.progress});

  final int seconds;
  final double progress;

  @override
  Widget build(BuildContext context) {
    const double size = 92;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox(
            width: size,
            height: size,
            child: const CircularProgressIndicator(
              value: 1.0,
              strokeWidth: 6,
              backgroundColor: Colors.white24,
              valueColor: AlwaysStoppedAnimation<Color>(Colors.white24),
            ),
          ),
          SizedBox(
            width: size,
            height: size,
            child: CircularProgressIndicator(
              value: progress,
              strokeWidth: 6,
              valueColor: const AlwaysStoppedAnimation<Color>(kProgressGreen),
              backgroundColor: Colors.transparent,
            ),
          ),
          Text(
            '$seconds',
            style: const TextStyle(
              fontSize: 28, fontWeight: FontWeight.w700, color: Colors.white),
          ),
        ],
      ),
    );
  }
}
