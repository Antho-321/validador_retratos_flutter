import 'dart:async';
import 'dart:convert' show jsonDecode, jsonEncode, utf8;
import 'dart:typed_data';
import 'dart:ui' show Offset, Size;

import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;

import '../../domain/service/pose_capture_service.dart';
import '../../domain/model/lmk_state.dart';
import '../model/pose_frame.dart' show PoseFrame, poseFrameFromMap;
import '../webrtc/rtc_video_encoder.dart';
import '../parsers/pose_binary_parser.dart';
import '../model/pose_point.dart';
import 'package:hashlib/hashlib.dart';

Uint8List _pad8(String s) {
  final src = utf8.encode(s);
  final out = Uint8List(8);
  final n = src.length > 8 ? 8 : src.length;
  out.setRange(0, n, src);
  return out;
}

int _dcIdFromTask(String name, {int mod = 1024}) {
  if (mod < 2) mod = 2;
  final person = _pad8('DCMAP');
  final digestBytes = Blake2s(2, aad: person).convert(utf8.encode(name)).bytes;
  final base = digestBytes[0] | (digestBytes[1] << 8);
  var id = (base % mod) & 0xFFFE;
  if (id == 1) {
    id = (id + 2) % mod;
    id &= 0xFFFE;
  }
  return id;
}

Map<String, dynamic> _parseJson(String text) =>
    jsonDecode(text) as Map<String, dynamic>;

class PoseWebrtcServiceImp implements PoseCaptureService {
  PoseWebrtcServiceImp({
    required this.offerUri,
    this.facingMode = 'user',
    this.idealWidth = 640,
    this.idealHeight = 360,
    this.idealFps = 30,
    this.maxBitrateKbps = 800,
    String? stunUrl,
    String? turnUrl,
    String? turnUsername,
    String? turnPassword,
    this.preferHevc = false,
    this.preCreateDataChannels = true,
    this.negotiatedFallbackAfterSeconds = 3,
    this.logEverything = true,
    this.stripFecFromSdp = true,
    this.stripRtxAndNackFromSdp = true,
    this.keepTransportCcOnly = true,
    this.requestedTasks = const ['pose', 'face'],
    RtcVideoEncoder? encoder,
  })  : _stunUrl = stunUrl ?? 'stun:stun.l.google.com:19302',
        _turnUrl = turnUrl,
        _turnUsername = turnUsername,
        _turnPassword = turnPassword,
        _encoder = encoder ??
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
  final bool logEverything;
  final bool stripFecFromSdp;
  final bool stripRtxAndNackFromSdp;
  final bool keepTransportCcOnly;
  final List<String> requestedTasks;

  String get _primaryTask =>
      (requestedTasks.isNotEmpty ? requestedTasks.first : 'pose').toLowerCase();

  final String? _stunUrl;
  final String? _turnUrl;
  final String? _turnUsername;
  final String? _turnPassword;

  final RtcVideoEncoder _encoder;

  RTCPeerConnection? _pc;

  RTCDataChannel? _dc;
  RTCDataChannel? _ctrl;
  final Map<String, RTCDataChannel> _resultsPerTask = {};

  MediaStream? _localStream;
  @override
  MediaStream? get localStream => _localStream;

  RTCRtpTransceiver? _videoTransceiver;

  Timer? _rtpStatsTimer;
  Timer? _dcGuardTimer;
  bool _disposed = false;

  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();

  @override
  RTCVideoRenderer get localRenderer => _localRenderer;
  @override
  RTCVideoRenderer get remoteRenderer => _remoteRenderer;

  final ValueNotifier<PoseFrame?> _latestFrame = ValueNotifier<PoseFrame?>(null);
  @override
  ValueListenable<PoseFrame?> get latestFrame => _latestFrame;

  final _framesCtrl = StreamController<PoseFrame>.broadcast();
  @override
  Stream<PoseFrame> get frames => _framesCtrl.stream;

  final ValueNotifier<LmkState> _faceLmk = ValueNotifier<LmkState>(LmkState());
  @override
  ValueListenable<LmkState> get faceLandmarks => _faceLmk;

  @override
  List<List<Offset>>? get latestFaceLandmarks {
    final faces3d = _lastPosesPerTask['face'];
    if (faces3d == null) return null;
    return faces3d
        .map((pose) => pose.map((p) => Offset(p.x, p.y)).toList(growable: false))
        .toList(growable: false);
  }

