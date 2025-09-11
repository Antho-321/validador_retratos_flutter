// lib/apps/asistente_retratos/presentation/styles/theme.dart
import 'package:flutter/material.dart';
import 'colors.dart';

class AsistenteTheme {
  static ThemeData light = ThemeData(
    useMaterial3: true,
    colorScheme: AppColors.scheme(Brightness.light),
    extensions: const [CaptureTheme()],
  );

  static ThemeData dark = ThemeData(
    useMaterial3: true,
    colorScheme: AppColors.scheme(Brightness.dark),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: AppColors.redPrimary,
    ),
    scaffoldBackgroundColor: Colors.black,
    iconTheme: const IconThemeData(color: AppColors.white),
    extensions: const [CaptureTheme()],
  );
}
