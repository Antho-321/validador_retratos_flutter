// lib/apps/asistente_retratos/presentation/widgets/portrait_validator_hud.dart
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
  show ValueListenable, ValueNotifier, listEquals;
import 'dart:math' as math;

import '../../core/face_oval_geometry.dart'
  show faceOvalRectFor, faceOvalPointsFor, faceOvalPathFor;
import '../styles/colors.dart' show CaptureTheme, AppColors; // ⬅️ paleta específica de la app

/// Trata cadenas vacías como null para no reservar espacio visual.
String? _nullIfBlank(String? s) => (s == null || s.trim().isEmpty) ? null : s;

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
    this.ovalSegmentsOk,
  });

  final String primaryMessage;
  final String? secondaryMessage;

  /// Visibles si ambos son no-null.
  final int? countdownSeconds;     // 3,2,1,0
  final double? countdownProgress; // 1→0

  /// 0..1 de perímetro del óvalo en verde.
  final double? ovalProgress;

  /// Si viene, el perímetro del óvalo se pinta por segmentos:
  /// `true` = verde (zona OK), `false` = rojo (zona fuera).
  final List<bool>? ovalSegmentsOk;

  PortraitUiModel copyWith({
    String? primaryMessage,
    String? secondaryMessage,
    int? countdownSeconds,
    double? countdownProgress,
    double? ovalProgress,
    List<bool>? ovalSegmentsOk,
  }) {
    return PortraitUiModel(
      primaryMessage: primaryMessage ?? this.primaryMessage,
      secondaryMessage: secondaryMessage ?? this.secondaryMessage,
      countdownSeconds: countdownSeconds ?? this.countdownSeconds,
      countdownProgress: countdownProgress ?? this.countdownProgress,
      ovalProgress: ovalProgress ?? this.ovalProgress,
      ovalSegmentsOk: ovalSegmentsOk ?? this.ovalSegmentsOk,
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

        // Override local del scheme para que onSurface sea negro (ink)
        final base = Theme.of(context);
        final hudTheme = base.copyWith(
          colorScheme: base.colorScheme.copyWith(
            onSurface: AppColors.ink, // negro de tu paleta, aplicado vía scheme
          ),
        );

        return Theme(
          data: hudTheme,
          child: Builder(
            builder: (context) {
              // A partir de aquí, Theme.of(context).colorScheme.onSurface == negro
              final scheme   = Theme.of(context).colorScheme;
              final capture  = Theme.of(context).extension<CaptureTheme>();

              return Stack(
                children: [
                  // 1) Ghost target (óvalo y caja segura)
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _GhostPainter(
                        ovalRect: ovalRect,           // NEW
                        // Trazo del óvalo/caja desde la paleta:
                        badColor: scheme.primary,
                        opacity: 0.85,
                        strokeWidth: 2.0,
                        showGhost: showGhost,
                        showSafeBox: showSafeBox,
                        shadeOutsideOval: true,
                        // Sombra exterior usando scrim del tema
                        shadeOpacity: 0.30,
                        scrimColor: scheme.scrim,
                        // Progreso en color HUD OK de la paleta (o secondary)
                        okColor: capture?.hudOk ?? scheme.secondary,
                        progressColor: capture?.hudOk ?? scheme.secondary,
                        progress: ((model.ovalProgress ?? 0).clamp(0.0, 1.0)).toDouble(),
                        ovalSegmentsOk: model.ovalSegmentsOk,
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
          ),
        );
      },
    );
  }
}

/// Pintor del óvalo/área segura
class _GhostPainter extends CustomPainter {
  _GhostPainter({
    required this.ovalRect,        // NEW
    required this.badColor,
    required this.okColor,
    required this.opacity,
    required this.strokeWidth,
    required this.showGhost,
    this.showSafeBox = true,
    this.shadeOutsideOval = true,
    this.shadeOpacity = 0.30,
    this.progress = 0.0,
    this.scrimColor = const Color(0xFF000000), // ⬅️ por defecto negro
    this.progressColor = const Color(0xFF53B056), // ⬅️ fallback verde
    this.ovalSegmentsOk,
  });

  final Rect ovalRect;            // NEW
  final Color badColor;
  final Color okColor;
  final double opacity;
  final double strokeWidth;
  final bool showGhost;

  final bool showSafeBox;
  final bool shadeOutsideOval;
  final double shadeOpacity;
  final double progress; // 0..1

  // NUEVO: colores desde el tema (con fallback)
  final Color scrimColor;
  final Color progressColor;

  /// Segmentos del óvalo: `true` = verde, `false` = rojo.
  final List<bool>? ovalSegmentsOk;

  @override
  void paint(Canvas canvas, Size size) {
    if (!showGhost) return;

    if (shadeOutsideOval) {
      final mask = Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(Offset.zero & size)
        ..addOval(ovalRect);
      final maskPaint = Paint()..color = scrimColor.withOpacity(shadeOpacity);
      canvas.drawPath(mask, maskPaint);
    }

    final badPaint = Paint()
      ..color = badColor.withOpacity(opacity)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..isAntiAlias = true;

    // Base: óvalo completo en ROJO.
    canvas.drawOval(ovalRect, badPaint);

    // Overlay: pinta en VERDE los segmentos "OK".
    final segs = ovalSegmentsOk;
    if (segs != null && segs.isNotEmpty) {
      final okPaint = Paint()
        ..color = okColor.withOpacity(opacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth + 1
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true;

      final n = segs.length;
      final sweepPer = (2 * math.pi) / n;

      final firstBad = segs.indexWhere((e) => e == false);
      if (firstBad == -1) {
        // Todo OK -> óvalo completo verde.
        canvas.drawArc(ovalRect, -math.pi, 2 * math.pi, false, okPaint);
      } else {
        // Para manejar el wrap (fin+inicio) sin partir arcos, arrancamos justo
        // después del primer segmento rojo.
        final startBase = (firstBad + 1) % n;
        int k = 0;
        while (k < n) {
          final idx = (startBase + k) % n;
          if (!segs[idx]) {
            k++;
            continue;
          }

          final runStartK = k;
          while (k < n && segs[(startBase + k) % n]) {
            k++;
          }
          final runLen = k - runStartK;
          final runStartIdx = (startBase + runStartK) % n;

          final startAngle = -math.pi + runStartIdx * sweepPer;
          final sweep = runLen * sweepPer;
          canvas.drawArc(ovalRect, startAngle, sweep, false, okPaint);
        }
      }
    }

    // Progreso (otras validaciones): arco verde por ovalProgress.
    final p = progress.clamp(0.0, 1.0);
    if (p > 0) {
      final arcPaint = Paint()
        ..color = progressColor
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
      canvas.drawRRect(rr, badPaint..strokeWidth = strokeWidth);
    }
  }

  @override
  bool shouldRepaint(covariant _GhostPainter old) =>
      old.ovalRect != ovalRect || // NEW
      old.opacity != opacity ||
      old.strokeWidth != strokeWidth ||
      old.badColor != badColor ||
      old.okColor != okColor ||
      old.showGhost != showGhost ||
      old.showSafeBox != showSafeBox ||
      old.shadeOutsideOval != shadeOutsideOval ||
      old.shadeOpacity != shadeOpacity ||
      old.progress != progress ||
      old.scrimColor != scrimColor ||
      old.progressColor != progressColor ||
      !listEquals(old.ovalSegmentsOk, ovalSegmentsOk);
}

/// Pastilla de guía (principal + opcional secundaria)
class _GuidancePill extends StatelessWidget {
  const _GuidancePill({required this.primary, this.secondary});

  final String primary;
  final String? secondary;

  @override
  Widget build(BuildContext context) {
    final String? secondaryText = _nullIfBlank(secondary);
    final scheme = Theme.of(context).colorScheme;

    // Fondo y sombras desde la paleta
    final pillBg = scheme.surfaceContainerHigh; // requiere Material 3
    final shadow = Theme.of(context).shadowColor.withOpacity(0.26);

    // Texto/ícono sobre el contenedor
    final onPill = scheme.onSurface;

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      child: Container(
        key: ValueKey<String>(primary + (secondaryText ?? '')),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: pillBg,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [BoxShadow(color: shadow, blurRadius: 8, offset: const Offset(0, 4))],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.north_east_rounded, color: onPill, size: 18),
              const SizedBox(width: 8),
            ]),
            Text(
              primary,
              style: TextStyle(
                color: onPill, fontSize: 16, fontWeight: FontWeight.w700),
            ),
            if (secondaryText != null) ...[
              const SizedBox(height: 6),
              Text(
                secondaryText,
                style: TextStyle(
                  color: onPill, fontSize: 13, fontWeight: FontWeight.w500),
              ),
            ]
          ],
        ),
      ),
    );
  }
}