  @override
  List<PosePoint>? get latestPoseLandmarks3D {
    final poses = _lastPosesPerTask['pose'];
    if (poses == null || poses.isEmpty) return null;
    return poses.first;
  }

  @override
  List<Offset>? get latestPoseLandmarks {
    final ps = latestPoseLandmarks3D;
    if (ps == null) return null;
    return ps.map((p) => Offset(p.x, p.y)).toList(growable: false);
  }

  final Map<String, PoseBinaryParser> _parsers = {};
  final Map<String, List<List<PosePoint>>> _lastPosesPerTask = {};
  int? _lastW;
  int? _lastH;

  final Map<String, int> _lastSeqPerTask = {};
  bool _isNewer16(int seq, int? last) {
    if (last == null) return true;
    final int d = (seq - last) & 0xFFFF;
    return d != 0 && (d & 0x8000) == 0;
  }

  // ── Add fields ───────────────────────────────────────────────────────────────
  final Map<String, Uint8List?> _pendingBin = {};   // latest pending per task
  final Set<String> _parsingTasks = {};             // tasks currently parsing
  int _lastAckSeqSent = -1;
  DateTime _lastKfReq = DateTime.fromMillisecondsSinceEpoch(0);

  void _log(Object? message) {
    if (!logEverything) return;
    // ignore: avoid_print
    print(message);
  }

  String _forceTurnUdp(String url) {
    return url.contains('?') ? url : '$url?transport=udp';
  }

  @override
  Future<void> init() async {
    _log('[client] init()');
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();
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
    _localRenderer.srcObject = _localStream;

    try {
      final dynamic dtrack = _localStream!.getVideoTracks().first;
      await dtrack.setVideoContentHint('motion');
    } catch (_) {}

    _log(
      '[client] local stream acquired: '
      'videoTracks=${_localStream!.getVideoTracks().length}',
    );
  }

