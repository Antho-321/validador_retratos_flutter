// lib/features/posture/services/pose_webrtc_service.dart

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' show Offset, Size;

import 'package:flutter/foundation.dart' show compute, kDebugMode, ValueNotifier;
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
  RTCDataChannel? _dc;    // results (unordered, lossy)
  RTCDataChannel? _ctrl;  // control (reliable)
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
  int _lastPktMs = 0;             // last time a results packet arrived (ms)
  bool _needKeyframe = false;     // client-side request for a keyframe
  int _lastKfReqMs = 0;           // rate-limit KF requests
  int? _expectedSeq;              // detects loss/reorder when server adds seq

  // ───────────────────────── Media / Peer connection ─────────────────────────
  Future<void> init() async {
    await localRenderer.initialize();
    await remoteRenderer.initialize();

    // Stronger constraints: keep camera from throttling when the scene is static.
    final mediaConstraints = <String, dynamic>{
      'audio': false,
      'video': {
        'facingMode': facingMode,
        'width':  {'min': idealWidth,  'ideal': idealWidth,  'max': idealWidth},
        'height': {'min': idealHeight, 'ideal': idealHeight, 'max': idealHeight},
        // IMPORTANT: request a minimum framerate
        'frameRate': {'min': idealFps, 'ideal': idealFps, 'max': idealFps},

        // WebRTC hint: prefer keeping FPS over resolution/bitrate when under load
        'degradationPreference': 'maintain-framerate',

        // Extra knobs some devices honor via the plugin’s mapping:
        'mandatory': {'minFrameRate': idealFps},
        'optional':  [
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

      // Directly set encodings (no getParameters() on your flutter_webrtc version).
      final params = RTCRtpParameters(
        encodings: [
          RTCRtpEncoding(
            // Keep FPS steady and avoid big resolution scaling
            maxFramerate: idealFps,
            scaleResolutionDownBy: 1.0,
            numTemporalLayers: 2,
            // Bitrate budget (tweak to your network)
            maxBitrate: 350 * 1000,
          ),
        ],
      );
      await vSender.setParameters(params);
    } catch (e) {
      if (kDebugMode) {
        // ignore: avoid_print
        print('RTCRtpParameters tuning not available: $e');
      }
    }

    // Prefer codecs if supported (best-effort).
    try {
      final transceivers = await _pc!.getTransceivers();
      final vTrans = transceivers.firstWhere(
        (t) => t.sender.track?.kind == 'video' || t.receiver.track?.kind == 'video',
      );

      final caps = await getRtpSenderCapabilities('video');
      final codecs = caps?.codecs ?? const <RTCRtpCodecCapability>[];

      const prefer = ['VIDEO/AV1', 'VIDEO/H265', 'VIDEO/VP9', 'VIDEO/H264'];
      final prefs = <RTCRtpCodecCapability>[
        for (final mt in prefer)
          ...codecs.where((c) => ((c.mimeType ?? '').toUpperCase()) == mt),
      ];

      if (prefs.isNotEmpty) {
        await vTrans.setCodecPreferences(prefs);
      } else if (kDebugMode) {
        // ignore: avoid_print
        print('No preferred codecs found in capabilities: '
            '${codecs.map((c) => c.mimeType).toList()}');
      }
    } catch (e) {
      if (kDebugMode) {
        // ignore: avoid_print
        print('setCodecPreferences not available/supported: $e');
      }
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
  //   else: for each pose: u8 nPts, u64 bitmask (changed points), then (int8 dx, int8 dy) per bit set
  void _handlePoseBinary(Uint8List bytes) {
    final now = DateTime.now().millisecondsSinceEpoch;

    // If we haven't received packets for a while, request a keyframe (faster).
    if (now - _lastPktMs > 300) {
      _needKeyframe = true;
      _maybeRequestKeyframe(now);
    }
    _lastPktMs = now;

    final bd = ByteData.sublistView(bytes);
    if (bd.lengthInBytes < 8) return;
    int i = 0;

    final m0 = bd.getUint8(i++), m1 = bd.getUint8(i++);

    // ── Path 1: "PO" absolute packets ──
    if (m0 == 0x50 && m1 == 0x4F) {
      final _ = bd.getUint8(i++); // ver (unused)
      final nPoses = bd.getUint8(i++);
      if (i + 4 > bd.lengthInBytes) return;
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

      _lastPoses = poses;          // seed delta state
      _expectedSeq = null;         // absolutes reset seq expectations
      _needKeyframe = false;       // satisfied by absolute
      final pf =
          PoseFrame(imageSize: Size(w.toDouble(), h.toDouble()), posesPx: poses);
      latestFrame.value = pf;
      if (!_framesCtrl.isClosed) _framesCtrl.add(pf);
      return;
    }

    // ── Path 2: "PD" delta-coded packets ──
    if (m0 != 0x50 || m1 != 0x44) return; // not "PD"

    final ver = bd.getUint8(i++);
    final flags = bd.getUint8(i++);

    int? seq;
    if (ver >= 1) {
      if (i + 2 > bd.lengthInBytes) return;
      seq = bd.getUint16(i, Endian.little);
      i += 2;

      // Detect loss/reorder and heal via KF.
      if (_expectedSeq != null && seq != _expectedSeq) {
        _needKeyframe = true;
        _maybeRequestKeyframe(now);
        return; // don't apply unsafe delta
      }
    }

    if (i + 1 + 2 + 2 > bd.lengthInBytes) return;
    final nPoses = bd.getUint8(i++);
    final w = bd.getUint16(i, Endian.little); i += 2;
    final h = bd.getUint16(i, Endian.little); i += 2;

    final isKey = (flags & 1) != 0;
    final poses = <List<Offset>>[];

    // Keyframe in PD => carry absolutes
    if (isKey) {
      for (int p = 0; p < nPoses; p++) {
        if (i >= bd.lengthInBytes) break;
        final nPts = bd.getUint8(i++);
        final pts = <Offset>[];
        for (int k = 0; k < nPts; k++) {
          if (i + 4 > bd.lengthInBytes) { _needKeyframe = true; _maybeRequestKeyframe(now); return; }
          final x = bd.getUint16(i, Endian.little).toDouble(); i += 2;
          final y = bd.getUint16(i, Endian.little).toDouble(); i += 2;
          pts.add(Offset(x, y));
        }
        poses.add(pts);
      }
      _lastPoses = poses;
      _needKeyframe = false;
      if (seq != null) _expectedSeq = (seq + 1) & 0xFFFF;
      final pf =
          PoseFrame(imageSize: Size(w.toDouble(), h.toDouble()), posesPx: poses);
      latestFrame.value = pf;
      if (!_framesCtrl.isClosed) _framesCtrl.add(pf);
      return;
    }

    // Non-keyframe PD (delta). We need a valid reference for each pose.
    _lastPoses ??= <List<Offset>>[];
    for (int p = 0; p < nPoses; p++) {
      if (i >= bd.lengthInBytes) return;
      final nPts = bd.getUint8(i++);

      final hasRef = _lastPoses != null &&
          _lastPoses!.length > p &&
          _lastPoses![p].length == nPts;

      if (!hasRef) {
        _needKeyframe = true;
        _maybeRequestKeyframe(now);
        return;
      }

      if (i + 8 > bd.lengthInBytes) return;
      final mask = bd.getUint64(i, Endian.little);
      i += 8;

      final base = List<Offset>.from(_lastPoses![p]);
      for (int k = 0; k < nPts; k++) {
        if (((mask >> k) & 1) != 0) {
          if (i + 2 > bd.lengthInBytes) return;
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
    final pf = PoseFrame(imageSize: Size(w.toDouble(), h.toDouble()), posesPx: poses);
    latestFrame.value = pf;
    if (!_framesCtrl.isClosed) _framesCtrl.add(pf);
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
      if (kDebugMode) {
        // ignore: avoid_print
        print('Requested keyframe (KF)');
      }
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
    } catch (e) {
      if (kDebugMode) {
        // ignore: avoid_print
        print('switchCamera not supported on this device: $e');
      }
    }
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
