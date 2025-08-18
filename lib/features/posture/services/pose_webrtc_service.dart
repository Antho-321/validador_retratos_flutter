// lib/features/posture/services/pose_webrtc_service.dart

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' show Offset, Size;

import 'package:flutter/foundation.dart' show compute, ValueNotifier;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;

import '../presentation/widgets/overlays.dart' show PoseFrame, poseFrameFromMap;

Map<String, dynamic> _parseJson(String text) =>
    jsonDecode(text) as Map<String, dynamic>;

/// WebRTC client that:
/// - publishes the local camera,
/// - receives pose results over a data channel (binary preferred, JSON fallback),
/// - exposes both a latest-frame ValueNotifier (low-latency) and a Stream.
/// Uses **two** data channels:
///   - "results": unordered + lossy (no retransmits) for pose packets
///   - "ctrl": reliable for control messages like "KF"
class PoseWebRTCService {
  PoseWebRTCService({
    required this.offerUri,
    this.facingMode = 'user', // 'user' or 'environment'
    this.idealWidth = 640,
    this.idealHeight = 480,
    this.idealFps = 15,
    String? stunUrl,
    String? turnUrl,
    String? turnUsername,
    String? turnPassword,
  })  : _stunUrl = stunUrl ??
            const String.fromEnvironment(
              'STUN_URL',
              defaultValue: 'stun:stun.l.google.com:19302',
            ),
        _turnUrl = turnUrl ?? const String.fromEnvironment('TURN_URL'),
        _turnUsername =
            turnUsername ?? const String.fromEnvironment('TURN_USERNAME'),
        _turnPassword =
            turnPassword ?? const String.fromEnvironment('TURN_PASSWORD');

  final Uri offerUri;
  final String facingMode;
  final int idealWidth;
  final int idealHeight;
  final int idealFps;

  final String? _stunUrl;
  final String? _turnUrl;
  final String? _turnUsername;
  final String? _turnPassword;

  RTCPeerConnection? _pc;
  RTCDataChannel? _dc; // results (unordered, lossy)
  RTCDataChannel? _ctrl; // control (reliable)
  MediaStream? _localStream;
  bool _parsing = false;
  String? _pendingJson; // holds the most recent unparsed JSON

  final RTCVideoRenderer localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();

  /// Low-latency "latest-only" sink for the overlay.
  final ValueNotifier<PoseFrame?> latestFrame = ValueNotifier<PoseFrame?>(null);

  /// Back-compat stream (optional consumers).
  final _framesCtrl = StreamController<PoseFrame>.broadcast();
  Stream<PoseFrame> get frames => _framesCtrl.stream;

  bool _disposed = false;

  // ───────────────────────── State for delta-decoding ('PD') ─────────────────────────
  List<List<Offset>>? _lastPoses; // reference state for deltas
  int _lastPktMs = 0; // last time a results packet arrived (ms)
  bool _needKeyframe = false; // client-side request for a keyframe
  int _lastKfReqMs = 0; // rate-limit KF requests
  int? _expectedSeq; // detects loss/reorder when server adds seq

  // --- optimization ---
  // keep only the most recent binary packet;
  Uint8List? _pendingBin;
  bool _parsingBin = false;

  // ───────────────────────── Media / Peer connection ─────────────────────────
  Future<void> init() async {
    await localRenderer.initialize();
    await remoteRenderer.initialize();

    // Stronger constraints: keep camera from throttling when the scene is static.
    final mediaConstraints = <String, dynamic>{
      'audio': false,
      'video': {
        'facingMode': facingMode,
        'width': {'min': idealWidth, 'ideal': idealWidth, 'max': idealWidth},
        'height': {'min': idealHeight, 'ideal': idealHeight, 'max': idealHeight},
        // IMPORTANT: request a minimum framerate
        'frameRate': {'min': idealFps, 'ideal': idealFps, 'max': idealFps},

        // WebRTC hint: prefer keeping FPS over resolution/bitrate when under load
        'degradationPreference': 'maintain-framerate',

        // Extra knobs some devices honor via the plugin’s mapping:
        'mandatory': {'minFrameRate': idealFps},
        'optional': [
          {'minFrameRate': idealFps},
        ],
      },
    };

    _localStream = await navigator.mediaDevices.getUserMedia(mediaConstraints);

    // Show local preview
    localRenderer.srcObject = _localStream;
  }