  @override
  Future<void> connect() async {
    _log(
      '[client] connect() STUN=${_stunUrl ?? '-'} '
      'TURN=${_turnUrl != null ? 'True' : 'False'} '
      'preferHevc=$preferHevc',
    );

    final config = <String, dynamic>{
      'sdpSemantics': 'unified-plan',
      'bundlePolicy': 'max-bundle',
      'iceCandidatePoolSize': 4,
      'iceServers': [
        if (_stunUrl != null && _stunUrl!.isNotEmpty) {'urls': _stunUrl},
        if (_turnUrl != null && _turnUrl!.isNotEmpty)
          {
            'urls': _forceTurnUdp(_turnUrl!),
            if ((_turnUsername ?? '').isNotEmpty) 'username': _turnUsername,
            if ((_turnPassword ?? '').isNotEmpty) 'credential': _turnPassword,
          },
      ],
    };

    _pc = await createPeerConnection(config);
    _log('[client] RTCPeerConnection created');

    _pc!.onIceGatheringState = (state) => _log('[client] ICE gathering: $state');
    _pc!.onIceConnectionState =
        (state) => _log('[client] ICE connection: $state');
    _pc!.onSignalingState = (state) => _log('[client] signaling state: $state');
    _pc!.onConnectionState =
        (state) => _log('[client] peer connection state: $state');
    _pc!.onRenegotiationNeeded = () => _log('[client] on-negotiation-needed');

    if (preCreateDataChannels) {
      final tasks = (requestedTasks.isEmpty) ? const ['pose'] : requestedTasks;

      {
        final String task0 = tasks[0].toLowerCase();
        final lossy = RTCDataChannelInit()
          ..negotiated = true
          ..id = _dcIdFromTask(task0)
          ..ordered = false
          ..maxRetransmits = 0;

        final label0 = 'results:$task0';
        final ch = await _pc!.createDataChannel(label0, lossy);
        _dc = ch;
        _resultsPerTask[task0] = ch;
        _log("[client] created negotiated DC '$label0' id=${ch.id}");
        _wireResults(ch, task: task0);
      }

      for (var i = 1; i < tasks.length; i++) {
        final task = tasks[i].toLowerCase().trim();
        if (task.isEmpty) continue;

        final lossy = RTCDataChannelInit()
          ..negotiated = true
          ..id = _dcIdFromTask(task)
          ..ordered = false
          ..maxRetransmits = 0;

        final label = 'results:$task';
        final ch = await _pc!.createDataChannel(label, lossy);
        _resultsPerTask[task] = ch;
        _log("[client] created negotiated DC '$label' id=${ch.id}");
        _wireResults(ch, task: task);
      }

      final reliable = RTCDataChannelInit()
        ..negotiated = true
        ..id = 1
        ..ordered = true;
      _ctrl = await _pc!.createDataChannel('ctrl', reliable);
      _log("[client] created negotiated DC 'ctrl' id=1");
      _wireCtrl(_ctrl!);
    } else {
      _log("[client] preCreateDataChannels=false → waiting peer-announced DCs");
    }

    _pc!.onDataChannel = (RTCDataChannel ch) {
      final label = ch.label ?? '';
      _log("[client] datachannel announced by peer: $label id=${ch.id}");

      if (label == 'ctrl') {
        _ctrl = ch;
        _wireCtrl(ch);
        return;
      }
      if (label.startsWith('results:')) {
        final task = label.substring('results:'.length).toLowerCase().trim();
        final t = task.isNotEmpty ? task : _primaryTask;
        _resultsPerTask[t] = ch;
        if (t == _primaryTask) _dc = ch;
        _wireResults(ch, task: t);
      }
    };

    final videoTrack = _localStream!.getVideoTracks().first;
    _videoTransceiver = await _pc!.addTransceiver(
      track: videoTrack,
      init: RTCRtpTransceiverInit(direction: TransceiverDirection.SendOnly),
    );
    _log('[client] video transceiver added as SendOnly');

    _pc!.onTrack = (RTCTrackEvent e) {
      _log('[client] onTrack kind=${e.track.kind} streams=${e.streams.length}');
      if (e.track.kind == 'video' && e.streams.isNotEmpty) {
        _remoteRenderer.srcObject = e.streams.first;
        _log('[client] remote video bound to renderer');
      }
    };

    await _encoder.applyTo(_videoTransceiver!);

    _log('[client] creating offer…');
    var offer = await _pc!.createOffer({
      'offerToReceiveVideo': 0,
      'offerToReceiveAudio': 0,
    });

    final munged = RtcVideoEncoder.mungeH264BitrateHints(
      offer.sdp!,
      kbps: maxBitrateKbps,
    );

    var sdp = munged;
    if (stripFecFromSdp) {
      sdp = _stripVideoFec(sdp);
    }
    if (stripRtxAndNackFromSdp) {
      sdp = _stripVideoRtxNackAndRemb(
        sdp,
        dropNack: true,
        dropRtx: true,
        keepTransportCcOnly: keepTransportCcOnly,
      );
    }
    final only = preferHevc ? ['h265'] : ['h264'];
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
    _log("[client] remote answer has m=application: ${ansSdp.contains('m=application')}");
    _log('[client] remote answer set');
    _dumpSdp('remote-answer', ansSdp);

    _startRtpStatsProbe();
    _startNoResultsGuard();
  }

  @override
  Future<void> switchCamera() async {
    final tracks = _localStream?.getVideoTracks();
    if (tracks == null || tracks.isEmpty) return;
    try {
      await Helper.switchCamera(tracks.first);
      _log('[client] camera switched');
      if (_videoTransceiver != null) {
        await _encoder.applyTo(_videoTransceiver!);
      }
    } catch (e) {
      _log('[client] switchCamera failed: $e');
    }
  }

  Future<void> close() => dispose();

  @override
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

    try {
      _localStream?.getTracks().forEach((t) {
        try {
          t.stop();
        } catch (_) {}
      });
    } catch (_) {}

    try {
      await _localRenderer.dispose();
    } catch (_) {}
    try {
      await _remoteRenderer.dispose();
    } catch (_) {}
    try {
      await _localStream?.dispose();
    } catch (_) {}

    _localStream = null;

    _rtpStatsTimer?.cancel();
    _dcGuardTimer?.cancel();
    await _framesCtrl.close();

    _lastSeqPerTask.clear();
    _lastPosesPerTask.clear();

    _log('[client] disposed');
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

