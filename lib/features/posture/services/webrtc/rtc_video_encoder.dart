// lib/features/posture/services/webrtc/rtc_video_encoder.dart
//
// RtcVideoEncoder: centralizes encoder-related configuration for flutter_webrtc
// - Chooses codec order (e.g., low-latency H.264, optionally HEVC)
// - Applies sender limits (bitrate/FPS) to the video RTCRtpSender
// - Offers an SDP bit-hinting helper for H.264 fmtp lines, now extended to
//   enforce low-latency profile (packetization-mode=1, profile-level-id=42e01f)
//   and optional max-fr.
//
// NOTE: This does not implement a software encoder in Dart — libwebrtc on the
// native side performs the actual encoding. Here we only steer preferences.

import 'dart:math' as math;
import 'package:flutter_webrtc/flutter_webrtc.dart';

class RtcVideoEncoder {
  RtcVideoEncoder({
    required this.idealFps,
    required this.maxBitrateKbps,
    this.preferHevc = false,
    this.forceCodec, // "VP8","H264","H265","VP9","AV1"
    this.enableSimulcast = false,
    this.simulcastScales, // e.g., [1.0, 2.0] (keep 1.0 first)
  });

  final int idealFps;
  final int maxBitrateKbps;
  final bool preferHevc;
  final String? forceCodec;
  final bool enableSimulcast;
  final List<double>? simulcastScales;

  /// Apply everything we can to a transceiver:
  /// - codec ordering (best-effort; some platforms may ignore)
  /// - sender parameters (bitrate/FPS, optional simulcast)
  Future<void> applyTo(RTCRtpTransceiver transceiver) async {
    await _preferCodecs(transceiver, preferHevc: preferHevc, forceCodec: forceCodec);
    await _applySenderLimits(
      transceiver.sender,
      maxKbps: maxBitrateKbps,
      maxFps: idealFps,
      enableSimulcast: enableSimulcast,
      simulcastScales: simulcastScales,
    );
  }

  // ────────────────────────────────────────────────────────────────────────────
  // Codec preferences
  // ────────────────────────────────────────────────────────────────────────────

  Future<void> _preferCodecs(
    RTCRtpTransceiver transceiver, {
    required bool preferHevc,
    String? forceCodec,
  }) async {
    try {
      final caps = await getRtpSenderCapabilities('video');
      final all = caps?.codecs ?? const <RTCRtpCodecCapability>[];
      if (all.isEmpty) return;

      bool isCodec(RTCRtpCodecCapability c, String family) {
        final m = (c.mimeType ?? '').toLowerCase();
        switch (family.toUpperCase()) {
          case 'H264':
            return m == 'video/h264';
          case 'H265':
          case 'HEVC':
            return m == 'video/h265';
          case 'VP8':
            return m == 'video/vp8';
          case 'VP9':
            return m == 'video/vp9';
          case 'AV1':
            return m == 'video/av1';
          default:
            return false;
        }
      }

      bool isLowLatencyH264(RTCRtpCodecCapability c) {
        final mime = (c.mimeType ?? '').toLowerCase();
        final fmtp = (c.sdpFmtpLine ?? '').toLowerCase();
        return mime == 'video/h264' &&
            fmtp.contains('packetization-mode=1') &&
            (
                fmtp.contains('profile-level-id=42e01f') ||
                fmtp.contains('profile-level-id=42001f')
            );
      }

      // Family buckets
      final h264LL = all.where(isLowLatencyH264).toList();
      final h264 = all.where((c) => isCodec(c, 'H264')).toList();
      final h265 = all.where((c) => isCodec(c, 'H265') || isCodec(c, 'HEVC')).toList();
      final vp8 = all.where((c) => isCodec(c, 'VP8')).toList();
      final vp9 = all.where((c) => isCodec(c, 'VP9')).toList();
      final av1 = all.where((c) => isCodec(c, 'AV1')).toList();

      List<RTCRtpCodecCapability> order = [];

      if (forceCodec != null && forceCodec.trim().isNotEmpty) {
        final fam = forceCodec.trim().toUpperCase();
        List<RTCRtpCodecCapability> pick() {
          switch (fam) {
            case 'H264':
              return [...h264LL, ...h264.where((c) => !h264LL.contains(c))];
            case 'H265':
            case 'HEVC':
              return h265;
            case 'VP8':
              return vp8;
            case 'VP9':
              return vp9;
            case 'AV1':
              return av1;
            default:
              return const [];
          }
        }

        order.addAll(pick());
      } else {
        // Default strategy:
        // - Prefer low-latency H.264
        // - Optionally elevate HEVC if requested
        // - Then keep the rest (VP8/VP9/AV1) in a stable order
        order
          ..addAll(h264LL)
          ..addAll(h264.where((c) => !h264LL.contains(c)));

        if (preferHevc && h265.isNotEmpty) {
          order = [...h265, ...order]; // put HEVC before H.264 families
        } else {
          order.addAll(h265); // or omit to avoid HEVC entirely
        }

        order
          ..addAll(vp8)
          ..addAll(vp9)
          ..addAll(av1);
      }

      // Deduplicate while preserving fmtp variants (by mime+fmtp key)
      final seen = <String>{};
      String key(RTCRtpCodecCapability c) {
        final mime = (c.mimeType ?? '').toLowerCase();
        final fmtp = (c.sdpFmtpLine ?? '').toLowerCase();
        return '$mime|$fmtp';
      }

      final preferred = <RTCRtpCodecCapability>[];
      for (final c in order) {
        final k = key(c);
        if (seen.add(k)) preferred.add(c);
      }
      if (preferred.isEmpty) preferred.addAll(all);

      await transceiver.setCodecPreferences(preferred);
    } catch (_) {
      // Best-effort; some platforms may not support setCodecPreferences
    }
  }

