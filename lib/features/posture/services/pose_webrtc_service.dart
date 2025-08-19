// lib/features/posture/services/pose_webrtc_service.dart
//
// NOTE: If you want to use a non-libwebrtc encoder on Android,
// you must inject a custom VideoEncoderFactory in the NATIVE plugin
// (see the Kotlin patch after this file). This Dart code stays the same;
// the encoder used is decided by the native PeerConnectionFactory.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset, Size;

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;

import '../presentation/widgets/overlays.dart' show PoseFrame, poseFrameFromMap;

/// Parse JSON safely into a `Map<String, dynamic>`.
Map<String, dynamic> _parseJson(String text) =>
    jsonDecode(text) as Map<String, dynamic>;

class PoseWebRTCService {
  PoseWebRTCService({
    required this.offerUri,
    this.facingMode = 'user',
    // Match Python client by default (16:9 @ 30fps)
    this.idealWidth = 640,
    this.idealHeight = 360,
    this.idealFps = 30,
    this.maxBitrateKbps = 800,
    String? stunUrl,
    String? turnUrl,
    String? turnUsername,
    String? turnPassword,
    this.preferHevc = false,
    // If true, pre-create DCs so OFFER contains m=application
    this.preCreateDataChannels = true,
    // If no results for N seconds, nudge server; try negotiated DCs only if
    // channels are not open
    this.negotiatedFallbackAfterSeconds = 5,
  })  : _stunUrl = stunUrl ?? 'stun:stun.l.google.com:19302',
        _turnUrl = turnUrl,
        _turnUsername = turnUsername,
        _turnPassword = turnPassword;

  final Uri offerUri;
  final String facingMode;
  final int idealWidth;
  final int idealHeight;
  final int idealFps;
  final int maxBitrateKbps;
  final bool preferHevc;
  final bool preCreateDataChannels;
  final int negotiatedFallbackAfterSeconds;

  final String? _stunUrl;
  final String? _turnUrl;
  final String? _turnUsername;
  final String? _turnPassword;

  RTCPeerConnection? _pc;
  RTCDataChannel? _dc; // 'results' (unordered, lossy)
  RTCDataChannel? _ctrl; // 'ctrl' (reliable)
  MediaStream? _localStream;
  RTCRtpTransceiver? _videoTransceiver;

  Timer? _rtpStatsTimer;
  Timer? _dcGuardTimer;
  bool _disposed = false;

  final RTCVideoRenderer localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();
  final ValueNotifier<PoseFrame?> latestFrame = ValueNotifier<PoseFrame?>(null);

  final _framesCtrl = StreamController<PoseFrame>.broadcast();
  Stream<PoseFrame> get frames => _framesCtrl.stream;

  // ─────── Binary PO/PD state ───────
  List<List<Offset>>? _lastPoses;
  int? _expectedSeq;
  int _parseErrors = 0;

  // ================================
  // Lifecycle
  // ================================

  Future<void> init() async {
    print('[client] init()');
    await localRenderer.initialize();
    await remoteRenderer.initialize();
    print('[client] renderers initialized');

    final mediaConstraints = <String, dynamic>{
      'audio': false,
      'video': {
        'facingMode': facingMode,
        'mandatory': {
          'minWidth': '$idealWidth',
          'maxWidth': '$idealWidth',
          'minHeight': '$idealHeight',
          'maxHeight': '$idealHeight',
          'minFrameRate': '$idealFps',
          'maxFrameRate': '$idealFps',
        },
        'optional': [],
        'degradationPreference': 'maintain-framerate',
      },
    };

    print('[client] getUserMedia constraints: ${mediaConstraints['video']}');

    _localStream = await navigator.mediaDevices.getUserMedia(mediaConstraints);
    localRenderer.srcObject = _localStream;

    print(
      '[client] local stream acquired: '
      'videoTracks=${_localStream!.getVideoTracks().length}',
    );
  }

