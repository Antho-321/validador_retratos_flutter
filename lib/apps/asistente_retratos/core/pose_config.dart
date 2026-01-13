// lib/apps/asistente_retratos/core/pose_config.dart
/// Configuración centralizada para el módulo de captura de pose/retratos.
/// Estos valores son los defaults; pueden ser sobreescritos en runtime.
class PoseConfig {
  // ─────────────────────────────────────────────────────────────────────────
  // SSL
  // ─────────────────────────────────────────────────────────────────────────
  /// true = aceptar certificado SSL no confiable (equivalente a curl -k)
  static bool allowInsecureSsl = true;

  // ─────────────────────────────────────────────────────────────────────────
  // WebRTC ICE Configuration
  // ─────────────────────────────────────────────────────────────────────────
  static String? stunUrl = 'stun:stun.l.google.com:19302';

  /// Using free OpenRelay.io TURN server for NAT traversal
  static String? turnUrl = 'turn:openrelay.metered.ca:80';
  static String? turnUsername = 'openrelayproject';
  static String? turnPassword = 'openrelayproject';

  // ─────────────────────────────────────────────────────────────────────────
  // Low-latency capture tuning (client-side)
  // ─────────────────────────────────────────────────────────────────────────
  static bool lowLatency = true;
  static bool preferBestResolution = false;

  static int idealWidth = 1280;
  static int idealHeight = 720;
  static int idealFps = 30;

  /// Cap de envio para bajar carga de inferencia (preview se mantiene en HD).
  static int sendFps = 20;

  /// Downscale del stream saliente (2.0 => 640x360 si la cámara está en 1280x720).
  static double sendScale = 2.0;

  static int maxBitrateKbps = 600;
  static int kfMinGapMs = 200;

  // ─────────────────────────────────────────────────────────────────────────
  // API / Endpoints
  // ─────────────────────────────────────────────────────────────────────────
  /// URL del endpoint para validar imágenes (POST con imagen base64).
  static String validarImagenUrl = '';

  // ─────────────────────────────────────────────────────────────────────────
  // Identidad del usuario (valores por defecto, normalmente se pasan en runtime)
  // ─────────────────────────────────────────────────────────────────────────
  static String cedula = '';

  // ─────────────────────────────────────────────────────────────────────────
  // Feature flags
  // ─────────────────────────────────────────────────────────────────────────
  static bool enableFaceRecog = true;

  /// Permite reconfigurar todos los valores desde un Map (útil para testing o
  /// para cargar desde otra fuente como SharedPreferences, RemoteConfig, etc.)
  static void configure(Map<String, dynamic> overrides) {
    if (overrides.containsKey('allowInsecureSsl')) {
      allowInsecureSsl = overrides['allowInsecureSsl'] as bool;
    }
    if (overrides.containsKey('stunUrl')) {
      stunUrl = overrides['stunUrl'] as String?;
    }
    if (overrides.containsKey('turnUrl')) {
      turnUrl = overrides['turnUrl'] as String?;
    }
    if (overrides.containsKey('turnUsername')) {
      turnUsername = overrides['turnUsername'] as String?;
    }
    if (overrides.containsKey('turnPassword')) {
      turnPassword = overrides['turnPassword'] as String?;
    }
    if (overrides.containsKey('lowLatency')) {
      lowLatency = overrides['lowLatency'] as bool;
    }
    if (overrides.containsKey('preferBestResolution')) {
      preferBestResolution = overrides['preferBestResolution'] as bool;
    }
    if (overrides.containsKey('idealWidth')) {
      idealWidth = overrides['idealWidth'] as int;
    }
    if (overrides.containsKey('idealHeight')) {
      idealHeight = overrides['idealHeight'] as int;
    }
    if (overrides.containsKey('idealFps')) {
      idealFps = overrides['idealFps'] as int;
    }
    if (overrides.containsKey('sendFps')) {
      sendFps = overrides['sendFps'] as int;
    }
    if (overrides.containsKey('sendScale')) {
      sendScale = overrides['sendScale'] as double;
    }
    if (overrides.containsKey('maxBitrateKbps')) {
      maxBitrateKbps = overrides['maxBitrateKbps'] as int;
    }
    if (overrides.containsKey('kfMinGapMs')) {
      kfMinGapMs = overrides['kfMinGapMs'] as int;
    }
    if (overrides.containsKey('enableFaceRecog')) {
      enableFaceRecog = overrides['enableFaceRecog'] as bool;
    }
    if (overrides.containsKey('validarImagenUrl')) {
      validarImagenUrl = overrides['validarImagenUrl'] as String;
    }
    if (overrides.containsKey('cedula')) {
      cedula = overrides['cedula'] as String;
    }
  }
}