/// Anillo de cuenta regresiva (usa blanco desde paleta + verde de paleta)
class _CountdownRing extends StatelessWidget {
  const _CountdownRing({required this.seconds, required this.progress});

  final int seconds;
  final double progress;

  @override
  Widget build(BuildContext context) {
    const double size = 92;

    // 1) Pista de fondo: BLANCO de la paleta con 24% de opacidad
    final Color bgTrack = AppColors.white.withOpacity(0.24);

    // 2) Arco activo: verde de la paleta (si hay override en CaptureTheme, respétalo)
    final capture = Theme.of(context).extension<CaptureTheme>();
    final Color active = capture?.hudOk ?? AppColors.green;

    // 3) Texto central: BLANCO de la paleta
    final Color textColor = AppColors.white;

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox(
            width: size,
            height: size,
            child: CircularProgressIndicator(
              value: 1.0,
              strokeWidth: 6,
              backgroundColor: bgTrack,
              valueColor: AlwaysStoppedAnimation<Color>(bgTrack),
            ),
          ),
          SizedBox(
            width: size,
            height: size,
            child: CircularProgressIndicator(
              value: progress,
              strokeWidth: 6,
              valueColor: AlwaysStoppedAnimation<Color>(active),
              backgroundColor: Colors.transparent,
            ),
          ),
          Text(
            '$seconds',
            style: TextStyle(
              fontSize: 28, fontWeight: FontWeight.w700, color: textColor),
          ),
        ],
      ),
    );
  }
}