  Future<void> connect() async {
    final config = <String, dynamic>{
      'sdpSemantics': 'unified-plan',
      'iceServers': [
        if (_stunUrl != null && _stunUrl!.isNotEmpty) {'urls': _stunUrl},
        if (_turnUrl != null && _turnUrl!.isNotEmpty)
          {
            'urls': _turnUrl,
            if ((_turnUsername ?? '').isNotEmpty) 'username': _turnUsername,
            if ((_turnPassword ?? '').isNotEmpty) 'credential': _turnPassword,
          },
      ],
    };

    _pc = await createPeerConnection(config);

    // Attach local camera
    for (final track in _localStream!.getTracks()) {
      await _pc!.addTrack(track, _localStream!);
    }

    // Keep uplink predictable/low-latency and maintain FPS.
    try {
      final senders = await _pc!.getSenders();
      final vSender = senders.firstWhere(
        (s) => s.track != null && s.track!.kind == 'video',
        orElse: () => throw Exception('No video sender'),
      );

      // Directly set encodings (no getParameters() on some plugin versions).
      final params = RTCRtpParameters(
        encodings: [
          RTCRtpEncoding(
            // Keep FPS steady and avoid big resolution scaling
            maxFramerate: idealFps,
            scaleResolutionDownBy: 1.0,
            numTemporalLayers: 2, // ignored by H.264 but harmless
            // Bitrate budget (tweak to your network)
            maxBitrate: 350 * 1000,
          ),
        ],
      );
      await vSender.setParameters(params);
    } catch (_) {}

    // ───────────── Prefer H.264 encoding (packetization-mode=1 first) ─────────────
    try {
      final transceivers = await _pc!.getTransceivers();
      final vTrans = transceivers.firstWhere(
        (t) => t.sender.track?.kind == 'video' || t.receiver.track?.kind == 'video',
      );

      final caps = await getRtpSenderCapabilities('video');
      final all = caps?.codecs ?? const <RTCRtpCodecCapability>[];

      String _mime(RTCRtpCodecCapability c) =>
          (c.mimeType ?? '').toLowerCase(); // e.g., "video/h264"
      String _fmtp(RTCRtpCodecCapability c) =>
          (c.sdpFmtpLine ?? '').toLowerCase();

      // Build preferred ordering list without using preferredPayloadType.
      final preferred = <RTCRtpCodecCapability>[];
      final seenKeys = <String>{};

      String _codecKey(RTCRtpCodecCapability c) => '${_mime(c)}|${_fmtp(c)}';

      // 1) H.264 first (packetization-mode=1 preferred, then by profile-level-id)
      final h264 = all.where((c) => _mime(c) == 'video/h264').toList();

      int _h264Rank(RTCRtpCodecCapability c) {
        final f = _fmtp(c);
        final pkt = f.contains('packetization-mode=1') ? 0 : 1;
        // Prefer High (640c1f) or Constrained Baseline (42e01f) if available
        final prof = f.contains('profile-level-id=640c1f')
            ? 0
            : (f.contains('profile-level-id=42e01f') ? 1 : 2);
        return pkt * 10 + prof;
      }

      h264.sort((a, b) => _h264Rank(a).compareTo(_h264Rank(b)));
      for (final c in h264) {
        final key = _codecKey(c);
        if (seenKeys.add(key)) preferred.add(c);
      }

      // 2) Fallbacks in sensible real-time order
      final order = <String>[
        'video/vp8',
        'video/vp9',
        'video/h265',
        'video/av1',
      ];

      for (final name in order) {
        for (final c in all) {
          if (_mime(c) == name) {
            final key = _codecKey(c);
            if (seenKeys.add(key)) {
              preferred.add(c);
            }
          }
        }
      }

      if (preferred.isNotEmpty) {
        await vTrans.setCodecPreferences(preferred);
        // print('[client] codec → ${preferred.first.mimeType} ${preferred.first.sdpFmtpLine}');
      }
    } catch (_) {
      // Best-effort: some platforms may not support setting codec preferences.
    }

    // Remote track (if the server returns annotated video)
    _pc!.onTrack = (RTCTrackEvent e) {
      if (e.track.kind == 'video' && e.streams.isNotEmpty) {
        remoteRenderer.srcObject = e.streams.first;
      }
    };

    // ---- Data channels ----

    // RESULTS: unordered + lossy (avoid HoL blocking)
    final dcInit = RTCDataChannelInit()
      ..ordered = false
      ..maxRetransmits = 0;

    void _wireResults(RTCDataChannel ch) {
      ch.onMessage = (RTCDataChannelMessage m) {
        if (m.isBinary) {
          _handlePoseBinary(m.binary);
        } else {
          _handlePoseText(m.text);
        }
      };
    }

    _dc = await _pc!.createDataChannel('results', dcInit);
    _wireResults(_dc!);

    // CTRL: reliable for keyframe (KF) and future control messages
    final ctrlInit = RTCDataChannelInit()..ordered = true;
    _ctrl = await _pc!.createDataChannel('ctrl', ctrlInit);

    // Also listen for server-created/recycled channels.
    _pc!.onDataChannel = (RTCDataChannel ch) {
      if (ch.label == 'results') {
        _dc = ch;
        _wireResults(ch);
      } else if (ch.label == 'ctrl') {
        _ctrl = ch;
      }
    };

    // ---- Signaling ----
    final offer = await _pc!.createOffer();
    await _pc!.setLocalDescription(offer);

    final res = await http.post(
      offerUri,
      headers: const {'content-type': 'application/json'},
      body: jsonEncode({'sdp': offer.sdp, 'type': offer.type}),
    );

    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('Signaling failed: ${res.statusCode} ${res.body}');
    }

