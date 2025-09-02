// lib/features/posture/services/pose_webrtc_service.dart
//
// NOTE: If you want to use a non-libwebrtc encoder on Android,
// you must inject a custom VideoEncoderFactory in the NATIVE plugin
// (see the Kotlin patch after this file). This Dart code stays the same;
// the encoder used is decided by the native PeerConnectionFactory.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' show Offset, Size;

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;

import '../presentation/widgets/overlays.dart' show PoseFrame, poseFrameFromMap;
import 'webrtc/rtc_video_encoder.dart'; // ← centralized encoder configuration
import 'parsers/pose_binary_parser.dart'; // ← isolated PO/PD parser

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
    this.negotiatedFallbackAfterSeconds = 3,
    // NEW: master logging switch — when false, this class prints nothing
    this.logEverything = true,
    // NEW: strip FEC payloads from video m-section to reduce latency
    this.stripFecFromSdp = true,
    // NEW: also strip RTX/NACK/REMB, keep only transport-cc for BWE
    this.stripRtxAndNackFromSdp = true,
    this.keepTransportCcOnly = true,
    this.requestedTasks = const ['pose', 'face'], // primary='pose', extra='face'
    RtcVideoEncoder? encoder, // (DI optional)
  })  : _stunUrl = stunUrl ?? 'stun:stun.l.google.com:19302',
        _turnUrl = turnUrl,
        _turnUsername = turnUsername,
        _turnPassword = turnPassword,
        encoder = encoder ??
            RtcVideoEncoder(
              idealFps: idealFps,
              maxBitrateKbps: maxBitrateKbps,
              preferHevc: preferHevc,
            );

  final Uri offerUri;
  final String facingMode;
  final int idealWidth;
  final int idealHeight;
  final int idealFps;
  final int maxBitrateKbps;
  final bool preferHevc;
  final bool preCreateDataChannels;
  final int negotiatedFallbackAfterSeconds;

  /// When true, log detailed diagnostics; when false, suppress ALL prints
  /// from this class (third-party/native logs may still appear).
  final bool logEverything;

  /// When true, strip FEC codecs (RED/ULPFEC/FlexFEC) from the video m-line
  /// in the local SDP offer to minimize buffering/overhead.
  final bool stripFecFromSdp;

  /// When true, strip RTX payloads and generic NACK/PLI/FIR/REMB; keep only transport-cc.
  final bool stripRtxAndNackFromSdp;

  /// If [stripRtxAndNackFromSdp] is true, keep only a=rtcp-fb:* transport-cc.
  final bool keepTransportCcOnly;

  /// Tasks to request from the server's adapters (e.g., ['pose'], or ['pose','face'])
  final List<String> requestedTasks;

  String get _primaryTask =>
      (requestedTasks.isNotEmpty ? requestedTasks.first : 'pose').toLowerCase();

  final String? _stunUrl;
  final String? _turnUrl;
  final String? _turnUsername;
  final String? _turnPassword;

  // ← centralized encoder
  final RtcVideoEncoder encoder;

  RTCPeerConnection? _pc;

  // Primary 'results' (alias) + per-task maps
  RTCDataChannel? _dc; // 'results' for primary task
  RTCDataChannel? _ctrl; // 'ctrl'
  final Map<String, RTCDataChannel> _resultsPerTask = {}; // task -> DC

  MediaStream? _localStream;
  MediaStream? get localStream => _localStream; // ← added getter
  RTCRtpTransceiver? _videoTransceiver;

  Timer? _rtpStatsTimer;
  Timer? _dcGuardTimer;
  bool _disposed = false;

  final RTCVideoRenderer localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();
  final ValueNotifier<PoseFrame?> latestFrame = ValueNotifier<PoseFrame?>(null);

  final _framesCtrl = StreamController<PoseFrame>.broadcast();
  Stream<PoseFrame> get frames => _framesCtrl.stream;

  /// NEW: latest face landmarks cache (requires 'face' in [requestedTasks]).
  /// Each entry is one face = List<Offset> (e.g., 468 points).
  List<List<Offset>>? get latestFaceLandmarks => _lastPosesPerTask['face'];

  // ⬇️ ADD THIS BLOCK HERE
  /// Latest primary pose landmarks (first person) — image-space.
  /// Returns `null` if no 'pose' data has arrived yet.
  List<Offset>? get latestPoseLandmarks {
    final poses = _lastPosesPerTask['pose'];
    if (poses == null || poses.isEmpty) return null;
    return poses.first; // choose the first detected person
  }
  // ⬆️ ADD THIS BLOCK HERE

  // ─────── Parsers & state PER TASK ───────
  final Map<String, PoseBinaryParser> _parsers = {}; // task -> parser
  final Map<String, List<List<Offset>>> _lastPosesPerTask = {}; // task -> poses
  int? _lastW;
  int? _lastH;

  // NEW: último seq aceptado por task (comparación circular 16-bit)
  final Map<String, int> _lastSeqPerTask = {};
  bool _isNewer16(int seq, int? last) {
    if (last == null) return true;
    final int d = (seq - last) & 0xFFFF;        // [0..65535]
    return d != 0 && (d & 0x8000) == 0;         // 1..32767 → más nuevo
  }

  // Simple logging helper that respects [logEverything]
  void _log(Object? message) {
    if (!logEverything) return;
    // ignore: avoid_print
    print(message);
  }

  // Prefer TURN over UDP to avoid TCP head-of-line blocking.
  String _forceTurnUdp(String url) {
    // only append if not already present
    return url.contains('?') ? url : '$url?transport=udp';
  }

  // Map a task to a negotiated datachannel id
  int _dcIdForTask(String task, int indexInList) {
    // Server defaults: results=0, ctrl=1, face=2, others auto-increment from 3
    final t = task.toLowerCase();
    if (indexInList == 0) return 0; // primary 'results'
    if (t == 'face') return 2; // must match server's DC_FACE_ID (default 2)
    return 3 + (indexInList - 1); // conservative auto IDs for extra tasks
  }

  // ================================
  // Lifecycle
  // ================================

  Future<void> init() async {
    _log('[client] init()');
    await localRenderer.initialize();
    await remoteRenderer.initialize();
    _log('[client] renderers initialized');

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

    _log('[client] getUserMedia constraints: ${mediaConstraints['video']}');

    _localStream = await navigator.mediaDevices.getUserMedia(mediaConstraints);
    localRenderer.srcObject = _localStream;

    // ↓ NEW: hint encoder/algorithms to optimize for motion/latency
    try {
      final dynamic dtrack = _localStream!.getVideoTracks().first;
      // Some flutter_webrtc builds expose this; safe dynamic call.
      // ignore: avoid_dynamic_calls
      await dtrack.setVideoContentHint('motion');
    } catch (_) {
      // Older flutter_webrtc versions don't expose setVideoContentHint — ignore.
    }

    _log(
      '[client] local stream acquired: '
      'videoTracks=${_localStream!.getVideoTracks().length}',
    );
  }

  Future<void> connect() async {
    _log(
      '[client] connect() STUN=${_stunUrl ?? '-'} '
      'TURN=${_turnUrl != null ? 'True' : 'False'} '
      'preferHevc=$preferHevc',
    );

    // ── UPDATED: added iceCandidatePoolSize: 4 and TURN over UDP ────────────
    final config = <String, dynamic>{
      'sdpSemantics': 'unified-plan',
      'bundlePolicy': 'max-bundle',
      'iceCandidatePoolSize': 4,
      'iceServers': [
        if (_stunUrl != null && _stunUrl!.isNotEmpty) {'urls': _stunUrl},
        if (_turnUrl != null && _turnUrl!.isNotEmpty)
          {
            'urls': _forceTurnUdp(_turnUrl!), // ← prefer UDP over TCP
            if ((_turnUsername ?? '').isNotEmpty) 'username': _turnUsername,
            if ((_turnPassword ?? '').isNotEmpty) 'credential': _turnPassword,
          },
      ],
    };

    _pc = await createPeerConnection(config);
    _log('[client] RTCPeerConnection created');

    _pc!.onIceGatheringState = (state) {
      _log('[client] ICE gathering: $state');
    };
    _pc!.onIceConnectionState = (state) {
      _log('[client] ICE connection: $state');
    };
    _pc!.onSignalingState = (state) {
      _log('[client] signaling state: $state');
    };
    _pc!.onConnectionState = (state) {
      _log('[client] peer connection state: $state');
    };
    _pc!.onRenegotiationNeeded = () {
      _log('[client] on-negotiation-needed');
    };

    // Data channels: optionally pre-create so the OFFER carries m=application.
    if (preCreateDataChannels) {
      final tasks = (requestedTasks.isEmpty) ? const ['pose'] : requestedTasks;

      // 1) Primary 'results' for tasks[0] (unordered lossy, negotiated id=0)
      {
        final String task0 = tasks[0].toLowerCase();
        final lossy = RTCDataChannelInit()
          ..negotiated = true
          ..id = _dcIdForTask(task0, 0)
          ..ordered = false
          ..maxRetransmits = 0;
        final ch = await _pc!.createDataChannel('results', lossy);
        _dc = ch;
        _resultsPerTask[task0] = ch;
        _log(
            "[client] created negotiated DC 'results' id=${ch.id} (task=$task0)");
        _wireResults(ch, task: task0);
      }

      // 2) Extra 'results:<task>' channels (unordered lossy, negotiated)
      for (var i = 1; i < tasks.length; i++) {
        final task = tasks[i].toLowerCase().trim();
        if (task.isEmpty) continue;
        final lossy = RTCDataChannelInit()
          ..negotiated = true
          ..id = _dcIdForTask(task, i)
          ..ordered = false
          ..maxRetransmits = 0;
        final label = 'results:$task';
        final ch = await _pc!.createDataChannel(label, lossy);
        _resultsPerTask[task] = ch;
        _log("[client] created negotiated DC '$label' id=${ch.id}");
        _wireResults(ch, task: task);
      }

      // 3) Reliable 'ctrl' (negotiated id=1)
      final reliable = RTCDataChannelInit()
        ..negotiated = true
        ..id = 1
        ..ordered = true;
      _ctrl = await _pc!.createDataChannel('ctrl', reliable);
      _log("[client] created negotiated DC 'ctrl' id=1");
      _wireCtrl(_ctrl!);
    } else {
      _log(
          "[client] preCreateDataChannels=false → waiting for peer-announced channels");
    }

    // Always adopt peer-announced channels if they arrive.
    _pc!.onDataChannel = (RTCDataChannel ch) {
      // label is nullable in flutter_webrtc → normalize to empty string
      final label = ch.label ?? '';
      _log("[client] datachannel announced by peer: $label id=${ch.id}");

      if (label == 'results') {
        _dc = ch;
        final task0 = _primaryTask;
        _resultsPerTask[task0] = ch;
        _wireResults(ch, task: task0);
      } else if (label.startsWith('results:')) {
        const prefix = 'results:';
        final task = label.substring(prefix.length).toLowerCase().trim();
        if (task.isNotEmpty) {
          _resultsPerTask[task] = ch;
        }
        _wireResults(ch, task: task.isNotEmpty ? task : _primaryTask);
      } else if (label == 'ctrl') {
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
    _log('[client] video transceiver added as SendOnly');

    _pc!.onTrack = (RTCTrackEvent e) {
      _log(
        '[client] onTrack kind=${e.track.kind} streams=${e.streams.length}',
      );
      if (e.track.kind == 'video' && e.streams.isNotEmpty) {
        remoteRenderer.srcObject = e.streams.first;
        _log('[client] remote video bound to renderer');
      }
    };

    // ─────────────────────────────────────────────────────────────
    // Centralized encoder setup (codec prefs + sender limits)
    // ─────────────────────────────────────────────────────────────
    await encoder.applyTo(_videoTransceiver!);

    // Create offer and log SDP parts like the Python client
    _log('[client] creating offer…');
    var offer = await _pc!.createOffer({
      'offerToReceiveVideo': 0,
      'offerToReceiveAudio': 0,
    });

    // Hint initial bitrate for H.264
    final munged = RtcVideoEncoder.mungeH264BitrateHints(
      offer.sdp!,
      kbps: maxBitrateKbps,
    );

    // ↓↓↓ NEW: Strip FEC codecs from the m=video section if requested
    var sdp = munged;
    if (stripFecFromSdp) {
      sdp = _stripVideoFec(sdp);
    }
    // ↓↓↓ NEW: Also strip RTX/NACK/REMB (keep transport-cc)
    if (stripRtxAndNackFromSdp) {
      sdp = _stripVideoRtxNackAndRemb(
        sdp,
        dropNack: true,
        dropRtx: true,
        keepTransportCcOnly: keepTransportCcOnly,
      );
    }
    // ↓↓↓ NEW: Keep only the chosen video codec(s) to avoid payload switches
    final only = preferHevc ? ['h265'] : ['h264']; // or ['vp8'] if you prefer
    sdp = _keepOnlyVideoCodecs(sdp, only);
    offer = RTCSessionDescription(sdp, offer.type);

    final hasApp = (offer.sdp?.contains('m=application') ?? false);
    _log('[client] offer created (has m=application: $hasApp )');
    await _pc!.setLocalDescription(offer);
    _log('[client] local description set');

    _dumpSdp('local-offer', offer.sdp);

    await _waitIceGatheringComplete(_pc!);

    final local = await _pc!.getLocalDescription();

    _log('[client] posting offer to server…');
    final body = {
      'type': local!.type,
      'sdp': local.sdp,
      // NEW ↓ tell server which adapters you want
      'tasks': requestedTasks.isEmpty ? ['pose'] : requestedTasks,
    };
    final res = await http.post(
      offerUri,
      headers: const {'content-type': 'application/json'},
      body: jsonEncode(body),
    );

    if (res.statusCode < 200 || res.statusCode >= 300) {
      _log('[client] signaling failed: ${res.statusCode} ${res.body}');
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
    _log(
      "[client] remote answer has m=application: "
      "${ansSdp.contains('m=application')}",
    );
    _log('[client] remote answer set');

    _dumpSdp('remote-answer', ansSdp);

    _startRtpStatsProbe();
    _startNoResultsGuard();
  }

  // ================================
  // Helpers (ICE, etc.)
  // ================================

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
        _log('[client] ICE gathering complete');
        c.complete();
        pc.onIceGatheringState = prev;
      }
    };

    Timer(const Duration(seconds: 2), () {
      if (!c.isCompleted) {
        _log('[client] ICE gathering timeout — continuing');
        c.complete();
        pc.onIceGatheringState = prev;
      }
    });

    return c.future;
  }

  // ===============================
  // Data channels
  // ===============================

  void _wireResults(RTCDataChannel ch, {required String task}) {
    ch.onDataChannelState = (s) {
      final label = ch.label ?? 'results';
      if (s == RTCDataChannelState.RTCDataChannelOpen) {
        _log("[client] '$label' open (id=${ch.id}, task=$task)");
      } else if (s == RTCDataChannelState.RTCDataChannelClosed) {
        _log("[client] '$label' closed (id=${ch.id}, task=$task)");
      }
    };

    ch.onMessage = (RTCDataChannelMessage m) {
      // UNIVERSAL MESSAGE LOGGER (before parsing)
      if (m.isBinary) {
        final bin = m.binary;
        final head = bin.length >= 2
            ? '${bin[0].toRadixString(16)} ${bin[1].toRadixString(16)}'
            : '<short>';
        _log("[client] results(task=$task) RECV bin len=${bin.length} head=$head");
      } else {
        final t = m.text ?? '';
        final preview = t.length <= 48 ? t : t.substring(0, 48);
        _log(
          "[client] results(task=$task) RECV txt len=${t.length} "
          "preview='${preview.replaceAll('\n', ' ')}'",
        );
      }

      // Actual handling
      if (m.isBinary) {
        try {
          _handleTaskBinary(task, m.binary);
        } catch (e) {
          _log('[client] error parsing results packet (task=$task): $e');
          _sendCtrlKF();
        }
      } else {
        final txtRaw = m.text ?? '';
        final txt = txtRaw.trim();
        if (txt.toUpperCase() == 'KF') {
          _log(
            "[client] '$task' got KF request (string) — ignoring on client",
          );
        } else {
          _handlePoseText(txtRaw); // JSON fallback (kept simple)
        }
      }
    };
  }

  void _wireCtrl(RTCDataChannel ch) {
    ch.onDataChannelState = (s) {
      if (s == RTCDataChannelState.RTCDataChannelOpen) {
        _log("[client] 'ctrl' open (id=${ch.id})");
        _nudgeServer();
      } else if (s == RTCDataChannelState.RTCDataChannelClosed) {
        _log("[client] 'ctrl' closed (id=${ch.id})");
      }
    };

    ch.onMessage = (RTCDataChannelMessage m) {
      if (m.isBinary) {
        _log('[client] ctrl RECV bin len=${m.binary.length}');
      } else {
        final t = m.text ?? '';
        final prev = t.length <= 48 ? t : t.substring(0, 48);
        _log(
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

    _log('[client] ctrl nudge: HELLO + KF');
    c.send(RTCDataChannelMessage('HELLO'));
    c.send(RTCDataChannelMessage('KF'));
  }

  Future<void> _recreateNegotiatedChannels() async {
    final pc = _pc;
    if (pc == null) return;

    // Only attempt if channels are absent or closed.
    if (_dc?.state == RTCDataChannelState.RTCDataChannelOpen ||
        _ctrl?.state == RTCDataChannelState.RTCDataChannelOpen) {
      _log('[client] negotiated fallback skipped — channels already open');
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
        _log("[client] created negotiated DC '$label' id=$id");
        return ch;
      } catch (e) {
        _log("[client] failed to create negotiated DC '$label' id=$id: $e");
        return null;
      }
    }

    final newResults = await _tryCreate('results', 0, lossy: true);
    final newCtrl = await _tryCreate('ctrl', 1, lossy: false);

    if (newResults == null || newCtrl == null) {
      _log(
        "[client] negotiated fallback aborted — "
        "could not create DCs (ids may be in use)",
      );
      return;
    }

    _dc = newResults;
    _wireResults(_dc!, task: _primaryTask);

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

      _log('[client] results: JSON pose(s) -> emitted frame');
    } catch (e) {
      _log('[client] JSON pose parse error: $e -> requesting KF');
      _sendCtrlKF();
    }
  }

  // ================================
  // Binary PO/PD Parsing (per task)
  // ================================

  void _handleTaskBinary(String task, Uint8List b) {
    final parser = _parsers.putIfAbsent(task, () => PoseBinaryParser());
    final res = parser.parse(b);

    if (res is PoseParseOk) {
      final pkt = res.packet; // has kind, keyframe, seq, w, h, poses
      final int? seq = pkt.seq;

      // ── DROP: PD no-KF re-ordenados (unordered/lossy DC) ─────────────
      if (pkt.kind == PacketKind.pd && !pkt.keyframe && seq != null) {
        final int? last = _lastSeqPerTask[task];
        if (last != null && !_isNewer16(seq, last)) {
          _log("[client] drop stale PD task=$task seq=$seq (last=$last)");
          // ACK igualmente si es el stream primario, para no confundir al servidor
          if (task == _primaryTask && res.ackSeq != null) {
            _sendCtrlAck(res.ackSeq!);
          }
          return; // no actualices estado ni emitas frame
        }
      }
      // ─────────────────────────────────────────────────────────────────

      // Save accepted packet state
      _lastW = pkt.w;
      _lastH = pkt.h;
      _lastPosesPerTask[task] = pkt.poses;
      if (seq != null) _lastSeqPerTask[task] = seq;

      // Fuse all tasks' poses into one list for the existing overlay
      final fused = _lastPosesPerTask.values
          .expand((l) => l)
          .toList(growable: false);

      _emitBinary(
        pkt.w,
        pkt.h,
        fused,
        kind: pkt.kind == PacketKind.po
            ? 'PO'
            : (pkt.keyframe ? 'PD(KF)' : 'PD'),
        seq: pkt.seq,
      );

      // ACK PD only for the PRIMARY stream (e.g., 'pose')
      if (task == _primaryTask && res.ackSeq != null) {
        _sendCtrlAck(res.ackSeq!);
      }
      // Ask for KF if parser detected a sequence hole
      if (res.requestKeyframe) {
        _log('[client] PD seq mismatch (task=$task) -> requesting KF');
        _sendCtrlKF();
      }
    } else if (res is PoseParseNeedKF) {
      _log('[client] parser says KF needed (task=$task): ${res.reason}');
      _sendCtrlKF();
    }
  }

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

    _log(
      '[client] emit frame kind=$kind seq=${seq ?? '-'} '
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

    _log('[client] sending KF request over ctrl');
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

    _log('[client] sending ACK seq=$seq over ctrl');
    c.send(RTCDataChannelMessage.fromBinary(out));
  }

  // ================================
  // Diagnostics
  // ================================

  void _dumpSdp(String tag, String? sdp) {
    if (!logEverything || sdp == null) return;

    // Split SDP into lines safely (CRLF or LF)
    final lines = sdp.split(RegExp(r'\r?\n'));

    final take = <String>[];
    var inVideo = false;

    for (final l in lines) {
      if (l.startsWith('m=')) {
        inVideo = l.startsWith('m=video');
      }
      if (inVideo &&
          (l.startsWith('m=video') ||
              l.startsWith('a=rtpmap:') ||
              l.startsWith('a=fmtp:'))) {
        take.add(l);
      }
    }

    _log('--- [$tag] SDP video ---\n${take.join('\n')}\n------------------------');
  }

  void _startRtpStatsProbe() {
    if (!logEverything) return;

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
            _log('[RTP] video packetsSent=$p bytesSent=$b');
          }
        }
      } catch (e) {
        _log('[client] stats probe error: $e');
      }
    });

    _log('[client] RTP stats probe started (2s)');
  }

  void _startNoResultsGuard() {
    _dcGuardTimer?.cancel();
    if (negotiatedFallbackAfterSeconds <= 0) return;

    _dcGuardTimer = Timer(
      Duration(seconds: negotiatedFallbackAfterSeconds),
      () async {
        if (_disposed) return;
        if (latestFrame.value != null) return;

        final dcOpen =
            _dc?.state == RTCDataChannelState.RTCDataChannelOpen;
        final ctrlOpen =
            _ctrl?.state == RTCDataChannelState.RTCDataChannelOpen;

        // If channels are open, don't try creating negotiated ones — just nudge.
        if (dcOpen || ctrlOpen) {
          _log(
            '[client] no results yet, channels open → re-nudge (HELLO+KF)',
          );
          _nudgeServer();
          return;
        }

        // Channels not open: try negotiated(0/1) once.
        _log(
          '[client] no results and channels not open → trying negotiated DCs (0/1)',
        );
        await _recreateNegotiatedChannels();
      },
    );
  }

  // ================================
  // SDP munging helpers (FEC strip)
  // ================================

  String _stripVideoFec(String sdp) {
    final lines = sdp.split(RegExp(r'\r?\n'));
    final fecNames = {'red', 'ulpfec', 'flexfec-03'};
    final fecPts = <String>{};

    // Pass 1: collect payload types for FEC codecs
    for (final l in lines) {
      final m =
          RegExp(r'^a=rtpmap:(\d+)\s+([A-Za-z0-9\-]+)/').firstMatch(l);
      if (m != null) {
        final pt = m.group(1)!;
        final codec = (m.group(2) ?? '').toLowerCase();
        if (fecNames.contains(codec)) fecPts.add(pt);
      }
    }

    if (fecPts.isEmpty) return sdp; // nothing to do

    // Pass 2: rebuild lines skipping FEC payloads and their attributes
    final out = <String>[];
    for (final l in lines) {
      if (l.startsWith('m=video')) {
        final parts = l.split(' ');
        final head = parts.take(3);
        final payloads =
            parts.skip(3).where((pt) => !fecPts.contains(pt));
        out.add([...head, ...payloads].join(' '));
        continue;
      }

      bool isFecSpecific = false;
      for (final prefix in ['a=rtpmap:', 'a=fmtp:', 'a=rtcp-fb:']) {
        final m =
            RegExp('^' + RegExp.escape(prefix) + r'(\d+)').firstMatch(l);
        if (m != null && fecPts.contains(m.group(1)!)) {
          isFecSpecific = true;
          break;
        }
      }
      if (!isFecSpecific) out.add(l);
    }

    return out.join('\r\n');
  }

  // ================================
  // SDP munging helpers (RTX/NACK/REMB strip)
  // ================================

  String _stripVideoRtxNackAndRemb(String sdp,
      {bool dropNack = true, bool dropRtx = true, bool keepTransportCcOnly = true}) {
    final lines = sdp.split(RegExp(r'\r?\n'));
    final rtxPts = <String>{};

    // 1) collect RTX payload types
    for (final l in lines) {
      final m = RegExp(r'^a=rtpmap:(\d+)\s+rtx/').firstMatch(l);
      if (m != null) rtxPts.add(m.group(1)!);
    }

    bool inVideo = false;
    final out = <String>[];
    for (final l in lines) {
      if (l.startsWith('m=')) inVideo = l.startsWith('m=video');

      if (inVideo) {
        // Remove RTX payload IDs from m=video line
        if (dropRtx && l.startsWith('m=video')) {
          final parts = l.split(' ');
          final head = parts.take(3);
          final payloads = parts.skip(3).where((pt) => !rtxPts.contains(pt));
          out.add([...head, ...payloads].join(' '));
          continue;
        }

        // Drop any attributes tied to RTX PTs
        if (dropRtx && RegExp(r'^a=(rtpmap|fmtp|rtcp-fb):(\d+)').hasMatch(l)) {
          final m = RegExp(r'^a=(?:rtpmap|fmtp|rtcp-fb):(\d+)').firstMatch(l);
          if (m != null && rtxPts.contains(m.group(1)!)) continue;
        }

        // Drop generic NACK / PLI / FIR feedback if requested
        if (dropNack && l.startsWith('a=rtcp-fb:')) {
          // Keep transport-cc only (and optionally drop goog-remb)
          if (keepTransportCcOnly) {
            if (l.contains('transport-cc')) { out.add(l); continue; }
            // drop everything else (incl. goog-remb, nack, ccm fir, nack pli)
            continue;
          } else {
            // drop nack/fir/pli, keep others
            if (l.contains('nack') || l.contains('ccm fir') || l.contains('pli')) continue;
          }
        }
      }
      out.add(l);
    }
    return out.join('\r\n');
  }

  // ================================
  // SDP munging helpers (keep only selected codecs)
  // ================================

  String _keepOnlyVideoCodecs(String sdp, List<String> codecNamesLower) {
    // Split SDP into lines safely (CRLF or LF)
    final lines = sdp.split(RegExp(r'\r?\n'));
    final keepPts = <String>{};

    // Pass 1: collect payload types (PTs) of the codecs we want to keep
    for (final l in lines) {
      final m = RegExp(r'^a=rtpmap:(\d+)\s+([A-Za-z0-9\-]+)/').firstMatch(l);
      if (m != null) {
        final pt = m.group(1)!;
        final codec = (m.group(2) ?? '').toLowerCase();
        if (codecNamesLower.contains(codec)) keepPts.add(pt);
      }
    }
    if (keepPts.isEmpty) return sdp;

    // Pass 2: rebuild the video section, dropping everything tied to other PTs
    final out = <String>[];
    var inVideo = false;

    for (final l in lines) {
      if (l.startsWith('m=')) inVideo = l.startsWith('m=video');

      if (inVideo && l.startsWith('m=video')) {
        final parts = l.split(' ');
        final head = parts.take(3);
        final pay = parts.skip(3).where((pt) => keepPts.contains(pt));
        out.add([...head, ...pay].join(' '));
        continue;
      }

      if (inVideo && RegExp(r'^a=(?:rtpmap|fmtp|rtcp-fb):(\d+)').hasMatch(l)) {
        final m = RegExp(r'^a=(?:rtpmap|fmtp|rtcp-fb):(\d+)').firstMatch(l);
        if (m != null && !keepPts.contains(m.group(1)!)) continue;
      }

      out.add(l);
    }

    // Use CRLF per SDP spec (LF also works in practice)
    return out.join('\r\n');
  }

  // ================================

  Future<void> switchCamera() async {
    final tracks = _localStream?.getVideoTracks();
    if (tracks == null || tracks.isEmpty) return;

    try {
      await Helper.switchCamera(tracks.first);
      _log('[client] camera switched');
      if (_videoTransceiver != null) {
        await encoder.applyTo(_videoTransceiver!); // keep limits after switch
      }
    } catch (e) {
      _log('[client] switchCamera failed: $e');
    }
  }

  Future<void> close() => dispose();

  Future<void> dispose() async {
    _disposed = true;
    _log('[client] dispose()');

    try {
      await _ctrl?.close();
    } catch (_) {}
    try {
      await _dc?.close();
    } catch (_) {}
    try {
      await _pc?.close();
    } catch (_) {}

    // Stop local tracks explicitly before disposing the stream/renderer
    try {
      _localStream?.getTracks().forEach((t) {
        try {
          t.stop();
        } catch (_) {}
      });
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

    _localStream = null; // ← ensure getter returns null after dispose

    _rtpStatsTimer?.cancel();
    _dcGuardTimer?.cancel();
    await _framesCtrl.close();

    // NEW: limpia estados para siguiente sesión
    _lastSeqPerTask.clear();
    _lastPosesPerTask.clear();

    _log('[client] disposed');
  }
}
