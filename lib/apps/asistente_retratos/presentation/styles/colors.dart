// lib/apps/asistente_retratos/presentation/styles/colors.dart
import 'package:flutter/material.dart';

class AppColors {
  static const redPrimary = Color(0xFFD10C13);
  static const redDark    = Color(0xFFD3262D);
  static const redSoft    = Color(0xFFE28C90);
  static const green      = Color(0xFF53B056);
  static const greenLight = Color(0xFFE9F7EA);
  static const ink        = Color(0xFF1E1D1D);
  static const grey       = Color(0xFF9B9B99);
  static const greyDark   = Color(0xFF777070);
  static const greyLight  = Color(0xFFECEBEB);
  static const white      = Color(0xFFFFFFFF);

  static ColorScheme scheme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    return ColorScheme(
      brightness: brightness,
      primary: redPrimary,
      onPrimary: white,
      secondary: green,
      onSecondary: white,
      error: redDark,
      onError: white,
      surface: dark ? const Color(0xFF121212) : white,
      onSurface: dark ? white : ink,
      background: dark ? Colors.black : white,
      onBackground: dark ? white : ink,
      tertiary: redSoft,
      onTertiary: ink,
      // Si tu versión de Flutter no tiene estos campos, elimínalos.
      surfaceContainerHighest: greyLight,
      surfaceContainerHigh:    greyLight,
      surfaceContainer:        greyLight,
      surfaceContainerLow:     greyLight,
      outline: grey,
      outlineVariant: greyLight,
      shadow: Colors.black,
      scrim: Colors.black,
    );
  }
}

@immutable
class CaptureTheme extends ThemeExtension<CaptureTheme> {
  final Color hudOk;
  final Color hudWarn;
  final Color hudError;
  final Color hudText;
  final Color faceOval;
  final Color pipBorder;

  const CaptureTheme({
    this.hudOk = AppColors.green,
    this.hudWarn = AppColors.redSoft,
    this.hudError = AppColors.redDark,
    this.hudText = AppColors.white,
    this.faceOval = AppColors.green,
    this.pipBorder = AppColors.white,
  });

  @override
  CaptureTheme copyWith({
    Color? hudOk, Color? hudWarn, Color? hudError,
    Color? hudText, Color? faceOval, Color? pipBorder,
  }) => CaptureTheme(
    hudOk: hudOk ?? this.hudOk,
    hudWarn: hudWarn ?? this.hudWarn,
    hudError: hudError ?? this.hudError,
    hudText: hudText ?? this.hudText,
    faceOval: faceOval ?? this.faceOval,
    pipBorder: pipBorder ?? this.pipBorder,
  );

  @override
  ThemeExtension<CaptureTheme> lerp(ThemeExtension<CaptureTheme>? other, double t) {
    if (other is! CaptureTheme) return this;
    Color f(Color a, Color b) => Color.lerp(a, b, t)!;
    return CaptureTheme(
      hudOk:     f(hudOk, other.hudOk),
      hudWarn:   f(hudWarn, other.hudWarn),
      hudError:  f(hudError, other.hudError),
      hudText:   f(hudText, other.hudText),
      faceOval:  f(faceOval, other.faceOval),
      pipBorder: f(pipBorder, other.pipBorder),
    );
  }
}
