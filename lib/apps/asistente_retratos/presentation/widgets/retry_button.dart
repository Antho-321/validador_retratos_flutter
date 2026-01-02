import 'package:flutter/material.dart';

/// Botón reutilizable de "Reintentar" con ícono de refresh.
/// Se usa en todas las pantallas de error de la aplicación.
class RetryButton extends StatelessWidget {
  const RetryButton({
    super.key,
    required this.onPressed,
  });

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: onPressed,
      icon: const Icon(Icons.refresh),
      label: const Text('Reintentar'),
    );
  }
}
