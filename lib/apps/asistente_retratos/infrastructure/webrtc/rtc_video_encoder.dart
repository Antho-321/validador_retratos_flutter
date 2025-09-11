// lib/apps/asistente_retratos/infrastructure/webrtc/rtc_video_encoder.dart
//
// RtcVideoEncoder: centraliza configuración del encoder para flutter_webrtc
// - Ordena codecs (H.264 baja latencia; opcional HEVC)
// - Aplica límites al sender (bitrate/FPS), con opción de simulcast
// - Ofrece un helper SDP para "hint" de H.264 (packetization-mode=1, profile-level-id, bitrates)
//
// Nota: No implementa un encoder software; libwebrtc (nativo) hace el encoding.
// Aquí solo "sugerimos" preferencias.

import 'package:flutter_webrtc/flutter_webrtc.dart';

class RtcVideoEncoder {
  RtcVideoEncoder({
    required this.idealFps,
    required this.maxBitrateKbps,
    this.preferHevc = false,
    this.forceCodec,           // "VP8","H264","H265|HEVC","VP9","AV1"
    this.enableSimulcast = false,
    this.simulcastScales,      // p.ej. [2.0, 1.25, 1.0]  (downscale factors)
  });

  final int idealFps;
  final int maxBitrateKbps;
  final bool preferHevc;
  final String? forceCodec;
  final bool enableSimulcast;
  final List<double>? simulcastScales;

  /// Aplica preferencias de codec y límites del sender al transceiver.
  Future<void> applyTo(RTCRtpTransceiver transceiver) async {
    await _preferCodecs(
      transceiver,
      preferHevc: preferHevc,
      forceCodec: forceCodec,
    );
    await _applySenderLimits(
      transceiver.sender,
      maxKbps: maxBitrateKbps,
      maxFps: idealFps,
      enableSimulcast: enableSimulcast,
      simulcastScales: simulcastScales,
    );
  }

  // ─────────────────────────────────────────────────────────────
  // Preferencias de codec
  // ─────────────────────────────────────────────────────────────

  Future<void> _preferCodecs(
    RTCRtpTransceiver transceiver, {
    required bool preferHevc,
    String? forceCodec,
  }) async {
    try {
      final caps = await getRtpSenderCapabilities('video');
      final all = caps?.codecs ?? const <RTCRtpCodecCapability>[];
      if (all.isEmpty) return;

      bool isFamily(RTCRtpCodecCapability c, String fam) {
        final m = (c.mimeType ?? '').toLowerCase();
        switch (fam.toUpperCase()) {
          case 'H264': return m == 'video/h264';
          case 'H265':
          case 'HEVC': return m == 'video/h265';
          case 'VP8' : return m == 'video/vp8';
          case 'VP9' : return m == 'video/vp9';
          case 'AV1' : return m == 'video/av1';
          default    : return false;
        }
      }

      bool isLowLatencyH264(RTCRtpCodecCapability c) {
        final mime = (c.mimeType ?? '').toLowerCase();
        final fmtp = (c.sdpFmtpLine ?? '').toLowerCase();
        return mime == 'video/h264'
            && fmtp.contains('packetization-mode=1')
            && (fmtp.contains('profile-level-id=42e01f') ||
                fmtp.contains('profile-level-id=42001f'));
      }

      final h264LL = all.where(isLowLatencyH264).toList();
      final h264   = all.where((c) => isFamily(c, 'H264')).toList();
      final h265   = all.where((c) => isFamily(c, 'H265') || isFamily(c, 'HEVC')).toList();
      final vp8    = all.where((c) => isFamily(c, 'VP8')).toList();
      final vp9    = all.where((c) => isFamily(c, 'VP9')).toList();
      final av1    = all.where((c) => isFamily(c, 'AV1')).toList();

      List<RTCRtpCodecCapability> order = [];

      if (forceCodec != null && forceCodec.trim().isNotEmpty) {
        switch (forceCodec.trim().toUpperCase()) {
          case 'H264':
            order = [...h264LL, ...h264.where((c) => !h264LL.contains(c))];
            break;
          case 'H265':
          case 'HEVC':
            order = [...h265];
            break;
          case 'VP8':
            order = [...vp8];
            break;
          case 'VP9':
            order = [...vp9];
            break;
          case 'AV1':
            order = [...av1];
            break;
          default:
            order = [...h264LL, ...h264, ...h265, ...vp8, ...vp9, ...av1];
        }
      } else {
        order
          ..addAll(h264LL)
          ..addAll(h264.where((c) => !h264LL.contains(c)));
        if (preferHevc && h265.isNotEmpty) {
          order = [...h265, ...order];
        } else {
          order.addAll(h265);
        }
        order..addAll(vp8)..addAll(vp9)..addAll(av1);
      }

      // Dedup por (mime|fmtp) preservando orden
      final seen = <String>{};
      String key(RTCRtpCodecCapability c) =>
          '${(c.mimeType ?? '').toLowerCase()}|${(c.sdpFmtpLine ?? '').toLowerCase()}';

      final preferred = <RTCRtpCodecCapability>[];
      for (final c in order) {
        final k = key(c);
        if (seen.add(k)) preferred.add(c);
      }
      if (preferred.isEmpty) preferred.addAll(all);

      // Puede no estar soportado en todas las plataformas → best-effort
      await transceiver.setCodecPreferences(preferred);
    } catch (_) {
      // Ignora: versiones antiguas pueden no exponer setCodecPreferences
    }
  }