  // ────────────────────────────────────────────────────────────────────────────
  // Sender limits & (optional) simulcast
  // ────────────────────────────────────────────────────────────────────────────

  Future<void> _applySenderLimits(
    RTCRtpSender sender, {
    required int maxKbps,
    required int maxFps,
    bool enableSimulcast = false,
    List<double>? simulcastScales,
  }) async {
    try {
      final encs = <RTCRtpEncoding>[];

      if (enableSimulcast && (simulcastScales != null) && simulcastScales.isNotEmpty) {
        // First layer should be 1.0 (full res). Others are downscaled.
        for (int i = 0; i < simulcastScales.length; i++) {
          final scale = simulcastScales[i];
          // Distribute bitrate rudimentarily (highest gets most).
          final frac = (i == 0) ? 0.6 : (0.4 / math.max(1, simulcastScales.length - 1));
          encs.add(
            RTCRtpEncoding(
              scaleResolutionDownBy: scale,
              maxBitrate: (maxKbps * 1000 * frac).round(),
              maxFramerate: maxFps,
            ),
          );
        }
      } else {
        encs.add(
          RTCRtpEncoding(
            scaleResolutionDownBy: 1.0,
            maxBitrate: maxKbps * 1000,
            maxFramerate: maxFps,
          ),
        );
      }

      await sender.setParameters(RTCRtpParameters(encodings: encs));
    } catch (_) {
      // Best-effort; older plugin versions may not support all fields.
    }
  }

  // ────────────────────────────────────────────────────────────────────────────
  // SDP hinting (for H.264 fmtp)
  // ────────────────────────────────────────────────────────────────────────────

  /// Extended: Ensure H.264 payload types have (or receive) an `a=fmtp` line
  /// containing:
  ///   - packetization-mode=1
  ///   - profile-level-id=42e01f   (Constrained Baseline; broadly compatible)
  ///   - x-google-start/min/max-bitrate
  ///   - max-fr (if [fps] provided)
  ///
  /// *Merges* with any existing fmtp values without dropping unknown keys.
  /// If an H.264 payload lacks an fmtp line, one is inserted immediately
  /// after its matching `a=rtpmap` line.
  ///
  /// Notes:
  /// - Call this on the OFFER (and optionally on the ANSWER) SDP
  ///   before setLocalDescription / after setRemoteDescription respectively.
  /// - Newline handling works with \r\n / \n / \r.
  static String mungeH264BitrateHints(String sdp, {required int kbps, int? fps}) {
    // Discover H.264 payload types from rtpmap lines.
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

    // Keys we want to enforce (merge semantics)
    String minKbps(int start) => ((start * 0.8).round()).toString();
    Map<String, String> injectFor(int startKbps, int? frames) => {
          'packetization-mode': '1',
          'profile-level-id': '42e01f',
          'x-google-start-bitrate': '$startKbps',
          'x-google-min-bitrate': minKbps(startKbps),
          'x-google-max-bitrate': '$startKbps',
          if (frames != null) 'max-fr': '$frames',
        };

    // Helper to merge existing fmtp value list with our inject map.
    String _mergeFmtpValues(String current, Map<String, String> inject) {
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
          // Rare flag-style token without '=', preserve as-is.
          map[p] = p;
        }
      }
      inject.forEach((k, v) {
        map[k] = '$k=$v'; // overwrite or add
      });
      return map.values.join(';');
    }

    for (final pt in h264Pt) {
      final fmtpRe = RegExp('^a=fmtp:$pt\\s+([^\\r\\n]*)', multiLine: true);
      final desired = injectFor(kbps, fps);

      if (fmtpRe.hasMatch(out)) {
        // Merge into existing fmtp
        out = out.replaceAllMapped(fmtpRe, (m) {
          final cur = m.group(1)!;
          final merged = _mergeFmtpValues(cur, desired);
          return 'a=fmtp:$pt $merged';
        });
      } else {
        // Insert a new fmtp line immediately after the rtpmap line
        final rtpLineRe = RegExp(
          '^a=rtpmap:$pt' r'\s+H264/\d+\s*$',
          multiLine: true,
        );
        out = out.replaceAllMapped(rtpLineRe, (m) {
          final kv = desired.entries.map((e) => '${e.key}=${e.value}').join(';');
          return '${m.group(0)}$nl' 'a=fmtp:$pt $kv';
        });
      }
    }

    return out;
  }
}