      // ── Replace inside _wireResults(ch,...): in onMessage for binary ─────────────
      if (m.isBinary) {
        _enqueueBinary(task, m.binary);
      } else {
        // unchanged: _handlePoseText(...)
        final txtRaw = m.text ?? '';
        final txt = txtRaw.trim();
        if (txt.toUpperCase() == 'KF') {
          _log("[client] '$task' got KF request (string) — ignoring on client");
        } else {
          _handlePoseText(txtRaw);
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

    try {
      final reliable = RTCDataChannelInit()
        ..negotiated = true
        ..id = 1
        ..ordered = true;
      _ctrl = await pc.createDataChannel('ctrl', reliable);
      _log("[client] recreated negotiated DC 'ctrl' id=1");
      _wireCtrl(_ctrl!);
    } catch (e) {
      _log("[client] failed to recreate 'ctrl' id=1: $e");
    }

    final tasks = requestedTasks.isEmpty ? const ['pose'] : requestedTasks;
    for (var i = 0; i < tasks.length; i++) {
      final task = tasks[i].toLowerCase().trim();
      if (task.isEmpty) continue;

      try {
        final lossy = RTCDataChannelInit()
          ..negotiated = true
          ..id = _dcIdFromTask(task)
          ..ordered = false
          ..maxRetransmits = 0;

        final label = 'results:$task';
        final ch = await pc.createDataChannel(label, lossy);
        _resultsPerTask[task] = ch;
        if (i == 0) _dc = ch;
        _log("[client] recreated negotiated DC '$label' id=${ch.id}");
        _wireResults(ch, task: task);
      } catch (e) {
        _log("[client] failed to recreate DC for task '$task': $e");
      }
    }

    _log("[client] negotiated fallback recreated with hashed IDs (ctrl=1)");
  }

  void _handlePoseText(String text) {
    try {
      final m = _parseJson(text);
      final frame = poseFrameFromMap(m);
      _latestFrame.value = frame;

      if (frame != null && !_framesCtrl.isClosed) {
        _framesCtrl.add(frame);
      }

      _log('[client] results: JSON pose(s) -> emitted frame');
    } catch (e) {
      _log('[client] JSON pose parse error: $e -> requesting KF');
      _sendCtrlKF();
    }
  }

  // ── New helpers ──────────────────────────────────────────────────────────────
  void _enqueueBinary(String task, Uint8List buf) {
    // keep only the newest packet for this task
    _pendingBin[task] = buf;
    if (_parsingTasks.contains(task)) return;
    _parsingTasks.add(task);
    // process in microtask to leave DC thread ASAP
    scheduleMicrotask(() => _drainParseLoop(task));
  }

  void _drainParseLoop(String task) {
    // Parse until the queue for this task is empty; always pick the latest.
    Uint8List? buf = _pendingBin.remove(task);
    int? lastAckToSend;

    while (buf != null && !_disposed) {
      try {
        final parser = _parsers.putIfAbsent(task, () => PoseBinaryParser());
        final res = parser.parse(buf);

        if (res is PoseParseOk) {
          final pkt = res.packet;
          final int? seq = pkt.seq;

          if (pkt.kind == PacketKind.pd && !pkt.keyframe && seq != null) {
            final int? last = _lastSeqPerTask[task];
            // drop stale PD
            if (last != null && !_isNewer16(seq, last)) {
              if (task == _primaryTask && res.ackSeq != null) {
                lastAckToSend = res.ackSeq!;
              }
              buf = _pendingBin.remove(task); // take the newest and continue
              continue;
            }
          }

          _lastW = pkt.w; _lastH = pkt.h;
          _lastPosesPerTask[task] = pkt.poses;
          if (pkt.seq != null) _lastSeqPerTask[task] = pkt.seq!;

          // Face: push 2D to the ValueNotifier (small)
          if (task == 'face') {
            final twoD = pkt.poses
                .map((pose) => pose.map((p) => Offset(p.x, p.y)).toList(growable: false))
                .toList(growable: false);
            _faceLmk.value = LmkState(
              last: twoD,
              lastSeq: pkt.seq ?? _faceLmk.value.lastSeq,
              lastTs: DateTime.now(),
            );
          }

          // fuse + emit (throttled below in §2)
          final fused = _lastPosesPerTask.values
              .expand((l) => l)
              .toList(growable: false);
          _emitBinaryThrottled(pkt.w, pkt.h, fused,
              kind: pkt.kind == PacketKind.po ? 'PO' : (pkt.keyframe ? 'PD(KF)' : 'PD'),
              seq: pkt.seq);

          if (task == _primaryTask && res.ackSeq != null) {
            lastAckToSend = res.ackSeq!;
          }
          if (res.requestKeyframe) _maybeSendKF();
        } else if (res is PoseParseNeedKF) {
          _maybeSendKF();
        }
      } catch (_) {
        _maybeSendKF();
      }

      // get newest pending (drop intermediate)
      buf = _pendingBin.remove(task);
    }

    // coalesce ACK: send only the last one seen in this run
    if (lastAckToSend != null && lastAckToSend != _lastAckSeqSent) {
      _lastAckSeqSent = lastAckToSend!;
      _sendCtrlAck(lastAckToSend!);
    }
    _parsingTasks.remove(task);
  }

  void _maybeSendKF() {
    final now = DateTime.now();
    if (now.difference(_lastKfReq).inMilliseconds >= 300) {
      _lastKfReq = now;
      _sendCtrlKF();
    }
  }

  // Minimal passthrough; if you later add FPS throttling, plug it here.
  void _emitBinaryThrottled(
    int w,
    int h,
    List<List<PosePoint>> poses3d, {
    required String kind,
    int? seq,
  }) {
    _emitBinary(w, h, poses3d, kind: kind, seq: seq);
  }

  void _handleTaskBinary(String task, Uint8List b) {
    // NOTE: legacy path kept for reference. New fast-path uses _enqueueBinary.
    final parser = _parsers.putIfAbsent(task, () => PoseBinaryParser());
    final res = parser.parse(b);

    if (res is PoseParseOk) {
      final pkt = res.packet;
      final int? seq = pkt.seq;

      if (pkt.kind == PacketKind.pd && !pkt.keyframe && seq != null) {
        final int? last = _lastSeqPerTask[task];
        if (last != null && !_isNewer16(seq, last)) {
          _log("[client] drop stale PD task=$task seq=$seq (last=$last)");
          if (task == _primaryTask && res.ackSeq != null) {
            _sendCtrlAck(res.ackSeq!);
          }
          return;
        }
      }

      _lastW = pkt.w;
      _lastH = pkt.h;
      _lastPosesPerTask[task] = pkt.poses;
      if (seq != null) _lastSeqPerTask[task] = seq;

      if (task == 'face') {
        final twoD = pkt.poses
            .map((pose) =>
                pose.map((p) => Offset(p.x, p.y)).toList(growable: false))
            .toList(growable: false);

        _faceLmk.value = LmkState(
          last: twoD,
          lastSeq: seq ?? _faceLmk.value.lastSeq,
          lastTs: DateTime.now(),
        );
      }

      final fused = _lastPosesPerTask.values.expand((l) => l).toList(growable: false);
      _emitBinary(
        pkt.w,
        pkt.h,
        fused,
        kind: pkt.kind == PacketKind.po ? 'PO' : (pkt.keyframe ? 'PD(KF)' : 'PD'),
        seq: pkt.seq,
      );

      if (task == _primaryTask && res.ackSeq != null) {
        _sendCtrlAck(res.ackSeq!);
      }
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
    List<List<PosePoint>> poses3d, {
    required String kind,
    int? seq,
  }) {
    if (_disposed) return;

    final poses2d = poses3d
        .map((pose) => pose.map((p) => Offset(p.x, p.y)).toList(growable: false))
        .toList(growable: false);

    final frame = PoseFrame(
      imageSize: Size(w.toDouble(), h.toDouble()),
      posesPx: poses2d,
    );

    _log('[client] emit frame kind=$kind seq=${seq ?? '-'} '
        'poses=${poses2d.length} size=${w}x$h');

    _latestFrame.value = frame;
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
    out[0] = 0x41;
    out[1] = 0x43;
    out[2] = 0x4B;
    out[3] = (seq & 0xFF);
    out[4] = ((seq >> 8) & 0xFF);

    _log('[client] sending ACK seq=$seq over ctrl');
    c.send(RTCDataChannelMessage.fromBinary(out));
  }

  void _dumpSdp(String tag, String? sdp) {
    if (!logEverything || sdp == null) return;

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
        if (_latestFrame.value != null) return;

        final dcOpen = _dc?.state == RTCDataChannelState.RTCDataChannelOpen;
        final ctrlOpen = _ctrl?.state == RTCDataChannelState.RTCDataChannelOpen;

        if (dcOpen || ctrlOpen) {
          _log('[client] no results yet, channels open → re-nudge (HELLO+KF)');
          _nudgeServer();
          return;
        }

        _log('[client] no results and DCs closed → recreating negotiated DCs with hashed IDs');
        await _recreateNegotiatedChannels();
      },
    );
  }

