// lib/features/posture/presentation/widgets/portrait_validator_hud.dart
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'dart:math' as math; // ← for arc sweep & min()

import '../../core/face_oval_geometry.dart'
  show faceOvalRectFor, faceOvalPointsFor, faceOvalPathFor;

/// Treat empty/whitespace strings as null so the HUD won't render extra space.
String? _nullIfBlank(String? s) => (s == null || s.trim().isEmpty) ? null : s;

/// App-specific success green (replaces Colors.greenAccent*)
const Color kProgressGreen = Color(0xFF4DC274);

/// ─────────────────────────────────────────────────────────────────────────
/// Centralized: edit this set to hide chip labels (case/spacing-insensitive)
const Set<String> kHiddenStatusLabels = {'Adjusting', 'Ready', 'On-device'}; // add 'Searching' if desired

bool isHiddenChipLabel(String label) {
  final s = label.trim().toLowerCase();
  return kHiddenStatusLabels.any((t) => s.contains(t.trim().toLowerCase()));
}
/// ─────────────────────────────────────────────────────────────────────────

/// Simple tri-state for checklist items.
enum Tri { pending, almost, ok }

/// UI model for the portrait validator HUD.
class PortraitUiModel {
  const PortraitUiModel({
    this.statusLabel = 'Adjusting',
    this.privacyLabel = 'On-device',
    this.primaryMessage = 'Centra tu rostro en el óvalo',
    this.secondaryMessage,
    this.countdownSeconds, // null => hidden; e.g., 3, 2, 1, 0
    this.countdownProgress, // 0..1 (1 = just started, 0 = fire). If null => hidden
    this.checkFraming = Tri.pending,
    this.checkHead = Tri.pending,
    this.checkEyes = Tri.pending,
    this.checkLighting = Tri.pending,
    this.checkBackground = Tri.pending,
    this.ovalProgress, // 0..1 fraction of the oval perimeter to draw in green
  });

  final String statusLabel;   // e.g., Adjusting / Ready
  final String privacyLabel;  // e.g., On-device / Online
  final String primaryMessage;
  final String? secondaryMessage;

  /// Visible if both [countdownSeconds] and [countdownProgress] are non-null.
  final int? countdownSeconds;
  final double? countdownProgress;

  final Tri checkFraming;
  final Tri checkHead;
  final Tri checkEyes;
  final Tri checkLighting;
  final Tri checkBackground;

  /// 0..1 proportion of the oval to paint in green (e.g., 0.6 for 60%).
  final double? ovalProgress;

  PortraitUiModel copyWith({
    String? statusLabel,
    String? privacyLabel,
    String? primaryMessage,
    String? secondaryMessage,
    int? countdownSeconds,
    double? countdownProgress,
    Tri? checkFraming,
    Tri? checkHead,
    Tri? checkEyes,
    Tri? checkLighting,
    Tri? checkBackground,
    double? ovalProgress,
  }) {
    return PortraitUiModel(
      statusLabel: statusLabel ?? this.statusLabel,
      privacyLabel: privacyLabel ?? this.privacyLabel,
      primaryMessage: primaryMessage ?? this.primaryMessage,
      secondaryMessage: secondaryMessage ?? this.secondaryMessage,
      countdownSeconds: countdownSeconds ?? this.countdownSeconds,
      countdownProgress: countdownProgress ?? this.countdownProgress,
      checkFraming: checkFraming ?? this.checkFraming,
      checkHead: checkHead ?? this.checkHead,
      checkEyes: checkEyes ?? this.checkEyes,
      checkLighting: checkLighting ?? this.checkLighting,
      checkBackground: checkBackground ?? this.checkBackground,
      ovalProgress: ovalProgress ?? this.ovalProgress,
    );
  }
}

/// Controller you can mutate from your update loop.
class PortraitUiController extends ValueNotifier<PortraitUiModel> {
  PortraitUiController([PortraitUiModel? initial]) : super(initial ?? const PortraitUiModel());
}

/// Main overlay widget (place above your camera preview and landmark overlay).
class PortraitValidatorHUD extends StatelessWidget {
  const PortraitValidatorHUD({
    super.key,
    required this.modelListenable,
    this.mirror = true,
    this.fit = BoxFit.cover,
    this.showGhost = true,
    this.showSafeBox = true,
    this.showChecklist = false, // hide by default
    this.belowMessages, // ⬅️ renders right under the primary/secondary messages
    this.messageGap = 0.0125, // ⬅️ fraction of screen height (e.g., 1.25%)
    this.keepAboveCountdownRing = true, // ⬅️ avoid overlapping the ring if possible
  });

