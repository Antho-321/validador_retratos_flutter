// lib/apps/asistente_retratos/infrastructure/services/pose_webrtc_service_imp.dart

import 'dart:async';
import 'dart:convert' show jsonDecode, jsonEncode, utf8;
import 'dart:typed_data';
import 'dart:ui' show Offset, Size;
import 'dart:isolate';

import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;

import '../../domain/service/pose_capture_service.dart';
import '../../domain/model/lmk_state.dart';
import '../model/pose_frame.dart' show PoseFrame;
import '../webrtc/rtc_video_encoder.dart';
import '../webrtc/sdp_utils.dart';
import '../model/pose_point.dart';
import 'package:hashlib/hashlib.dart';
import '../parsers/pose_parse_isolate.dart' show poseParseIsolateEntry;

class _PendingEmit {
  final PoseFrame frame;
  final String kind;
  final int? seq;

  const _PendingEmit(this.frame, this.kind, this.seq);
}

// ======================= Helpers y extensiones compactas =======================

extension _DCX on RTCDataChannel? {
  bool get isOpen => this?.state == RTCDataChannelState.RTCDataChannelOpen;
  void sendText(String s) {
    final c = this;
    if (c?.state == RTCDataChannelState.RTCDataChannelOpen) {
      c!.send(RTCDataChannelMessage(s));
    }
  }
  void sendBin(Uint8List b) {
    final c = this;
    if (c?.state == RTCDataChannelState.RTCDataChannelOpen) {
      c!.send(RTCDataChannelMessage.fromBinary(b));
    }
  }
  Future<void> safeClose() async { try { await this?.close(); } catch (_) {} }
}

Size _szWH(int w, int h) => Size(w.toDouble(), h.toDouble());

// Cache de Size para evitar micro-allocs en rutas calientes
Size? _cachedSize;
Size _szWHCached(int w, int h) {
  final dw = w.toDouble(), dh = h.toDouble();
  final s = _cachedSize;
  if (s != null && s.width == dw && s.height == dh) return s;
  final n = Size(dw, dh);
  _cachedSize = n;
  return n;
}

T? _silence<T>(T Function() f) { try { return f(); } catch (_) { return null; } }
Future<void> _silenceAsync(Future<void> Function() f) async { try { await f(); } catch (_) {} }