    final ans = jsonDecode(res.body) as Map<String, dynamic>;
    final answer = RTCSessionDescription(
      ans['sdp'] as String,
      ans['type'] as String,
    );
    await _pc!.setRemoteDescription(answer);
  }

  // ───────────────────────── Incoming results (JSON fallback) ─────────────────────────
  void _handlePoseText(String text) {
    _pendingJson = text; // Keep only most recent JSON
    if (_parsing) return;
    _drainJsonQueue();
  }

  void _drainJsonQueue() async {
    final text = _pendingJson;
    if (text == null) {
      _parsing = false;
      return;
    }
    _pendingJson = null;
    _parsing = true;

    try {
      final map = await compute(_parseJson, text); // off UI thread
      final pf = poseFrameFromMap(map);
      if (pf != null) {
        latestFrame.value = pf; // triggers only the painter
        if (!_framesCtrl.isClosed) _framesCtrl.add(pf);
      }
    } catch (_) {
      // ignore malformed messages
    } finally {
      if (_pendingJson != null) {
        _drainJsonQueue();
      } else {
        _parsing = false;
      }
    }
  }

  // ───────────────────────── Incoming results (binary fast path) ─────────────────────
  //
  // Supported layouts (little endian):
  // "PO": Absolute pixels
  //   u8 'P', u8 'O', u8 ver, u8 nPoses, u16 imgW, u16 imgH,
  //   repeat nPoses: u8 nPts, repeat nPts: u16 x, u16 y
  //
  // "PD": Delta-coded pixels (bit0 of flags = keyframe)
  //   u8 'P', u8 'D', u8 ver, u8 flags, [u16 seq if ver>=1], u8 nPoses, u16 imgW, u16 imgH,
  //   if keyframe: same body as "PO"
  //   else: for each pose:
  //         u8 nPts,
  //         (ver>=2) ceil(nPts/8) bytes mask (LE)  OR  (ver==1) u64 mask,
  //         then (int8 dx, int8 dy) per bit set
  void _handlePoseBinary(Uint8List bytes) {
    // latest-only: keep newest, drop older; parse on a microtask loop
    _pendingBin = bytes;
    if (_parsingBin) return;
    _drainBinQueue();
  }

  void _drainBinQueue() {
    final pkt = _pendingBin;
    if (pkt == null) {
      _parsingBin = false;
      return;
    }
    _pendingBin = null;
    _parsingBin = true;

    try {
      final pf = _parsePoseBinaryInline(pkt);
      if (pf != null) {
        latestFrame.value = pf;
        if (!_framesCtrl.isClosed) _framesCtrl.add(pf);
      }
    } finally {
      if (_pendingBin != null) {
        // parse the freshest packet soon without blocking the UI thread
        scheduleMicrotask(_drainBinQueue);
      } else {
        _parsingBin = false;
      }
    }
  }

  PoseFrame? _parsePoseBinaryInline(Uint8List bytes) {
    final now = DateTime.now().millisecondsSinceEpoch;

    // If we haven't received packets for a while, request a keyframe.
    if (now - _lastPktMs > 300) {
      _needKeyframe = true;
      _maybeRequestKeyframe(now);
    }
    _lastPktMs = now;

    final bd = ByteData.sublistView(bytes);
    if (bd.lengthInBytes < 8) return null;
    int i = 0;

    final m0 = bd.getUint8(i++), m1 = bd.getUint8(i++);

    // ── Path 1: "PO" absolute packets ──
    if (m0 == 0x50 && m1 == 0x4F) {
      final _ = bd.getUint8(i++); // ver (unused)
      final nPoses = bd.getUint8(i++);
      if (i + 4 > bd.lengthInBytes) return null;
      final w = bd.getUint16(i, Endian.little);
      i += 2;
      final h = bd.getUint16(i, Endian.little);
      i += 2;

      final poses = <List<Offset>>[];
      for (int p = 0; p < nPoses; p++) {
        if (i >= bd.lengthInBytes) break;
        final nPts = bd.getUint8(i++);
        final pts = <Offset>[];
        for (int k = 0; k < nPts; k++) {
          if (i + 4 > bd.lengthInBytes) break;
          final x = bd.getUint16(i, Endian.little).toDouble();
          i += 2;
          final y = bd.getUint16(i, Endian.little).toDouble();
          i += 2;
          pts.add(Offset(x, y));
        }
        poses.add(pts);
      }

      _lastPoses = poses; // seed delta state
      _expectedSeq = null; // absolutes reset seq expectations
      _needKeyframe = false; // satisfied by absolute
      return PoseFrame(
        imageSize: Size(w.toDouble(), h.toDouble()),
        posesPx: poses,
      );
    }

    // ── Path 2: "PD" delta-coded packets ──
    if (m0 != 0x50 || m1 != 0x44) return null; // not "PD"

    final ver = bd.getUint8(i++);
    final flags = bd.getUint8(i++);

    int? seq;
    if (ver >= 1) {
      if (i + 2 > bd.lengthInBytes) return null;
      seq = bd.getUint16(i, Endian.little);
      i += 2;

      // Detect loss/reorder and heal via KF.
      if (_expectedSeq != null && seq != _expectedSeq) {
        _needKeyframe = true;
        _maybeRequestKeyframe(now);
        return null; // don't apply unsafe delta
      }
    }

    if (i + 1 + 2 + 2 > bd.lengthInBytes) return null;
    final nPoses = bd.getUint8(i++);
    final w = bd.getUint16(i, Endian.little);
    i += 2;
    final h = bd.getUint16(i, Endian.little);
    i += 2;

    final isKey = (flags & 1) != 0;
    final poses = <List<Offset>>[];

    // Keyframe in PD => carry absolutes
    if (isKey) {
      for (int p = 0; p < nPoses; p++) {
        if (i >= bd.lengthInBytes) break;
        final nPts = bd.getUint8(i++);
        final pts = <Offset>[];
        for (int k = 0; k < nPts; k++) {
          if (i + 4 > bd.lengthInBytes) {
            _needKeyframe = true;
            _maybeRequestKeyframe(now);
            return null;
          }
          final x = bd.getUint16(i, Endian.little).toDouble();
          i += 2;
          final y = bd.getUint16(i, Endian.little).toDouble();
          i += 2;
          pts.add(Offset(x, y));
        }
        poses.add(pts);
      }
      _lastPoses = poses;
      _needKeyframe = false;
      if (seq != null) _expectedSeq = (seq + 1) & 0xFFFF;
      return PoseFrame(
        imageSize: Size(w.toDouble(), h.toDouble()),
        posesPx: poses,
      );
    }

    // Non-keyframe PD (delta). We need a valid reference for each pose.
    _lastPoses ??= <List<Offset>>[];
    for (int p = 0; p < nPoses; p++) {
      if (i >= bd.lengthInBytes) return null;
      final nPts = bd.getUint8(i++);

      final hasRef = _lastPoses != null &&
          _lastPoses!.length > p &&
          _lastPoses![p].length == nPts;

      if (!hasRef) {
        _needKeyframe = true;
        _maybeRequestKeyframe(now);
        return null;
      }

      // === variable-length mask if ver>=2, else fixed u64 for back-compat ===
      int mask = 0;
      if (ver >= 2) {
        final maskBytes = (nPts + 7) >> 3;
        if (i + maskBytes > bd.lengthInBytes) return null;
        for (int b = 0; b < maskBytes; b++) {
          mask |= (bd.getUint8(i++) << (8 * b));
        }
      } else {
        if (i + 8 > bd.lengthInBytes) return null;
        mask = bd.getUint64(i, Endian.little);
        i += 8;
      }

      final base = List<Offset>.from(_lastPoses![p]);
      for (int k = 0; k < nPts; k++) {
        if (((mask >> k) & 1) != 0) {
          if (i + 2 > bd.lengthInBytes) return null;
          final dx = bd.getInt8(i++).toDouble();
          final dy = bd.getInt8(i++).toDouble();
          final prev = base[k];
          base[k] = Offset(prev.dx + dx, prev.dy + dy);
        }
      }
      poses.add(base);
    }

    _lastPoses = poses;
    if (seq != null) _expectedSeq = (seq + 1) & 0xFFFF;
    return PoseFrame(
      imageSize: Size(w.toDouble(), h.toDouble()),
      posesPx: poses,
    );
  }

  void _maybeRequestKeyframe(int nowMs) {
    // Best effort: ask server to send a keyframe soon (rate-limited).
    if (!_needKeyframe) return;
    if (nowMs - _lastKfReqMs < 300) return;

    final ch = _ctrl ?? _dc; // prefer reliable ctrl, fallback to results
    if (ch == null) return;

    try {
      ch.send(RTCDataChannelMessage('KF'));
      _lastKfReqMs = nowMs;
    } catch (_) {
      // ignore send failures
    }
  }

  // ───────────────────────── Camera controls ─────────────────────────
  Future<void> switchCamera() async {
    final videoTracks = _localStream?.getVideoTracks();
    if (videoTracks == null || videoTracks.isEmpty) return;
    try {
      await Helper.switchCamera(videoTracks.first);
    } catch (_) {}
  }

  Future<void> setTorch(bool on) async {
    final videoTracks = _localStream?.getVideoTracks();
    if (videoTracks == null || videoTracks.isEmpty) return;
    try {
      final track = videoTracks.first;
      if (await track.hasTorch()) {
        await track.setTorch(on);
      }
    } catch (_) {
      // ignore
    }
  }

  // ───────────────────────── Cleanup ─────────────────────────
  Future<void> close() async {
    if (_disposed) return;
    _disposed = true;

    try {
      await _ctrl?.close();
    } catch (_) {}
    try {
      await _dc?.close();
    } catch (_) {}
    try {
      await _pc?.close();
    } catch (_) {}
    try {
      await _localStream?.dispose();
    } catch (_) {}

    await localRenderer.dispose();
    await remoteRenderer.dispose();

    latestFrame.dispose();
    await _framesCtrl.close();
  }
}