  Future<void> connect() async {
    print(
      '[client] connect() STUN=${_stunUrl ?? "-"} '
      'TURN=${_turnUrl != null ? "True" : "False"} '
      'preferHevc=$preferHevc',
    );

    // ── UPDATED: added iceCandidatePoolSize: 4 ──────────────────────────────
    final config = <String, dynamic>{
      'sdpSemantics': 'unified-plan',
      'bundlePolicy': 'max-bundle',
      'iceCandidatePoolSize': 4,
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
    print('[client] RTCPeerConnection created');

    _pc!.onIceGatheringState = (state) {
      print('[client] ICE gathering: $state');
    };
    _pc!.onIceConnectionState = (state) {
      print('[client] ICE connection: $state');
    };
    _pc!.onSignalingState = (state) {
      print('[client] signaling state: $state');
    };
    _pc!.onConnectionState = (state) {
      print('[client] peer connection state: $state');
    };
    _pc!.onRenegotiationNeeded = () {
      print('[client] on-negotiation-needed');
    };

    // Data channels: optionally pre-create so the OFFER carries m=application.
    if (preCreateDataChannels) {
      _dc = await _pc!.createDataChannel(
        'results',
        RTCDataChannelInit()
          ..ordered = false
          ..maxRetransmits = 0,
      );
      print("[client] created datachannel 'results' id=${_dc!.id}");
      _wireResults(_dc!);

      _ctrl = await _pc!.createDataChannel('ctrl', RTCDataChannelInit());
      print("[client] created datachannel 'ctrl' id=${_ctrl!.id}");
      _wireCtrl(_ctrl!);

      print(
        "[client] pre-offer datachannels 'results' (unordered, maxRetransmits=0) "
        "and 'ctrl' (reliable) created",
      );
    } else {
      print(
        "[client] preCreateDataChannels=false → waiting for peer-announced channels",
      );
    }

    // Always adopt peer-announced channels if they arrive.
    _pc!.onDataChannel = (RTCDataChannel ch) {
      print("[client] datachannel announced by peer: ${ch.label} id=${ch.id}");
      if (ch.label == 'results') {
        _dc = ch;
        _wireResults(ch);
      } else if (ch.label == 'ctrl') {
        _ctrl = ch;
        _wireCtrl(ch);
      }
    };

    // Add video as sendonly.
    final videoTrack = _localStream!.getVideoTracks().first;
    _videoTransceiver = await _pc!.addTransceiver(
      track: videoTrack,
      init: RTCRtpTransceiverInit(direction: TransceiverDirection.SendOnly),
    );
    print('[client] video transceiver added as SendOnly');

    _pc!.onTrack = (RTCTrackEvent e) {
      print(
        '[client] onTrack kind=${e.track.kind} streams=${e.streams.length}',
      );
      if (e.track.kind == 'video' && e.streams.isNotEmpty) {
        remoteRenderer.srcObject = e.streams.first;
        print('[client] remote video bound to renderer');
      }
    };

    // ─────────────────────────────────────────────────────────────
    // Prefer codecs — PREFER H.264 (fallback allowed if missing)
    // ─────────────────────────────────────────────────────────────
    try {
      final caps = await getRtpSenderCapabilities('video');
      final all = caps?.codecs ?? const <RTCRtpCodecCapability>[];

      // Pick H.264 variants first (prefer packetization-mode=1).
      final h264First = all.where((c) {
        final mime = (c.mimeType ?? '').toLowerCase();
        final fmtp = (c.sdpFmtpLine ?? '').toLowerCase();
        return mime == 'video/h264' &&
            (fmtp.contains('packetization-mode=1') || fmtp.isEmpty);
      }).toList();

      if (h264First.isEmpty) {
        print('[client] H.264 not supported on this device.');
      } else {
        // Put H.264 first, then append everything else for graceful fallback.
        final preferred = <RTCRtpCodecCapability>[
          ...h264First,
          ...all.where((c) => !h264First.contains(c)),
        ];
        await _videoTransceiver!.setCodecPreferences(preferred);
        print('[client] preferring H.264 (${h264First.length} variant(s))');
      }

      // Keep your existing sender params (bitrate/FPS) as-is
      await _videoTransceiver!.sender.setParameters(
        RTCRtpParameters(
          encodings: [
            RTCRtpEncoding(
              maxFramerate: idealFps,
              scaleResolutionDownBy: 1.0,
              maxBitrate: 1_500 * 1000,
            ),
          ],
        ),
      );
    } catch (e) {
      print('[client] codec preference failed (best-effort): $e');
    }

    // Cap bitrate/FPS so encoder queue doesn't overflow.
    await _applySenderLimits(maxKbps: maxBitrateKbps, maxFps: idealFps);

    // Create offer and log SDP parts like the Python client
    print('[client] creating offer…');
    final offer = await _pc!.createOffer({});
    final hasApp = (offer.sdp?.contains('m=application') ?? false);
    print('[client] offer created (has m=application: $hasApp )');

    await _pc!.setLocalDescription(offer);
    print('[client] local description set');

    _dumpSdp('local-offer', offer.sdp);

    await _waitIceGatheringComplete(_pc!);

    final local = await _pc!.getLocalDescription();

    print('[client] posting offer to server…');
    final res = await http.post(
      offerUri,
      headers: const {'content-type': 'application/json'},
      body: jsonEncode({'type': local!.type, 'sdp': local.sdp}),
    );

    if (res.statusCode < 200 || res.statusCode >= 300) {
      print('[client] signaling failed: ${res.statusCode} ${res.body}');
      throw Exception('Signaling failed: ${res.statusCode} ${res.body}');
    }

    final ansMap = jsonDecode(res.body) as Map<String, dynamic>;
    await _pc!.setRemoteDescription(
      RTCSessionDescription(
        ansMap['sdp'] as String,
        (ansMap['type'] as String?) ?? 'answer',
      ),
    );

    final ansSdp = (ansMap['sdp'] as String?) ?? '';
    print(
      "[client] remote answer has m=application: "
      "${ansSdp.contains('m=application')}",
    );
    print('[client] remote answer set');

    _dumpSdp('remote-answer', ansSdp);

    _startRtpStatsProbe();
    _startNoResultsGuard();
  }

  // ================================
  // Helpers (apply limits, ICE, etc.)
  // ================================

  Future<void> _applySenderLimits({
    required int maxKbps,
    required int maxFps,
  }) async {
    try {
      final sender = _videoTransceiver?.sender;
      if (sender == null) return;

      print(
        '[client] applying sender limits: '
        'maxBitrate=${maxKbps}kbps, maxFramerate=$maxFps',
      );

      await sender.setParameters(
        RTCRtpParameters(
          encodings: [
            RTCRtpEncoding(
              maxBitrate: maxKbps * 1000,
              maxFramerate: maxFps,
              scaleResolutionDownBy: 1.0,
            ),
          ],
        ),
      );

      print('[client] sender limits applied');
    } catch (e) {
      print('[client] sender limits best-effort failed: $e');
    }
  }

  Future<void> _waitIceGatheringComplete(RTCPeerConnection pc) async {
    if (pc.iceGatheringState ==
        RTCIceGatheringState.RTCIceGatheringStateComplete) {
      return;
    }

    final c = Completer<void>();
    final prev = pc.onIceGatheringState;

    pc.onIceGatheringState = (s) {
      if (prev != null) prev(s);
      if (s == RTCIceGatheringState.RTCIceGatheringStateComplete &&
          !c.isCompleted) {
        print('[client] ICE gathering complete');
        c.complete();
        pc.onIceGatheringState = prev;
      }
    };

    Timer(const Duration(seconds: 2), () {
      if (!c.isCompleted) {
        print('[client] ICE gathering timeout — continuing');
        c.complete();
        pc.onIceGatheringState = prev;
      }
    });

    return c.future;
  }

  // ================================
  // Data channels
  // ================================

  void _wireResults(RTCDataChannel ch) {
    ch.onDataChannelState = (s) {
      if (s == RTCDataChannelState.RTCDataChannelOpen) {
        print("[client] 'results' open (id=${ch.id})");
      } else if (s == RTCDataChannelState.RTCDataChannelClosed) {
        print("[client] 'results' closed (id=${ch.id})");
      }
    };

    ch.onMessage = (RTCDataChannelMessage m) {
      // UNIVERSAL MESSAGE LOGGER (before parsing)
      if (m.isBinary) {
        final bin = m.binary;
        final head = bin.length >= 2
            ? '${bin[0].toRadixString(16)} ${bin[1].toRadixString(16)}'
            : '<short>';
        print("[client] results RECV bin len=${bin.length} head=$head");
      } else {
        final t = m.text ?? '';
        final preview = t.length <= 48 ? t : t.substring(0, 48);
        print(
          "[client] results RECV txt len=${t.length} "
          "preview='${preview.replaceAll('\n', ' ')}'",
        );
      }

      // Actual handling
      if (m.isBinary) {
        try {
          _handlePoseBinary(m.binary);
        } catch (e) {
          print('[client] error parsing results packet: $e');
          _sendCtrlKF();
        }
      } else {
        final txtRaw = m.text ?? '';
        final txt = txtRaw.trim();
        if (txt.toUpperCase() == 'KF') {
          print(
            "[client] 'results' got KF request (string) — ignoring on client",
          );
        } else {
          _handlePoseText(txtRaw);
        }
      }
    };
  }

  void _wireCtrl(RTCDataChannel ch) {
    ch.onDataChannelState = (s) {
      if (s == RTCDataChannelState.RTCDataChannelOpen) {
        print("[client] 'ctrl' open (id=${ch.id})");
        _nudgeServer();
      } else if (s == RTCDataChannelState.RTCDataChannelClosed) {
        print("[client] 'ctrl' closed (id=${ch.id})");
      }
    };

    ch.onMessage = (RTCDataChannelMessage m) {
      if (m.isBinary) {
        print('[client] ctrl RECV bin len=${m.binary.length}');
      } else {
        final t = m.text ?? '';
        final prev = t.length <= 48 ? t : t.substring(0, 48);
        print(
          "[client] ctrl RECV txt len=${t.length} "
          "preview='${prev.replaceAll('\n', ' ')}'",
        );
      }
    };
  }

  void _nudgeServer() {
    final c = _ctrl;
    if (c == null) return;
    if (c.state != RTCDataChannelState.RTCDataChannelOpen) return;

    print('[client] ctrl nudge: HELLO + KF');
    c.send(RTCDataChannelMessage('HELLO'));
    c.send(RTCDataChannelMessage('KF'));
  }

  Future<void> _recreateNegotiatedChannels() async {
    final pc = _pc;
    if (pc == null) return;

    // Only attempt if channels are absent or closed.
    if (_dc?.state == RTCDataChannelState.RTCDataChannelOpen ||
        _ctrl?.state == RTCDataChannelState.RTCDataChannelOpen) {
      print('[client] negotiated fallback skipped — channels already open');
      return;
    }

    try {
      await _dc?.close();
    } catch (_) {}
    try {
      await _ctrl?.close();
    } catch (_) {}

    _dc = null;
    _ctrl = null;

    Future<RTCDataChannel?> _tryCreate(
      String label,
      int id, {
      required bool lossy,
    }) async {
      try {
        final init = RTCDataChannelInit()
          ..negotiated = true
          ..id = id
          ..ordered = !lossy;

        if (lossy) {
          // NOTE: cannot set null on some plugin versions; set only when lossy
          init.maxRetransmits = 0;
        }

        final ch = await pc.createDataChannel(label, init);
        print("[client] created negotiated DC '$label' id=$id");
        return ch;
      } catch (e) {
        print("[client] failed to create negotiated DC '$label' id=$id: $e");
        return null;
      }
    }

    final newResults = await _tryCreate('results', 0, lossy: true);
    final newCtrl = await _tryCreate('ctrl', 1, lossy: false);

    if (newResults == null || newCtrl == null) {
      print(
        "[client] negotiated fallback aborted — "
        "could not create DCs (ids may be in use)",
      );
      return;
    }

    _dc = newResults;
    _wireResults(_dc!);

    _ctrl = newCtrl;
    _wireCtrl(_ctrl!);
  }

  // ================================
  // JSON Fallback
  // ================================

  void _handlePoseText(String text) {
    try {
      final m = _parseJson(text);
      final frame = poseFrameFromMap(m);
      latestFrame.value = frame;

      if (frame != null && !_framesCtrl.isClosed) {
        _framesCtrl.add(frame);
      }

      print('[client] results: JSON pose(s) -> emitted frame');
    } catch (e) {
      print('[client] JSON pose parse error: $e -> requesting KF');
      _sendCtrlKF();
    }
  }

  // ================================
  // Binary PO/PD Parsing
  // ================================

  void _handlePoseBinary(Uint8List b) {
    try {
      if (b.length < 2) return;

      if (b[0] == 0x50 && b[1] == 0x4F) {
        final parsed = _parsePO(b);
        _lastPoses = parsed.poses;
        _expectedSeq = null;

        print(
          '[client] results: PO ${parsed.poses.length} pose(s) '
          '${parsed.w}x${parsed.h}',
        );

        _emitBinary(parsed.w, parsed.h, parsed.poses, kind: 'PO', seq: null);
        return;
      }

      if (b[0] == 0x50 && b[1] == 0x44) {
        final parsed = _parsePD(b, _lastPoses);
        _lastPoses = parsed.poses;

        if (_expectedSeq != null && parsed.seq != _expectedSeq) {
          print(
            '[client] PD seq mismatch: got=${parsed.seq} expected=$_expectedSeq -> requesting KF',
          );
          _sendCtrlKF();
          _expectedSeq = null;
        }

        _expectedSeq = (parsed.seq + 1) & 0xFFFF;

        print(
          '[client] results: PD seq=${parsed.seq} '
          '${parsed.poses.length} pose(s) ${parsed.w}x${parsed.h}',
        );

        _emitBinary(parsed.w, parsed.h, parsed.poses,
            kind: 'PD', seq: parsed.seq);
        _sendCtrlAck(parsed.seq);
        return;
      }

      print(
        '[client] unknown binary packet head: '
        '${b[0].toRadixString(16)} ${b[1].toRadixString(16)} -> KF',
      );
      _sendCtrlKF();
    } catch (e) {
      _parseErrors++;
      print('[client] binary parse error #$_parseErrors: $e -> KF');
      _sendCtrlKF();
    }
  }

  ({int w, int h, List<List<Offset>> poses}) _parsePO(Uint8List b) {
    int i = 2;
    if (i >= b.length) throw StateError('PO missing ver');
    i++; // ver

    if (i + 1 + 2 + 2 > b.length) {
      throw StateError('PO header short');
    }

    final nposes = b[i];
    i += 1;

    final w = b[i] | (b[i + 1] << 8);
    i += 2;

    final h = b[i] | (b[i + 1] << 8);
    i += 2;

    final poses = <List<Offset>>[];

    for (int p = 0; p < nposes; p++) {
      if (i >= b.length) throw StateError('PO npts short');
      final npts = b[i];
      i += 1;

      final need = npts * 4;
      if (i + need > b.length) throw StateError('PO pts short');

      final pts = <Offset>[];
      for (int k = 0; k < npts; k++) {
        final x = b[i] | (b[i + 1] << 8);
        i += 2;
        final y = b[i] | (b[i + 1] << 8);
        i += 2;
        pts.add(Offset(x.toDouble(), y.toDouble()));
      }

      poses.add(pts);
    }

    return (w: w, h: h, poses: poses);
  }

  ({int w, int h, int seq, List<List<Offset>> poses}) _parsePD(
    Uint8List b,
    List<List<Offset>>? prev,
  ) {
    int i = 2;
    if (i + 1 + 1 + 2 + 1 + 2 + 2 > b.length) {
      throw StateError('PD header short');
    }

    i++; // ver
    final flags = b[i];
    i += 1;

    final seq = b[i] | (b[i + 1] << 8);
    i += 2;

    final nposes = b[i];
    i += 1;

    final w = b[i] | (b[i + 1] << 8);
    i += 2;

    final h = b[i] | (b[i + 1] << 8);
    i += 2;

    final isKey = (flags & 1) != 0;

    if (isKey || prev == null) {
      final poses = <List<Offset>>[];
      for (int p = 0; p < nposes; p++) {
        if (i >= b.length) throw StateError('PD KF npts short');
        final npts = b[i];
        i += 1;

        final need = npts * 4;
        if (i + need > b.length) throw StateError('PD KF pts short');

        final pts = <Offset>[];
        for (int k = 0; k < npts; k++) {
          final x = b[i] | (b[i + 1] << 8);
          i += 2;
          final y = b[i] | (b[i + 1] << 8);
          i += 2;
          pts.add(Offset(x.toDouble(), y.toDouble()));
        }
        poses.add(pts);
      }
      return (w: w, h: h, seq: seq, poses: poses);
    } else {
      if (prev.length != nposes) {
        throw StateError('PD Δ nposes mismatch');
      }

      final poses = <List<Offset>>[];
      for (int p = 0; p < nposes; p++) {
        if (i >= b.length) throw StateError('PD Δ npts short');
        final npts = b[i];
        i += 1;

        final maskBytes = ((npts + 7) >> 3);
        if (i + maskBytes > b.length) {
          throw StateError('PD Δ mask short');
        }

        int mask = 0;
        for (int mb = 0; mb < maskBytes; mb++) {
          mask |= (b[i + mb] << (8 * mb));
        }
        i += maskBytes;

        final prevPts = prev[p];
        if (prevPts.length != npts) {
          throw StateError('PD Δ npts mismatch');
        }

        final out = <Offset>[];
        for (int j = 0; j < npts; j++) {
          int x = prevPts[j].dx.toInt();
          int y = prevPts[j].dy.toInt();

          if (((mask >> j) & 1) == 1) {
            if (i + 2 > b.length) {
              throw StateError('PD Δ dxdy short');
            }
            int dx = _asInt8(b[i]);
            i += 1;
            int dy = _asInt8(b[i]);
            i += 1;
            x += dx;
            y += dy;
          }

          x = math.max(0, math.min(w - 1, x));
          y = math.max(0, math.min(h - 1, y));
          out.add(Offset(x.toDouble(), y.toDouble()));
        }

        poses.add(out);
      }
      return (w: w, h: h, seq: seq, poses: poses);
    }
  }

  int _asInt8(int u) => (u & 0x80) != 0 ? (u - 256) : u;

  void _emitBinary(
    int w,
    int h,
    List<List<Offset>> poses, {
    required String kind,
    int? seq,
  }) {
    if (_disposed) return;

    final frame = PoseFrame(
      imageSize: Size(w.toDouble(), h.toDouble()),
      posesPx: poses,
    );

    print(
      '[client] emit frame kind=$kind seq=${seq ?? "-"} '
      'poses=${poses.length} size=${w}x$h',
    );

    latestFrame.value = frame;
    if (!_framesCtrl.isClosed) {
      _framesCtrl.add(frame);
    }
  }

  void _sendCtrlKF() {
    final c = _ctrl;
    if (c == null || c.state != RTCDataChannelState.RTCDataChannelOpen) return;

    print('[client] sending KF request over ctrl');
    c.send(RTCDataChannelMessage('KF'));
  }

  void _sendCtrlAck(int seq) {
    final c = _ctrl;
    if (c == null || c.state != RTCDataChannelState.RTCDataChannelOpen) return;

    final out = Uint8List(5);
    out[0] = 0x41; // 'A'
    out[1] = 0x43; // 'C'
    out[2] = 0x4B; // 'K'
    out[3] = (seq & 0xFF);
    out[4] = ((seq >> 8) & 0xFF);

    print('[client] sending ACK seq=$seq over ctrl');
    c.send(RTCDataChannelMessage.fromBinary(out));
  }

  // ================================
  // Diagnostics
  // ================================

  void _dumpSdp(String tag, String? sdp) {
    if (sdp == null) return;
    final lines = sdp.split(RegExp(r'\r?\n'));

    final take = <String>[];
    bool inVideo = false;

    for (final l in lines) {
      if (l.startsWith('m=')) inVideo = l.startsWith('m=video');
      if (inVideo &&
          (l.startsWith('m=video') ||
              l.startsWith('a=rtpmap:') ||
              l.startsWith('a=fmtp:'))) {
        take.add(l);
      }
    }

    print('--- ['+tag+'] SDP video ---\n${take.join('\n')}\n------------------------');
  }

  void _startRtpStatsProbe() {
    _rtpStatsTimer?.cancel();
    _rtpStatsTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      final pc = _pc;
      if (pc == null) return;

      try {
        final reports = await pc.getStats();
        for (final r in reports) {
          if (r.type == 'outbound-rtp' &&
              (r.values['kind'] == 'video' ||
                  r.values['mediaType'] == 'video')) {
            final p = r.values['packetsSent'];
            final b = r.values['bytesSent'];
            print('[RTP] video packetsSent=$p bytesSent=$b');
          }
        }
      } catch (e) {
        print('[client] stats probe error: $e');
      }
    });
    print('[client] RTP stats probe started (2s)');
  }

  void _startNoResultsGuard() {
    _dcGuardTimer?.cancel();
    if (negotiatedFallbackAfterSeconds <= 0) return;

    _dcGuardTimer = Timer(
      Duration(seconds: negotiatedFallbackAfterSeconds),
      () async {
        if (_disposed) return;
        if (latestFrame.value != null) return;

        final dcOpen = _dc?.state == RTCDataChannelState.RTCDataChannelOpen;
        final ctrlOpen = _ctrl?.state == RTCDataChannelState.RTCDataChannelOpen;

        // If channels are open, don't try creating negotiated ones — just nudge.
        if (dcOpen || ctrlOpen) {
          print(
            '[client] no results yet, channels open → re-nudge (HELLO+KF)',
          );
          _nudgeServer();
          return;
        }

        // Channels not open: try negotiated(0/1) once.
        print(
          '[client] no results and channels not open → trying negotiated DCs (0/1)',
        );
        await _recreateNegotiatedChannels();
      },
    );
  }

  // ================================
  // Camera and cleanup
  // ================================

  Future<void> switchCamera() async {
    final tracks = _localStream?.getVideoTracks();
    if (tracks == null || tracks.isEmpty) return;

    try {
      await Helper.switchCamera(tracks.first);
      print('[client] camera switched');
      await _applySenderLimits(maxKbps: maxBitrateKbps, maxFps: idealFps);
    } catch (e) {
      print('[client] switchCamera failed: $e');
    }
  }

  Future<void> close() => dispose();

  Future<void> dispose() async {
    _disposed = true;
    print('[client] dispose()');

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
      await localRenderer.dispose();
    } catch (_) {}
    try {
      await remoteRenderer.dispose();
    } catch (_) {}
    try {
      await _localStream?.dispose();
    } catch (_) {}

    _rtpStatsTimer?.cancel();
    _dcGuardTimer?.cancel();
    await _framesCtrl.close();

    print('[client] disposed');
  }
}