// ==============================================================================

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
    this.kfMinGapMs = 500, // configurable KF pacing
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
  final int kfMinGapMs;

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
  final Map<String, Timer?> _emitGateByTask = {};
  final Map<String, _PendingEmit?> _pendingByTask = {};
  final Map<String, DateTime> _lastEmitByTask = {};

  int _minEmitIntervalMsFor(String task) => (1000 ~/ idealFps).clamp(8, 1000);

  MediaStream? _localStream;
  @override
  MediaStream? get localStream => _localStream;

  RTCRtpTransceiver? _videoTransceiver;

  Timer? _rtpStatsTimer;
  Timer? _dcGuardTimer;
  bool _disposed = false;

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

  // sync:true para evitar microtasks innecesarias
  final _framesCtrl = StreamController<PoseFrame>.broadcast(sync: true);
  @override
  Stream<PoseFrame> get frames => _framesCtrl.stream;

  final ValueNotifier<LmkState> _faceLmk = ValueNotifier<LmkState>(LmkState());
  @override
  ValueListenable<LmkState> get faceLandmarks => _faceLmk;

  final ValueNotifier<LmkState> _poseLmk = ValueNotifier<LmkState>(LmkState());
  @override
  ValueListenable<LmkState> get poseLandmarks => _poseLmk;
  ValueListenable<LmkState> get poseLmk => _poseLmk;
  ValueListenable<LmkState> get faceLmk => _faceLmk;

  @override
  List<List<Offset>>? get latestFaceLandmarks {
    return _stateToOffsets(_faceLmk.value);
  }

  @override
  List<PosePoint>? get latestPoseLandmarks3D {
    return _stateToPosePoints(_poseLmk.value);
  }

  @override
  List<Offset>? get latestPoseLandmarks {
    final pose = _stateToOffsets(_poseLmk.value);
    if (pose == null || pose.isEmpty) return null;
    return pose.first;
  }

  int? _lastW;
  int? _lastH;

  final Map<String, int> _lastSeqPerTask = {};
  bool _isNewer16(int seq, int? last) {
    if (last == null) return true;
    final int d = (seq - last) & 0xFFFF;
    return d != 0 && (d & 0x8000) == 0;
  }

  final Map<String, Uint8List?> _pendingBin = {};
  final Set<String> _parsingTasks = {};
  int _lastAckSeqSent = -1;
  DateTime _lastKfReq = DateTime.fromMillisecondsSinceEpoch(0);
  final Uint8List _ackBuf = Uint8List(5)..setAll(0, [0x41, 0x43, 0x4B, 0, 0]);

  String _forceTurnUdp(String url) => url.contains('?') ? url : '$url?transport=udp';

  // ====== Overlay repaint coalescing =========================================
  final ValueNotifier<int> overlayTick = ValueNotifier<int>(0);
  bool _overlayScheduled = false;
  Duration _minGap = const Duration(milliseconds: 0); // o 33 ms (≈30 fps)
  DateTime _lastTick = DateTime.fromMillisecondsSinceEpoch(0);

  void _bumpOverlay() {
    if (_overlayScheduled) return;
    final now = DateTime.now();
    if (now.difference(_lastTick) < _minGap) return;
    _overlayScheduled = true;
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      _overlayScheduled = false;
      _lastTick = DateTime.now();
      overlayTick.value++;
    });
  }
  // ===========================================================================

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
        if (_lastW != vw) _lastW = vw;
        if (_lastH != vh) _lastH = vh;
      }
    }

    _localRenderer.onResize = _updateSize;
    _updateSize();

    _silence(() async {
      final dynamic dtrack = _localStream!.getVideoTracks().first;
      await dtrack.setVideoContentHint('motion');
    });
  }

  @override
  Future<void> connect() async {
    final config = <String, dynamic>{
      'sdpSemantics': 'unified-plan',
      'bundlePolicy': 'max-bundle',
      'iceCandidatePoolSize': 4,
      'iceServers': [
        if (_stunUrl?.isNotEmpty ?? false) {'urls': _stunUrl},
        if (_turnUrl?.isNotEmpty ?? false)
          {
            'urls': _forceTurnUdp(_turnUrl!),
            if ((_turnUsername ?? '').isNotEmpty) 'username': _turnUsername,
            if ((_turnPassword ?? '').isNotEmpty) 'credential': _turnPassword,
          },
      ],
    };

    _pc = await createPeerConnection(config);

    _pc!.onIceGatheringState = (state) {};
    _pc!.onIceConnectionState = (state) {};
    _pc!.onSignalingState = (state) {};
    _pc!.onConnectionState = (state) {};
    _pc!.onRenegotiationNeeded = () {};

    if (preCreateDataChannels) {
      final tasks = (requestedTasks.isEmpty) ? const ['pose'] : requestedTasks;
      await _ensureCtrlDC();
      for (final t in tasks.map((e) => e.toLowerCase().trim()).where((e) => e.isNotEmpty)) {
        await _createLossyDC(t);
      }
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

    var sdp = RtcVideoEncoder.mungeH264BitrateHints(offer.sdp!, kbps: maxBitrateKbps);
    if (stripFecFromSdp) sdp = stripVideoFec(sdp);
    if (stripRtxAndNackFromSdp) {
      sdp = stripVideoRtxNackAndRemb(sdp, dropNack: true, dropRtx: true, keepTransportCcOnly: keepTransportCcOnly);
    }
    sdp = keepOnlyVideoCodecs(sdp, preferHevc ? const ['h265'] : const ['h264']);
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

  Future<RTCDataChannel> _createLossyDC(String task) async {
    final lossy = RTCDataChannelInit()
      ..negotiated = true
      ..id = _dcIdFromTask(task)
      ..ordered = false
      ..maxRetransmits = 0;
    final ch = await _pc!.createDataChannel('results:$task', lossy);
    _resultsPerTask[task] = ch;
    if (task == _primaryTask) _dc = ch;
    _wireResults(ch, task: task);
    return ch;
  }

  Future<void> _ensureCtrlDC() async {
    if (_ctrl.isOpen) return;
    _ctrl = await _pc!.createDataChannel('ctrl', RTCDataChannelInit()
      ..negotiated = true
      ..id = 1
      ..ordered = true);
    _wireCtrl(_ctrl!);
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

    await _dc.safeClose();
    await _ctrl.safeClose();
    await _silenceAsync(() async { await _pc?.close(); });

    _silence(() => _localStream?.getTracks().forEach((t) { _silence(() { t.stop(); }); }));
    await _silenceAsync(() async { await _localRenderer.dispose(); });
    await _silenceAsync(() async { await _remoteRenderer.dispose(); });
    await _silenceAsync(() async { await _localStream?.dispose(); });
    _localStream = null;

    _rtpStatsTimer?.cancel();
    _dcGuardTimer?.cancel();
    await _framesCtrl.close();

    _lastSeqPerTask.clear();

    await _silenceAsync(() async { await _parseRxSub?.cancel(); });
    _silence(() => _parseRx?.close());
    _silence(() => _parseIsolate?.kill(priority: Isolate.immediate));

    _parseRxSub = null;
    _parseIsolate = null;
    _parseRx = null;
    _parseSendPort = null;

    overlayTick.dispose();
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

  void _handleParsed2D(Map msg, {String? fallbackTask}) {
    final t = (msg['task'] as String? ?? fallbackTask ?? 'pose').toLowerCase();
    final int w = (msg['w'] as int?) ?? _lastW ?? _localRenderer.videoWidth;
    final int h = (msg['h'] as int?) ?? _lastH ?? _localRenderer.videoHeight;
    if (w == 0 || h == 0) return;

    final seq = msg['seq'] as int?;
    final positions = msg['positions'] as Float32List?;
    final ranges = msg['ranges'] as Int32List?;
    final hasZ = (msg['hasZ'] as bool?) ?? false;
    final zPositions = hasZ ? msg['zPositions'] as Float32List? : null;

    if (positions == null || ranges == null) return;

    _lastW = w;
    _lastH = h;
    if (seq != null) {
      final last = _lastSeqPerTask[t];
      if (last != null && !_isNewer16(seq, last)) return;
      _lastSeqPerTask[t] = seq;
    }

    final imageSize = _szWHCached(w, h);

    final nextSeqFace = (seq ?? (_faceLmk.value.lastSeq + 1));
    final nextSeqPose = (seq ?? (_poseLmk.value.lastSeq + 1));

    if (t == 'face') {
      final cur = _faceLmk.value;
      if (nextSeqFace != cur.lastSeq ||
          !identical(cur.packedPositions, positions) ||
          !identical(cur.packedRanges, ranges)) {
        _faceLmk.value = LmkState.fromPacked(
          positions: positions,
          ranges: ranges,
          zPositions: null,
          lastSeq: nextSeqFace,
          imageSize: imageSize,
        );
        _bumpOverlay();
      }
    } else {
      final cur = _poseLmk.value;
      if (nextSeqPose != cur.lastSeq ||
          !identical(cur.packedPositions, positions) ||
          !identical(cur.packedRanges, ranges) ||
          !identical(cur.packedZPositions, zPositions)) {
        _poseLmk.value = LmkState.fromPacked(
          positions: positions,
          ranges: ranges,
          zPositions: zPositions,
          lastSeq: nextSeqPose,
          imageSize: imageSize,
        );
        _bumpOverlay();
      }
    }

    final bool kf = (msg['keyframe'] as bool?) ?? false;
    final String kindStr = (msg['kind'] as String? ?? 'PD').toString().toUpperCase();
    final String emitKind = (kindStr == 'PO') ? 'PO' : (kf ? 'PD(KF)' : 'PD');

    final frame = PoseFrame.packed(
      imageSize,
      positions,
      ranges,
      zPositions: zPositions,
    );
    _emitBinaryThrottled(frame, kind: emitKind, seq: seq, task: t);

    if ((msg['requestKF'] as bool?) == true) _maybeSendKF();
  }

  void _onParseResultFromIsolate(dynamic msg) {
    if (_disposed || msg is! Map) return;

    final String? task = (msg['task'] as String?)?.toLowerCase();
    final String? type = msg['type'] as String?;

    if (task != null) {
      _parsingTasks.remove(task);
      if (_pendingBin.containsKey(task)) {
        scheduleMicrotask(() => _drainParseLoop(task));
      }
    }

    final int? ackSeq = msg['ackSeq'] as int?;
    if (ackSeq != null) _sendCtrlAck(ackSeq);

    if (type == 'result' || type == 'ok2d') {
      _handleParsed2D(msg, fallbackTask: task);
      return;
    }

    _maybeSendKF();
  }

  void _wireResults(RTCDataChannel ch, {required String task}) {
    ch.onDataChannelState = (s) {};
    ch.onMessage = (RTCDataChannelMessage m) {
      if (!m.isBinary) return;
      _enqueueBinary(task, m.binary);
    };
  }

  void _wireCtrl(RTCDataChannel ch) {
    ch.onDataChannelState = (s) {
      if (s == RTCDataChannelState.RTCDataChannelOpen) {
        _nudgeServer();
      }
    };
    ch.onMessage = (RTCDataChannelMessage m) {
      // ignore (no logs)
    };
  }

  void _nudgeServer() {
    _ctrl.sendText('HELLO');
    _ctrl.sendText('KF');
  }

  Future<void> _recreateNegotiatedChannels() async {
    final pc = _pc;
    if (pc == null) return;
    if (_dc.isOpen || _ctrl.isOpen) return;

    await _dc.safeClose();
    await _ctrl.safeClose();
    _dc = null;
    _ctrl = null;

    await _ensureCtrlDC();
    final tasks = requestedTasks.isEmpty ? const ['pose'] : requestedTasks;
    for (final t in tasks.map((e) => e.toLowerCase().trim()).where((e) => e.isNotEmpty)) {
      await _createLossyDC(t);
    }
  }


  void _enqueueBinary(String task, Uint8List buf) {
    _pendingBin[task] = buf;
    if (_parsingTasks.contains(task)) return;
    _parsingTasks.add(task);
    scheduleMicrotask(() => _drainParseLoop(task));
  }

  void _drainParseLoop(String task) {
    final Uint8List? buf = _pendingBin.remove(task);
    if (buf == null || _disposed) {
      _parsingTasks.remove(task);
      return;
    }

    try {
      final ttd = TransferableTypedData.fromList([buf]);
      _parseSendPort?.send({
        'type': 'job',
        'task': task,
        'data': ttd,
      });
      return;
    } catch (_) {
      _maybeSendKF();
      _parsingTasks.remove(task);
    }
  }

  void _maybeSendKF() {
    final now = DateTime.now();
    if (now.millisecondsSinceEpoch - _lastKfReq.millisecondsSinceEpoch >= kfMinGapMs) {
      _lastKfReq = now;
      _sendCtrlKF();
    }
  }

  void _emitBinaryThrottled(
    PoseFrame frame, {
    required String kind,
    int? seq,
    required String task,
  }) {
    if (_disposed) return;

    final now = DateTime.now();
    final last = _lastEmitByTask[task] ?? DateTime.fromMillisecondsSinceEpoch(0);
    final elapsed = now.difference(last).inMilliseconds;
    final minInterval = _minEmitIntervalMsFor(task);

    if (_emitGateByTask[task] == null && elapsed >= minInterval) {
      _lastEmitByTask[task] = now;
      _doEmit(frame, kind: kind, seq: seq, task: task);
      return;
    }

    final waitMs = (minInterval - elapsed).clamp(0, 1000);
    _pendingByTask[task] = _PendingEmit(frame, kind, seq);

    _emitGateByTask[task] ??= Timer(Duration(milliseconds: waitMs), () {
      _emitGateByTask[task] = null;
      final p = _pendingByTask[task];
      _pendingByTask[task] = null;
      if (p != null && !_disposed) {
        _lastEmitByTask[task] = DateTime.now();
        _doEmit(p.frame, kind: p.kind, seq: p.seq, task: task);
      }
    });
  }

  void _doEmit(PoseFrame frame, {required String kind, int? seq, required String task}) {
    _latestFrame.value = frame;
    if (_framesCtrl.hasListener && !_framesCtrl.isClosed) {
      _framesCtrl.add(frame);
    }
  }

  List<List<Offset>>? _stateToOffsets(LmkState state) {
    final cached = state.last;
    if (cached != null) return cached;

    final packedPositions = state.packedPositions;
    final packedRanges = state.packedRanges;
    if (packedPositions != null && packedRanges != null && packedRanges.isNotEmpty) {
      final people = packedRanges.length >> 1;
      return List<List<Offset>>.generate(people, (person) {
        final int startPt = packedRanges[person << 1];
        final int countPt = packedRanges[(person << 1) + 1];
        final int startF = startPt << 1;
        return List<Offset>.generate(countPt, (i) {
          final int idx = startF + (i << 1);
          return Offset(packedPositions[idx], packedPositions[idx + 1]);
        }, growable: false);
      }, growable: false);
    }

    final flats = state.lastFlat;
    if (flats != null) {
      return flats
          .map((f) => List<Offset>.generate(
                f.length >> 1,
                (i) => Offset(f[i << 1], f[(i << 1) + 1]),
                growable: false,
              ))
          .toList(growable: false);
    }

    return null;
  }

  List<PosePoint>? _stateToPosePoints(LmkState state) {
    final packedPositions = state.packedPositions;
    final packedRanges = state.packedRanges;
    if (packedPositions != null && packedRanges != null && packedRanges.length >= 2) {
      final int startPt = packedRanges[0];
      final int countPt = packedRanges[1];
      final int startF = startPt << 1;
      final packedZ = state.packedZPositions;
      final fallbackFlatZ = state.lastFlatZ;
      final List<PosePoint> out = List<PosePoint>.generate(countPt, (i) {
        final int idx = startF + (i << 1);
        double? z;
        if (packedZ != null) {
          final int zi = startPt + i;
          if (zi < packedZ.length) z = packedZ[zi];
        } else if (fallbackFlatZ != null && fallbackFlatZ.isNotEmpty) {
          final firstZ = fallbackFlatZ.first;
          if (i < firstZ.length) z = firstZ[i];
        }
        return PosePoint(
          x: packedPositions[idx],
          y: packedPositions[idx + 1],
          z: z,
        );
      }, growable: false);

      if (out.isNotEmpty) {
        return out;
      }
    }

    final flats = state.lastFlat;
    if (flats != null && flats.isNotEmpty) {
      final first = flats.first;
      final zFlat = state.lastFlatZ;
      return List<PosePoint>.generate(first.length >> 1, (i) {
        double? z;
        if (zFlat != null && zFlat.isNotEmpty && i < zFlat.first.length) {
          z = zFlat.first[i];
        }
        return PosePoint(
          x: first[i << 1],
          y: first[(i << 1) + 1],
          z: z,
        );
      }, growable: false);
    }

    final legacy = state.last;
    if (legacy != null && legacy.isNotEmpty) {
      final first = legacy.first;
      return first
          .map((o) => PosePoint(x: o.dx, y: o.dy))
          .toList(growable: false);
    }

    return null;
  }

  void _sendCtrlKF() => _ctrl.sendText('KF');

  void _sendCtrlAck(int seq) {
    _ackBuf[3] = (seq & 0xFF);
    _ackBuf[4] = ((seq >> 8) & 0xFF);
    _ctrl.sendBin(_ackBuf);
  }

  void _startRtpStatsProbe() {
    _rtpStatsTimer?.cancel();
  }

  void _startNoResultsGuard() {
    _dcGuardTimer?.cancel();
    if (negotiatedFallbackAfterSeconds <= 0) return;

    _dcGuardTimer = Timer(
      Duration(seconds: negotiatedFallbackAfterSeconds),
      () async {
        if (_disposed) return;
        if (_latestFrame.value != null) return;

        final dcOpen = _dc.isOpen;
        final ctrlOpen = _ctrl.isOpen;

        if (dcOpen || ctrlOpen) {
          _nudgeServer();
          return;
        }

        await _recreateNegotiatedChannels();
      },
    );
  }
}