  String _stripVideoFec(String sdp) {
    final lines = sdp.split(RegExp(r'\r?\n'));
    final fecNames = {'red', 'ulpfec', 'flexfec-03'};
    final fecPts = <String>{};

    for (final l in lines) {
      final m = RegExp(r'^a=rtpmap:(\d+)\s+([A-Za-z0-9\-]+)/').firstMatch(l);
      if (m != null) {
        final pt = m.group(1)!;
        final codec = (m.group(2) ?? '').toLowerCase();
        if (fecNames.contains(codec)) fecPts.add(pt);
      }
    }
    if (fecPts.isEmpty) return sdp;

    final out = <String>[];
    for (final l in lines) {
      if (l.startsWith('m=video')) {
        final parts = l.split(' ');
        final head = parts.take(3);
        final payloads = parts.skip(3).where((pt) => !fecPts.contains(pt));
        out.add([...head, ...payloads].join(' '));
        continue;
      }

      bool isFecSpecific = false;
      for (final prefix in ['a=rtpmap:', 'a=fmtp:', 'a=rtcp-fb:']) {
        final m = RegExp('^' + RegExp.escape(prefix) + r'(\d+)').firstMatch(l);
        if (m != null && fecPts.contains(m.group(1)!)) {
          isFecSpecific = true;
          break;
        }
      }
      if (!isFecSpecific) out.add(l);
    }
    return out.join('\r\n');
  }

