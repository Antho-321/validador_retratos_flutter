// lib/apps/asistente_retratos/infrastructure/services/pose_webrtc_service_imp.dart

import 'dart:async';
import 'dart:convert' show jsonDecode, jsonEncode, utf8;
import 'dart:typed_data';
import 'dart:ui' show Offset, Size;
import 'dart:isolate';

import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;

import '../../domain/service/pose_capture_service.dart';
import '../../domain/model/lmk_state.dart';
import '../model/pose_frame.dart' show PoseFrame, poseFrameFromMap;
import '../webrtc/rtc_video_encoder.dart';
import '../model/pose_point.dart';
import 'package:hashlib/hashlib.dart';
import '../parsers/pose_parse_isolate.dart' show poseParseIsolateEntry;

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
    this.logEverything = true, // ya no se usa; mantenido por compatibilidad
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
  final bool logEverything; // no-op
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

  // ── Isolate de parseo ──────────────────────────────────────────────────────
  Isolate? _parseIsolate;
  ReceivePort? _parseRx;
  SendPort? _parseSendPort;
  StreamSubscription? _parseRxSub;

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

  // Face
  final ValueNotifier<LmkState> _faceLmk = ValueNotifier<LmkState>(LmkState());
  @override
  ValueListenable<LmkState> get faceLandmarks => _faceLmk;
  List<List<Offset>>? _lastFace2D;
  List<Float32List>? _lastFaceFlat;

  // Pose (nuevo)
  final ValueNotifier<LmkState> _poseLmk = ValueNotifier<LmkState>(LmkState());
  @override
  ValueListenable<LmkState> get poseLandmarks => _poseLmk;
  List<Float32List>? _lastPoseFlat3d;

  @override
  List<List<Offset>>? get latestFaceLandmarks {
    final fast = _lastFace2D;
    if (fast != null) return fast;
    final faces3d = _lastPosesPerTask['face'];
    if (faces3d == null) return null;
    return faces3d
        .map((pose) => pose
            .map((p) => Offset(p.x, p.y))
            .toList(growable: false))
        .toList(growable: false);
  }

  @override
  List<PosePoint>? get latestPoseLandmarks3D {
    final flat3 = _poseLmk.value.lastFlat3d; // NEW
    if (flat3 != null && flat3.isNotEmpty) {
      final f = flat3.first;
      final n = f.length ~/ 3;
      return List<PosePoint>.generate(
        n,
        (i) => PosePoint(x: f[i * 3], y: f[i * 3 + 1], z: f[i * 3 + 2]),
        growable: false,
      );
    }
    final flat2 = _poseLmk.value.lastFlat;
    if (flat2 != null && flat2.isNotEmpty) {
      final f = flat2.first;
      final n = f.length ~/ 2;
      return List<PosePoint>.generate(
        n,
        (i) => PosePoint(x: f[i * 2], y: f[i * 2 + 1], z: 0),
        growable: false,
      );
    }
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
  // ── Add fields ───────────────────────────────────────────────────────────────
  Timer? _emitGate;
  PoseFrame? _pendingFrame;
  DateTime _lastEmit = DateTime.fromMillisecondsSinceEpoch(0);
  int get _minEmitIntervalMs => ((1000 ~/ idealFps).clamp(8, 1000) as int);
  // Reuse a single ACK buffer to avoid per-send allocations
  final Uint8List _ackBuf = Uint8List(5)..setAll(0, [0x41, 0x43, 0x4B, 0, 0]);

  // No-op logger (se eliminaron todas las salidas)
  void _log(Object? message) {}

  String _forceTurnUdp(String url) {
    return url.contains('?') ? url : '$url?transport=udp';
  }

  @override
  Future<void> init() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();

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

    _localStream = await navigator.mediaDevices.getUserMedia(mediaConstraints);
    _localRenderer.srcObject = _localStream;

    void _updateSize() {
      final vw = _localRenderer.videoWidth;
      final vh = _localRenderer.videoHeight;
      if (vw > 0 && vh > 0) {
        _lastW = vw;
        _lastH = vh;
      }
    }

    _localRenderer.onResize = _updateSize;
    _updateSize();

    try {
      final dynamic dtrack = _localStream!.getVideoTracks().first;
      await dtrack.setVideoContentHint('motion');
    } catch (_) {}
  }

  @override
  Future<void> connect() async {
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

    // Handlers sin logs
    _pc!.onIceGatheringState = (_) {};
    _pc!.onIceConnectionState = (_) {};
    _pc!.onSignalingState = (_) {};
    _pc!.onConnectionState = (_) {};
    _pc!.onRenegotiationNeeded = () {};

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
        _wireResults(ch, task: task);
      }

      final reliable = RTCDataChannelInit()
        ..negotiated = true
        ..id = 1
        ..ordered = true;
      _ctrl = await _pc!.createDataChannel('ctrl', reliable);
      _wireCtrl(_ctrl!);
    }

    _pc!.onDataChannel = (RTCDataChannel ch) {
      final label = ch.label ?? '';
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

    _pc!.onTrack = (RTCTrackEvent e) {
      if (e.track.kind == 'video' && e.streams.isNotEmpty) {
        _remoteRenderer.srcObject = e.streams.first;
      }
    };

    await _encoder.applyTo(_videoTransceiver!);

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

    await _pc!.setLocalDescription(offer);

    await _waitIceGatheringComplete(_pc!);
    final local = await _pc!.getLocalDescription();

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
      throw Exception('Signaling failed: ${res.statusCode} ${res.body}');
    }

    final ansMap = jsonDecode(res.body) as Map<String, dynamic>;
    await _pc!.setRemoteDescription(
      RTCSessionDescription(
        ansMap['sdp'] as String,
        (ansMap['type'] as String?) ?? 'answer',
      ),
    );

    _startRtpStatsProbe();
    _startNoResultsGuard();

    if (_parseIsolate == null) {
      _parseRx = ReceivePort();
      _parseIsolate = await Isolate.spawn(
        poseParseIsolateEntry,
        _parseRx!.sendPort,
      );

      _parseRxSub = _parseRx!.listen((msg) {
        if (msg is SendPort) {
          _parseSendPort = msg;
          return;
        }
        _onParseResultFromIsolate(msg);
      });
    }
  }

  @override
  Future<void> switchCamera() async {
    final tracks = _localStream?.getVideoTracks();
    if (tracks == null || tracks.isEmpty) return;
    try {
      await Helper.switchCamera(tracks.first);
      if (_videoTransceiver != null) {
        await _encoder.applyTo(_videoTransceiver!);
      }
    } catch (_) {}
  }

  Future<void> close() => dispose();

  @override
  Future<void> dispose() async {
    _disposed = true;
    _lastFace2D = null;
    _lastFaceFlat = null;

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

    try { await _parseRxSub?.cancel(); } catch (_) {}
    try { _parseRx?.close(); } catch (_) {}
    try { _parseIsolate?.kill(priority: Isolate.immediate); } catch (_) {}

    _parseRxSub = null;
    _parseIsolate = null;
    _parseRx = null;
    _parseSendPort = null;
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
        c.complete();
        pc.onIceGatheringState = prev;
      }
    };

    Timer(const Duration(seconds: 2), () {
      if (!c.isCompleted) {
        c.complete();
        pc.onIceGatheringState = prev;
      }
    });

    return c.future;
  }

  void _publishLegacyFromFlat2D(String task, List<Float32List> flat2d) {
    final out = <List<PosePoint>>[];
    for (final f in flat2d) {
      final n = f.length ~/ 2;
      out.add(List<PosePoint>.generate(
        n,
        (i) => PosePoint(x: f[i * 2], y: f[i * 2 + 1], z: 0),
        growable: false,
      ));
    }
    _lastPosesPerTask[task] = out;
  }

  void _publishLegacyFromFlat3D(String task, List<Float32List> flat3d) {
    final out = <List<PosePoint>>[];
    for (final f in flat3d) {
      final n = f.length ~/ 3;
      out.add(List<PosePoint>.generate(
        n,
        (i) => PosePoint(x: f[i * 3], y: f[i * 3 + 1], z: f[i * 3 + 2]),
        growable: false,
      ));
    }
    _lastPosesPerTask[task] = out;
  }

  // ── Handler del isolate de parseo ──────────────────────────────────────────
  void _onParseResultFromIsolate(dynamic msg) {
    if (_disposed || msg is! Map) return;

    final String? task = msg['task'] as String?;
    final String? type = msg['type'] as String?;

    // libera el flag y relanza si quedó algo
    if (task != null) {
      _parsingTasks.remove(task);
      if (_pendingBin.containsKey(task)) {
        scheduleMicrotask(() => _drainParseLoop(task));
      }
    }

    // ⬇️ ACK opcional desde el isolate
    final int? ack = msg['ack'] as int?;
    if (ack != null) _sendCtrlAck(ack);

    if (type == 'ok2d') {
      final int? w =
          (msg['w'] as int?) ?? _lastW ?? _localRenderer.videoWidth;
      final int? h =
          (msg['h'] as int?) ?? _lastH ?? _localRenderer.videoHeight;
      if (w == null || h == null || w == 0 || h == 0) return;

      final int? seq = msg['seq'] as int?;
      final bool kf = (msg['keyframe'] as bool?) ?? false;
      final List<Float32List> poses2d =
          (msg['poses2d'] as List).cast<Float32List>();

      _lastW = w;
      _lastH = h;
      if (seq != null && task != null) _lastSeqPerTask[task] = seq;

      if (task == 'face') {
        _lastFaceFlat = poses2d;
        _lastFace2D = poses2d
            .map((f) => List<Offset>.generate(
                  f.length ~/ 2,
                  (i) => Offset(f[i * 2], f[i * 2 + 1]),
                  growable: false,
                ))
            .toList(growable: false);
      }

      if (task != null) {
        _publishLegacyFromFlat2D(task, poses2d);
        if (seq != null) _lastSeqPerTask[task] = seq;
      }

      final frame = PoseFrame(
        imageSize: Size(w.toDouble(), h.toDouble()),
        posesPxFlat: poses2d,
      );
      _emitBinaryThrottled(frame, kind: kf ? 'PD(KF)' : 'PD', seq: seq);
    } else if (type == 'ok3d') {
      final int? w = (msg['w'] as int?) ?? _lastW ?? _localRenderer.videoWidth;
      final int? h = (msg['h'] as int?) ?? _lastH ?? _localRenderer.videoHeight;
      if (w == null || h == null || w == 0 || h == 0) return;

      final int? seq = msg['seq'] as int?;
      final bool kf = (msg['keyframe'] as bool?) ?? false;
      final String task = (msg['task'] as String?)?.toLowerCase() ?? 'pose';

      // 1) Lee 3D del isolate
      final List<Float32List> poses3dIn =
          (msg['poses3d'] as List).cast<Float32List>();

      // 2) Escala 3D a píxeles si venía normalizado, y úsalo en TODO
      final List<Float32List> poses3dPx = <Float32List>[];
      for (final f3 in poses3dIn) {
        final n = f3.length ~/ 3;
        final f3px = Float32List(f3.length);
        for (var i = 0; i < n; i++) {
          final double x = f3[i * 3];
          final double y = f3[i * 3 + 1];
          final double z = f3[i * 3 + 2];
          final bool nrm = (x >= 0 && x <= 1.2 && y >= 0 && y <= 1.2);
          f3px[i * 3]     = nrm ? (x * w) : x;
          f3px[i * 3 + 1] = nrm ? (y * h) : y;
          f3px[i * 3 + 2] = z;
        }
        poses3dPx.add(f3px);
      }

      _lastW = w;
      _lastH = h;
      if (seq != null) _lastSeqPerTask[task] = seq;

      // 3) Publica SIEMPRE la versión en píxeles
      _publishLegacyFromFlat3D(task, poses3dPx);    // legacy en píxeles
      if (task == 'pose') _lastPoseFlat3d = poses3dPx;

      // (opcional, si sigues poblando manualmente legacy):
      // _lastPosesPerTask[task] = poses3dPx.map((f) {
      //   final n = f.length ~/ 3;
      //   return List<PosePoint>.generate(
      //     n, (i) => PosePoint(x: f[i*3], y: f[i*3+1], z: f[i*3+2]),
      //     growable: false,
      //   );
      // }).toList(growable: false);

      // 4) Deriva 2D a partir del MISMO batch ya en píxeles (para overlay/frame)
      final List<Float32List> poses2d = <Float32List>[];
      for (final f3px in poses3dPx) {
        final n = f3px.length ~/ 3;
        final f2 = Float32List(n * 2);
        for (var i = 0; i < n; i++) {
          f2[i * 2]     = f3px[i * 3];
          f2[i * 2 + 1] = f3px[i * 3 + 1];
        }
        poses2d.add(f2);
      }

      final frame = PoseFrame(
        imageSize: Size(w.toDouble(), h.toDouble()),
        posesPxFlat: poses2d,
      );

      // 5) (Recomendado) Actualiza _poseLmk con este mismo batch para evitar “drift”
      final nextSeq = (seq ?? _poseLmk.value.lastSeq) + 1;
      _poseLmk.value = LmkState.fromFlat3d(
        poses3dPx,
        lastSeq: nextSeq,
        imageSize: frame.imageSize,
      ).copyWith(lastFlat: poses2d);

      _emitBinaryThrottled(frame, kind: kf ? 'PD(KF)' : 'PD', seq: seq);
    } else if (type == 'need_kf') {
      _maybeSendKF();
    }
  }

  void _wireResults(RTCDataChannel ch, {required String task}) {
    ch.onDataChannelState = (s) {
      if (s == RTCDataChannelState.RTCDataChannelOpen) {
        // no-op
      } else if (s == RTCDataChannelState.RTCDataChannelClosed) {
        // no-op
      }
    };

    ch.onMessage = (RTCDataChannelMessage m) {
      if (m.isBinary) {
        _enqueueBinary(task, m.binary);
      } else {
        final txtRaw = m.text ?? '';
        final txt = txtRaw.trim();
        if (txt.toUpperCase() == 'KF') {
          // ignorar
        } else {
          _handlePoseText(txtRaw);
        }
      }
    };
  }

  void _wireCtrl(RTCDataChannel ch) {
    ch.onDataChannelState = (s) {
      if (s == RTCDataChannelState.RTCDataChannelOpen) {
        _nudgeServer();
      } else if (s == RTCDataChannelState.RTCDataChannelClosed) {
        // no-op
      }
    };

    ch.onMessage = (RTCDataChannelMessage m) {
      // no-op (silenciar ctrl)
    };
  }

  void _nudgeServer() {
    final c = _ctrl;
    if (c == null) return;
    if (c.state != RTCDataChannelState.RTCDataChannelOpen) return;
    c.send(RTCDataChannelMessage('HELLO'));
    c.send(RTCDataChannelMessage('KF'));
  }

  Future<void> _recreateNegotiatedChannels() async {
    final pc = _pc;
    if (pc == null) return;

    if (_dc?.state == RTCDataChannelState.RTCDataChannelOpen ||
        _ctrl?.state == RTCDataChannelState.RTCDataChannelOpen) {
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
      _wireCtrl(_ctrl!);
    } catch (_) {}

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
        _wireResults(ch, task: task);
      } catch (_) {}
    }
  }

  void _handlePoseText(String text) {
    try {
      final m = _parseJson(text);
      final PoseFrame? raw = poseFrameFromMap(m);
      if (raw == null) return;

      final int w = _lastW ?? idealWidth;
      final int h = _lastH ?? idealHeight;

      PoseFrame out = raw;

      // --- 1) Escalar poses si vienen normalizadas [0..1] ---
      if (raw.posesPx != null && raw.posesPx!.isNotEmpty) {
        final isNormalized = raw.posesPx!.every(
          (pose) => pose.every(
            (p) => p.dx >= 0 && p.dx <= 1.2 && p.dy >= 0 && p.dy <= 1.2,
          ),
        );

        if (isNormalized) {
          final scaled = raw.posesPx!
              .map((pose) => pose
                  .map((p) => Offset(p.dx * w, p.dy * h))
                  .toList(growable: false))
              .toList(growable: false);

          out = PoseFrame(
            imageSize: Size(w.toDouble(), h.toDouble()),
            posesPx: scaled,
          );
        } else if (raw.imageSize.width <= 4 || raw.imageSize.height <= 4) {
          // Completa imageSize si falta
          out = PoseFrame(
            imageSize: Size(w.toDouble(), h.toDouble()),
            posesPx: raw.posesPx,
          );
        }
      }

      // --- 2) FACE 2D opcional ---
      final faces = m['faces'] as List<dynamic>?;
      if (faces != null) {
        final List<Float32List> flat = <Float32List>[];
        for (final face in faces) {
          final List<dynamic> lmk = face as List<dynamic>;
          final f = Float32List(lmk.length * 2);
          for (var i = 0; i < lmk.length; i++) {
            final Map<String, dynamic> pt = lmk[i] as Map<String, dynamic>;
            final double x = (pt['x'] as num).toDouble();
            final double y = (pt['y'] as num).toDouble();
            final bool nrm = (x >= 0 && x <= 1.2 && y >= 0 && y <= 1.2);
            f[i * 2] = nrm ? (x * w) : x;
            f[i * 2 + 1] = nrm ? (y * h) : y;
          }
          flat.add(f);
        }

        _lastFaceFlat = flat;
        _lastFace2D = flat
            .map((f) => List<Offset>.generate(
                  f.length ~/ 2,
                  (i) => Offset(f[i * 2], f[i * 2 + 1]),
                  growable: false,
                ))
            .toList(growable: false);

        // Alimentar legacy solo desde fast-path
        _publishLegacyFromFlat2D('face', flat);

        _faceLmk.value = LmkState(
          last: _lastFace2D,
          lastFlat: _lastFaceFlat,
          lastSeq: _faceLmk.value.lastSeq + 1,
          lastTs: DateTime.now(),
          imageSize: Size(w.toDouble(), h.toDouble()),
        );
      }

      // --- 2b) POSE (XYZ) opcional ---
      final posesJson = m['poses'] as List<dynamic>?;
      if (posesJson != null) {
        final List<Float32List> flat2d = <Float32List>[];
        final List<Float32List> flat3d = <Float32List>[];

        for (final pose in posesJson) {
          final List<dynamic> lmk = pose as List<dynamic>;

          final f2 = Float32List(lmk.length * 2);
          final f3 = Float32List(lmk.length * 3);

          for (var i = 0; i < lmk.length; i++) {
            final Map<String, dynamic> pt = lmk[i] as Map<String, dynamic>;
            final double x = (pt['x'] as num).toDouble();
            final double y = (pt['y'] as num).toDouble();
            final double z = (pt['z'] as num?)?.toDouble() ?? 0.0;

            final bool nrm = (x >= 0 && x <= 1.2 && y >= 0 && y <= 1.2);
            final double X = nrm ? (x * w) : x;
            final double Y = nrm ? (y * h) : y;

            f2[i * 2] = X;
            f2[i * 2 + 1] = Y;

            f3[i * 3] = X;
            f3[i * 3 + 1] = Y;
            f3[i * 3 + 2] = z;
          }
          flat2d.add(f2);
          flat3d.add(f3);
        }

        _lastPoseFlat3d = flat3d;
        // Alimentar legacy solo desde fast-path
        _publishLegacyFromFlat3D('pose', flat3d);

        // Asegura que el frame a emitir tenga 2D px
        out = PoseFrame(
          imageSize: Size(w.toDouble(), h.toDouble()),
          posesPxFlat: flat2d,
        );
      }

      // --- 3) Emitir TODO por el mismo throttle que la ruta binaria ---
      final int? seqFromJson = m['seq'] as int?;
      _emitBinaryThrottled(out, kind: 'JSON', seq: seqFromJson);
    } catch (_) {
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
    // Siempre tomar el más nuevo para este task
    final Uint8List? buf = _pendingBin.remove(task);
    if (buf == null || _disposed) {
      // nada que parsear; liberar el flag
      _parsingTasks.remove(task);
      return;
    }

    try {
      // Offload al isolate de parseo
      final ttd = TransferableTypedData.fromList([buf]);
      _parseSendPort?.send({
        'type': 'job',
        'task': task,
        'data': ttd,
      });

      // Importante: no liberar _parsingTasks aquí.
      // Esperamos la respuesta en _onParseResultFromIsolate, que liberará el flag
      // y relanzará el drain si quedó algo nuevo en cola.
      return;
    } catch (_) {
      _maybeSendKF();
      _parsingTasks.remove(task);
    }
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
    PoseFrame frame, {
    required String kind,
    int? seq,
  }) {
    if (_disposed) return;

    final now = DateTime.now();
    final elapsed = now.difference(_lastEmit).inMilliseconds;

    if (elapsed >= _minEmitIntervalMs && _emitGate == null) {
      _lastEmit = now;
      _doEmit(frame, kind: kind, seq: seq);
      return;
    }

    final waitMs =
        (_minEmitIntervalMs - elapsed) > 0 ? (_minEmitIntervalMs - elapsed) : 0;
    _pendingFrame = frame;
    _emitGate ??= Timer(Duration(milliseconds: waitMs), () {
      _emitGate = null;
      final f = _pendingFrame;
      _pendingFrame = null;
      if (f != null && !_disposed) {
        _lastEmit = DateTime.now();
        _doEmit(f, kind: kind, seq: seq);
      }
    });
  }

  void _doEmit(PoseFrame frame, {required String kind, int? seq}) {
    // Asegura pxFlat a partir de legacy si hace falta
    List<Float32List>? pxFlat = frame.posesPxFlat;
    final pxLegacy = frame.posesPx;

    if ((pxFlat == null || pxFlat.isEmpty) &&
        pxLegacy != null &&
        pxLegacy.isNotEmpty) {
      pxFlat = pxLegacy.map((pose) {
        final f = Float32List(pose.length * 2);
        for (var i = 0; i < pose.length; i++) {
          f[i * 2] = pose[i].dx;
          f[i * 2 + 1] = pose[i].dy;
        }
        return f;
      }).toList(growable: false);
    }

    _latestFrame.value = frame;

    // --- FACE (ya existente) ---
    final lf = _lastFace2D;
    final lff = _lastFaceFlat;
    if (lf != null || lff != null) {
      _faceLmk.value = LmkState(
        last: lf,
        lastFlat: lff,
        lastSeq: seq ?? _faceLmk.value.lastSeq,
        lastTs: DateTime.now(),
        imageSize: frame.imageSize,
      );
    }

    // --- POSE (preferir 3D si se tiene) ---
    if (_lastPoseFlat3d != null && _lastPoseFlat3d!.isNotEmpty) {
      final nextSeq = (seq ?? _poseLmk.value.lastSeq) + 1;

      // Publica 3D como fast-path y, si existe, también 2D (pxFlat) para overlays
      _poseLmk.value = LmkState.fromFlat3d(
        _lastPoseFlat3d!,
        lastSeq: nextSeq,
        imageSize: frame.imageSize,
      ).copyWith(
        lastFlat: (pxFlat != null && pxFlat.isNotEmpty) ? pxFlat : null,
      );
    } else if (pxFlat != null && pxFlat.isNotEmpty) {
      // Fallback a 2D si no hay 3D
      final nextSeq = (seq ?? _poseLmk.value.lastSeq) + 1;
      _poseLmk.value = LmkState.fromFlat(
        pxFlat,
        lastSeq: nextSeq,
        imageSize: frame.imageSize,
      );
    }

    if (!_framesCtrl.isClosed) _framesCtrl.add(frame);
  }

  void _sendCtrlKF() {
    final c = _ctrl;
    if (c == null || c.state != RTCDataChannelState.RTCDataChannelOpen) return;
    c.send(RTCDataChannelMessage('KF'));
  }

  void _sendCtrlAck(int seq) {
    final c = _ctrl;
    if (c == null || c.state != RTCDataChannelState.RTCDataChannelOpen) return;
    _ackBuf[3] = (seq & 0xFF);
    _ackBuf[4] = ((seq >> 8) & 0xFF);
    c.send(RTCDataChannelMessage.fromBinary(_ackBuf));
  }

  // No-op: se eliminó el volcado de SDP a logs
  void _dumpSdp(String tag, String? sdp) {}

  // No-op: se eliminó el sondeo periódico de stats (y cualquier log)
  void _startRtpStatsProbe() {
    _rtpStatsTimer?.cancel();
    _rtpStatsTimer = null;
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
        final ctrlOpen =
            _ctrl?.state == RTCDataChannelState.RTCDataChannelOpen;

        if (dcOpen || ctrlOpen) {
          _nudgeServer();
          return;
        }

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

  String _stripVideoRtxNackAndRemb(String sdp,
      {bool dropNack = true,
      bool dropRtx = true,
      bool keepTransportCcOnly = true}) {
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
          final payloads =
              parts.skip(3).where((pt) => !rtxPts.contains(pt));
          out.add([...head, ...payloads].join(' '));
          continue;
        }

        if (dropRtx && RegExp(r'^a=(rtpmap|fmtp|rtcp-fb):(\d+)').hasMatch(l)) {
          final m =
              RegExp(r'^a=(?:rtpmap|fmtp|rtcp-fb):(\d+)').firstMatch(l);
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
            if (l.contains('nack') ||
                l.contains('ccm fir') ||
                l.contains('pli')) {
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
        final m =
            RegExp(r'^a=(?:rtpmap|fmtp|rtcp-fb):(\d+)').firstMatch(l);
        if (m != null && !keepPts.contains(m.group(1))) continue;
      }

      out.add(l);
    }

    return out.join('\r\n');
  }
}