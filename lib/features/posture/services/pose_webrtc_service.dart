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
  })  : _stunUrl = stunUrl ?? const String.fromEnvironment(
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
  RTCDataChannel? _dc;
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

  Future<void> init() async {
    await localRenderer.initialize();
    await remoteRenderer.initialize();

    final mediaConstraints = <String, dynamic>{
      'audio': false,
      'video': {
        'facingMode': facingMode,
        'width': {'ideal': idealWidth},
        'height': {'ideal': idealHeight},
        'frameRate': {'ideal': idealFps, 'max': 30},
      }
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

    // Attach local camera to PeerConnection
    for (final track in _localStream!.getTracks()) {
      await _pc!.addTrack(track, _localStream!);
    }

    // Try to keep uplink predictable/low-latency.
try {
  final senders = await _pc!.getSenders();
  final vSender = senders.firstWhere(
    (s) => s.track != null && s.track!.kind == 'video',
    orElse: () => throw Exception('No video sender'),
  );

  // Build parameters directly; don't call getParameters() (not available in your version)
  final params = RTCRtpParameters(
    encodings: [
      RTCRtpEncoding(
        maxBitrate: 300 * 1000, // ~300 kbps for 640x480@15
        maxFramerate: idealFps, // <-- int, not double
      ),
    ],
  );

  await vSender.setParameters(params);
} catch (e) {
  if (kDebugMode) {
    // ignore: avoid_print
    print('Setting RTCRtpParameters failed/unsupported: $e');
  }
}

    // Remote track (if the server returns annotated video)
    _pc!.onTrack = (RTCTrackEvent e) {
      if (e.track.kind == 'video' && e.streams.isNotEmpty) {
        remoteRenderer.srcObject = e.streams.first;
      }
    };

    // ---- Data channel for pose results ----
    // Unreliable + unordered => drop late packets, keep latest-only behavior
    final dcInit = RTCDataChannelInit()
      ..ordered = false
      ..maxRetransmits = 0;
    _dc = await _pc!.createDataChannel('results', dcInit);

    void _wireChannel(RTCDataChannel ch) {
      ch.onMessage = (RTCDataChannelMessage m) {
        if (m.isBinary) {
          _handlePoseBinary(m.binary);
        } else {
          _handlePoseText(m.text);
        }
      };
    }

    _wireChannel(_dc!);
    _pc!.onDataChannel = (RTCDataChannel ch) {
      if (ch.label == 'results') {
        _dc = ch;
        _wireChannel(_dc!);
      }
    };

    // Offer/Answer (HTTP signaling)
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
    // Keep only the most recent JSON; drop older ones while we are parsing.
    _pendingJson = text;
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
        latestFrame.value = pf; // triggers only the painter via ValueListenable
        if (!_framesCtrl.isClosed) _framesCtrl.add(pf);
      }
    } catch (_) {
      // ignore malformed messages
    } finally {
      // If more JSON arrived while parsing, loop once more with the newest one.
      if (_pendingJson != null) {
        _drainJsonQueue();
      } else {
        _parsing = false;
      }
    }
  }

  // ───────────────────────── Incoming results (binary fast path) ─────────────────────
  //
  // Binary packet layout (little endian):
  // u8  'P' (0x50)
  // u8  'O' (0x4F)
  // u8  version (0)
  // u8  numPoses (N)
  // u16 imgWidth
  // u16 imgHeight
  // Repeat N times:
  //   u8  numPts (M, e.g., 33)
  //   Repeat M times:
  //     u16 x_px
  //     u16 y_px
void _handlePoseBinary(Uint8List bytes) {
  // Use a ByteData view that respects the list's offset/length.
  // Either of these two lines is fine:
  final bd = ByteData.sublistView(bytes);
  // or: final bd = bytes.buffer.asByteData(bytes.offsetInBytes, bytes.lengthInBytes);

  if (bytes.lengthInBytes < 8) return;
  int i = 0;

  final m0 = bd.getUint8(i++), m1 = bd.getUint8(i++);
  if (m0 != 0x50 || m1 != 0x4F) return; // not "PO"

  final ver = bd.getUint8(i++); // currently 0 (unused)
  final nPoses = bd.getUint8(i++);
  if (i + 4 > bd.lengthInBytes) return;

  final w = bd.getUint16(i, Endian.little); i += 2;
  final h = bd.getUint16(i, Endian.little); i += 2;

  final poses = <List<Offset>>[];
  for (int p = 0; p < nPoses; p++) {
    if (i >= bd.lengthInBytes) break;
    final nPts = bd.getUint8(i++);
    final pts = <Offset>[];
    for (int k = 0; k < nPts; k++) {
      if (i + 4 > bd.lengthInBytes) break; // guard short packets
      final x = bd.getUint16(i, Endian.little).toDouble(); i += 2;
      final y = bd.getUint16(i, Endian.little).toDouble(); i += 2;
      pts.add(Offset(x, y));
    }
    poses.add(pts);
  }

  final pf = PoseFrame(imageSize: Size(w.toDouble(), h.toDouble()), posesPx: poses);
  latestFrame.value = pf;
  if (!_framesCtrl.isClosed) _framesCtrl.add(pf);
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
      // Not supported on many devices; ignore.
    }
  }

  // ───────────────────────── Cleanup ─────────────────────────
  Future<void> close() async {
    if (_disposed) return;
    _disposed = true;

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