  // ─────────────────────────────────────────────────────────────
  // Límites del sender (+ simulcast opcional)
  // ─────────────────────────────────────────────────────────────

  Future<void> _applySenderLimits(
    RTCRtpSender sender, {
    required int maxKbps,
    required int maxFps,
    bool enableSimulcast = false,
    List<double>? simulcastScales,
  }) async {
    try {
      final encs = <RTCRtpEncoding>[];

      if (enableSimulcast &&
          simulcastScales != null &&
          simulcastScales.isNotEmpty) {
        // Asigna varias capas con distintos downscales (low→full).
        // Distribución simple de bitrate (60% a la capa mayor).
        final rids = ['q', 'h', 'f']; // low, mid, full
        final n = simulcastScales.length;
        for (var i = 0; i < n; i++) {
          final scale = simulcastScales[i];
          final share = (i == n - 1)
              ? 0.6
              : (0.4 / (n - 1).clamp(1, 3)); // reparte el 40% entre capas bajas
          encs.add(
            RTCRtpEncoding(
              rid: rids[i % rids.length],
              active: true,
              scaleResolutionDownBy: scale,
              maxBitrate: (maxKbps * 1000 * share).round(),
              maxFramerate: maxFps,
            ),
          );
        }
      } else {
        // Una sola capa, baja latencia
        encs.add(
          RTCRtpEncoding(
            rid: 'f',
            active: true,
            scaleResolutionDownBy: 1.0,
            maxBitrate: maxKbps * 1000,
            maxFramerate: maxFps,
          ),
        );
      }

      // Patrón seguro: leer-modificar-escribir
      final params = sender.parameters;
      params.encodings = encs;
      await sender.setParameters(params);
    } catch (_) {
      // Algunas plataformas ignoran/limitan setParameters → best-effort
    }
  }

  // ─────────────────────────────────────────────────────────────
  // SDP hinting para H.264
  // ─────────────────────────────────────────────────────────────

  /// Inserta/mezcla en H.264 fmtp:
  ///  - packetization-mode=1
  ///  - profile-level-id=42e01f
  ///  - x-google-(start|min|max)-bitrate
  ///  - max-fr (si [fps] se provee)
  static String mungeH264BitrateHints(String sdp, {required int kbps, int? fps}) {
    final h264Pt = <String>{};
    final rtpmap = RegExp(r'^a=rtpmap:(\d+)\s+H264/\d+', multiLine: true);
    for (final m in rtpmap.allMatches(sdp)) {
      h264Pt.add(m.group(1)!);
    }
    if (h264Pt.isEmpty) return sdp;

    String out = sdp;
    final nl = sdp.contains('\r\n')
        ? '\r\n'
        : (sdp.contains('\n') ? '\n' : '\r\n');

    String minKbps(int start) => ((start * 0.8).round()).toString();
    Map<String, String> injectFor(int startKbps, int? frames) => {
          'packetization-mode': '1',
          'profile-level-id': '42e01f',
          'x-google-start-bitrate': '$startKbps',
          'x-google-min-bitrate': minKbps(startKbps),
          'x-google-max-bitrate': '$startKbps',
          if (frames != null) 'max-fr': '$frames',
        };

    String mergeFmtp(String current, Map<String, String> inject) {
      final map = <String, String>{};
      final parts = current
          .split(';')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      for (final p in parts) {
        final eq = p.indexOf('=');
        if (eq > 0) {
          final k = p.substring(0, eq).trim();
          final v = p.substring(eq + 1).trim();
          map[k] = '$k=$v';
        } else {
          map[p] = p; // token sin '='
        }
      }
      inject.forEach((k, v) => map[k] = '$k=$v');
      return map.values.join(';');
    }

    for (final pt in h264Pt) {
      final fmtpRe = RegExp('^a=fmtp:$pt\\s+([^\\r\\n]*)', multiLine: true);
      final desired = injectFor(kbps, fps);

      if (fmtpRe.hasMatch(out)) {
        out = out.replaceAllMapped(fmtpRe, (m) {
          final cur = m.group(1)!;
          final merged = mergeFmtp(cur, desired);
          return 'a=fmtp:$pt $merged';
        });
      } else {
        final rtpLineRe = RegExp('^a=rtpmap:$pt\\s+H264/\\d+\\s*\$', multiLine: true);
        out = out.replaceAllMapped(rtpLineRe, (m) {
          final kv = desired.entries.map((e) => '${e.key}=${e.value}').join(';');
          return '${m.group(0)}$nl' 'a=fmtp:$pt $kv';
        });
      }
    }
    return out;
  }
}