  final ValueListenable<PortraitUiModel> modelListenable;
  final bool mirror;
  final BoxFit fit;
  final bool showGhost;
  final bool showSafeBox;
  final bool showChecklist;

  /// Anything you pass here will appear just below the primary/secondary
  /// message block (i.e., under the guidance pill).
  final Widget? belowMessages;

  /// Fraction (0..1) of the screen height to place between the face oval
  /// bottom and the message pill. Example: 0.015 = 1.5% of screen height.
  final double messageGap;

  /// If true, we’ll clamp the message pill upward to avoid overlapping the
  /// countdown ring area when it’s visible.
  final bool keepAboveCountdownRing;

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.of(context).size;
    final safe = MediaQuery.of(context).padding;

    // Countdown ring metrics (keep in sync with _CountdownRing)
    const ringSize = 92.0;
    const ringBottom = 16.0;

    return ValueListenableBuilder<PortraitUiModel>(
      valueListenable: modelListenable,
      builder: (context, model, _) {
        // Compute where the face oval is, so we can anchor messages under it.
        final ovalRect = faceOvalRectFor(screen);

        // Convert fraction to pixels using screen height.
        final double gapPx = screen.height * messageGap.clamp(0.0, 1.0).toDouble();

        // Desired top position for the guidance pill: just under the oval.
        final desiredTop = ovalRect.bottom + gapPx;

        // If we want to keep above the countdown ring, clamp to the top of that area.
        // Top edge of the ring’s bounding box:
        final ringTop = screen.height - (ringBottom + safe.bottom + ringSize);

        // Final top for message block:
        final messagesTop = keepAboveCountdownRing
            ? math.min(desiredTop, ringTop - 8) // leave a tiny gap above the ring
            : desiredTop;

        return Stack(
          children: [
            // 1) Ghost target (face oval + optional safe area)
            Positioned.fill(
              child: CustomPaint(
                painter: _GhostPainter(
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

            // 2) Top row chips: status + privacy (both respect hiding list)
            Positioned(
              left: 12,
              right: 12,
              top: 10 + safe.top,
              child: Row(
                children: [
                  if (!isHiddenChipLabel(model.statusLabel))
                    _ChipPill(
                      label: model.statusLabel,
                      background: const Color(0xFFFFF1B8), // warm yellow
                      foreground: Colors.black87,
                      icon: Icons.tune_rounded,
                    ),
                  const Spacer(),
                  if (!isHiddenChipLabel(model.privacyLabel))
                    _ChipPill(
                      label: model.privacyLabel,
                      background: Colors.white.withOpacity(0.30),
                      foreground: Colors.white,
                      icon: Icons.shield_outlined,
                    ),
                ],
              ),
            ),

            // 3) Right rail checklist (gated)
            if (showChecklist)
              Positioned(
                right: 8,
                top: (screen.height * 0.22),
                child: _ChecklistRail(
                  items: const ['Framing', 'Head', 'Eyes', 'Light', 'BG'],
                  states: [
                    model.checkFraming,
                    model.checkHead,
                    model.checkEyes,
                    model.checkLighting,
                    model.checkBackground,
                  ],
                ),
              ),

            // 4) Guidance pill anchored under the face oval (with gap)
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

            // 5) Countdown ring (auto-capture)
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

/// Paints the face oval "ghost" and (optional) safe-area box.
class _GhostPainter extends CustomPainter {
  _GhostPainter({
    required this.color,
    required this.opacity,
    required this.strokeWidth,
    required this.showGhost,
    this.showSafeBox = true,
    this.shadeOutsideOval = true,
    this.shadeOpacity = 0.30,
    this.progress = 0.0, // 0..1 fraction of arc to draw in green
  });

  final Color color;
  final double opacity;
  final double strokeWidth;
  final bool showGhost;
  final bool showSafeBox;

  final bool shadeOutsideOval;
  final double shadeOpacity;

  /// 0..1 of the oval perimeter to be highlighted in green.
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    if (!showGhost) return;

    // Use shared geometry so painter and helpers stay in sync
    final ovalRect = faceOvalRectFor(size);

    // Dim everything outside the oval (30% black)
    if (shadeOutsideOval) {
      final mask = Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(Offset.zero & size)
        ..addOval(ovalRect);
      final maskPaint = Paint()..color = Colors.black.withOpacity(shadeOpacity);
      canvas.drawPath(mask, maskPaint);
    }

    // Base oval
    final base = Paint()
      ..color = color.withOpacity(opacity)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..isAntiAlias = true;
    canvas.drawOval(ovalRect, base);

    // Draw the green fraction as an arc along the oval
    final p = progress.clamp(0.0, 1.0);
    if (p > 0) {
      final arcPaint = Paint()
        ..color = kProgressGreen // ← #4DC274
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth + 3
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true;

      // Start at 12 o’clock (-math.pi/2) and sweep clockwise by p * 2π
      const startAngle = -math.pi / 2;
      final sweepAngle = p * 2 * math.pi;

      canvas.drawArc(ovalRect, startAngle, sweepAngle, false, arcPaint);
    }

    // Safe area rounded box — draw only if enabled
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
  bool shouldRepaint(covariant _GhostPainter old) {
    return old.opacity != opacity ||
           old.strokeWidth != strokeWidth ||
           old.color != color ||
           old.showGhost != showGhost ||
           old.showSafeBox != showSafeBox ||
           old.shadeOutsideOval != shadeOutsideOval ||
           old.shadeOpacity != shadeOpacity ||
           old.progress != progress;
  }
}

/// Compact rounded pill for status/labels.
class _ChipPill extends StatelessWidget {
  const _ChipPill({
    required this.label,
    required this.background,
    required this.foreground,
    required this.icon,
  });

  final String label;
  final Color background;
  final Color foreground;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: foreground),
          const SizedBox(width: 8),
          Text(label, style: TextStyle(color: foreground, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

/// Right-edge checklist with tri-state icons.
class _ChecklistRail extends StatelessWidget {
  const _ChecklistRail({required this.items, required this.states});

  final List<String> items;
  final List<Tri> states;

  Color _color(Tri t) {
    switch (t) {
      case Tri.ok:
        return kProgressGreen; // ← #4DC274
      case Tri.almost:
        return Colors.amber.shade400;
      case Tri.pending:
      default:
        return Colors.white.withOpacity(0.55);
    }
  }

  IconData _icon(Tri t) {
    switch (t) {
      case Tri.ok:
        return Icons.check_circle_rounded;
      case Tri.almost:
        return Icons.change_circle_outlined;
      case Tri.pending:
      default:
        return Icons.radio_button_unchecked;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: List.generate(items.length, (i) {
        final c = _color(states[i]);
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6.0),
          child: Tooltip(
            message: items[i],
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.3),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white24),
              ),
              child: Icon(_icon(states[i]), color: c, size: 22),
            ),
          ),
        );
      }),
    );
  }
}

/// Bottom guidance pill (primary + optional secondary).
class _GuidancePill extends StatelessWidget {
  const _GuidancePill({required this.primary, this.secondary});

  final String primary;
  final String? secondary;

  @override
  Widget build(BuildContext context) {
    final String? secondaryText = _nullIfBlank(secondary); // ← normalize

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      child: Container(
        key: ValueKey<String>(primary + (secondaryText ?? '')), // ← use normalized
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFFFFF1B8),
          borderRadius: BorderRadius.circular(16),
          boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 8, offset: Offset(0, 4))],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: const [
                Icon(Icons.north_east_rounded, color: Colors.black87, size: 18),
                SizedBox(width: 8),
              ],
            ),
            Text(
              primary,
              style: const TextStyle(color: Colors.black87, fontSize: 16, fontWeight: FontWeight.w700),
            ),
            if (secondaryText != null) ...[
              const SizedBox(height: 6),
              Text(
                secondaryText,
                style: const TextStyle(color: Colors.black87, fontSize: 13, fontWeight: FontWeight.w500),
              ),
            ]
          ],
        ),
      ),
    );
  }
}

/// Circular countdown ring with a big numeral in the middle.
/// progress: 1.0 -> 0.0 across the countdown.
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
          // Background ring
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
          // Foreground ring (progress)
          SizedBox(
            width: size,
            height: size,
            child: CircularProgressIndicator(
              value: progress,
              strokeWidth: 6,
              valueColor: const AlwaysStoppedAnimation<Color>(kProgressGreen), // ← #4DC274
              backgroundColor: Colors.transparent,
            ),
          ),
          // Numeral
          Text(
            '$seconds',
            style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700, color: Colors.white),
          ),
        ],
      ),
    );
  }
}