  String _stripVideoRtxNackAndRemb(String sdp,
      {bool dropNack = true, bool dropRtx = true, bool keepTransportCcOnly = true}) {
    final lines = sdp.split(RegExp(r'\r?\n'));
    final rtxPts = <String>{};

    for (final l in lines) {
      final m = RegExp(r'^a=rtpmap:(\d+)\s+rtx/').firstMatch(l);
      if (m != null) rtxPts.add(m.group(1)!);
    }

    bool inVideo = false;
    final out = <String>[];
    for (final l in lines) {
      if (l.startsWith('m=')) inVideo = l.startsWith('m=video');

      if (inVideo) {
        if (dropRtx && l.startsWith('m=video')) {
          final parts = l.split(' ');
          final head = parts.take(3);
          final payloads = parts.skip(3).where((pt) => !rtxPts.contains(pt));
          out.add([...head, ...payloads].join(' '));
          continue;
        }

        if (dropRtx && RegExp(r'^a=(rtpmap|fmtp|rtcp-fb):(\d+)').hasMatch(l)) {
          final m = RegExp(r'^a=(?:rtpmap|fmtp|rtcp-fb):(\d+)').firstMatch(l);
          if (m != null && rtxPts.contains(m.group(1)!)) continue;
        }

        if (dropNack && l.startsWith('a=rtcp-fb:')) {
          if (keepTransportCcOnly) {
            if (l.contains('transport-cc')) {
              out.add(l);
              continue;
            }
            continue;
          } else {
            if (l.contains('nack') || l.contains('ccm fir') || l.contains('pli')) {
              continue;
            }
          }
        }
      }
      out.add(l);
    }
    return out.join('\r\n');
  }

  String _keepOnlyVideoCodecs(String sdp, List<String> codecNamesLower) {
    final lines = sdp.split(RegExp(r'\r?\n'));
    final keepPts = <String>{};

    for (final l in lines) {
      final m = RegExp(r'^a=rtpmap:(\d+)\s+([A-Za-z0-9\-]+)/').firstMatch(l);
      if (m != null) {
        final pt = m.group(1)!;
        final codec = (m.group(2) ?? '').toLowerCase();
        if (codecNamesLower.contains(codec)) keepPts.add(pt);
      }
    }
    if (keepPts.isEmpty) return sdp;

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
        if (m != null && !keepPts.contains(m.group(1))) continue;
      }

      out.add(l);
    }

    return out.join('\r\n');
  }
}