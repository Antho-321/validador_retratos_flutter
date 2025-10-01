// lib/apps/asistente_retratos/infrastructure/services/pose_webrtc_service_imp.dart

import 'dart:async';
import 'dart:convert' show jsonDecode, jsonEncode, utf8;
import 'dart:typed_data';
import 'dart:ui' show Offset, Size;
import 'dart:isolate';

import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:flutter/foundation.dart'
    show ValueListenable, ValueNotifier, debugPrint;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;

import '../../domain/service/pose_capture_service.dart';
import '../../domain/model/lmk_state.dart';
import '../../domain/model/face_recog_result.dart';
import '../model/pose_frame.dart' show PoseFrame;
import '../webrtc/rtc_video_encoder.dart';
import '../webrtc/sdp_utils.dart';
import '../model/pose_point.dart';
import 'package:hashlib/hashlib.dart';
import '../parsers/pose_parse_isolate.dart' show poseParseIsolateEntry;
import '../parsers/pose_binary_parser.dart';
import '../parsers/pose_json_parser.dart';
import '../parsers/pose_utils.dart';

class _PendingEmit {
  final PoseFrame frame;
  final String kind;
  final int? seq;

  const _PendingEmit(this.frame, this.kind, this.seq);
}

class _ParseWorker {
  _ParseWorker(this.task, this._onMessage)
      : _receivePort = ReceivePort(),
        _readyCompleter = Completer<void>() {
    _subscription = _receivePort.listen((dynamic msg) {
      if (msg is SendPort) {
        sendPort = msg;
        if (!_readyCompleter.isCompleted) {
          _readyCompleter.complete();
        }
        return;
      }
      _onMessage(task, msg);
    });
  }

  final String task;
  final void Function(String task, dynamic message) _onMessage;
  final ReceivePort _receivePort;
  late final StreamSubscription<dynamic> _subscription;
  final Completer<void> _readyCompleter;

  Isolate? isolate;
  SendPort? sendPort;
  bool busy = false;

  Future<void> start() async {
    isolate = await Isolate.spawn(
      poseParseIsolateEntry,
      _receivePort.sendPort,
    );
  }

  Future<void> get ready => _readyCompleter.future;

  Future<void> dispose() async {
    await _subscription.cancel();
    _receivePort.close();
    isolate?.kill(priority: Isolate.immediate);
    isolate = null;
    if (!_readyCompleter.isCompleted) {
      _readyCompleter.complete();
    }
  }
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

final Stopwatch _monoClock = Stopwatch()..start();
int _nowUs() => _monoClock.elapsedMicroseconds;

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
    Map<String, Map<String, dynamic>>? initialTaskParams,
    RtcVideoEncoder? encoder,
    Set<String>? jsonTasks,
  })  : _stunUrl = stunUrl ?? 'stun:stun.l.google.com:19302',
        _turnUrl = turnUrl,
        _turnUsername = turnUsername,
        _turnPassword = turnPassword,
        _encoder = encoder ??
            RtcVideoEncoder(
              idealFps: idealFps,
              maxBitrateKbps: maxBitrateKbps,
              preferHevc: preferHevc,
            ),
        taskParams = {
          for (final entry
              in (initialTaskParams ?? const <String, Map<String, dynamic>>{}).entries)
            if (entry.key.trim().isNotEmpty)
              entry.key.trim().toLowerCase(): Map<String, dynamic>.from(entry.value),
        },
        _jsonTasks = {
          for (final raw in (jsonTasks ?? const <String>{}))
            if (raw.trim().isNotEmpty) raw.toLowerCase().trim(),
        } {
    final fps = idealFps <= 0 ? 1 : idealFps;
    final gapMs = (1000 ~/ fps).clamp(1, 1000);
    _minOverlayGapUs = gapMs * 1000;
    _jsonParser = PoseJsonParser(
      warn: _warn,
      updateLmkStateFromFlat: _updateLmkStateFromFlat,
      deliverTaskJsonEvent: _deliverTaskJsonEvent,
    );
  }

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
  final Map<String, Map<String, dynamic>> taskParams;
  final int kfMinGapMs;
  final Set<String> _jsonTasks;
  late final PoseJsonParser _jsonParser;

  void _log(String message) {
    if (!logEverything) return;
    debugPrint('[PoseWebRTC] $message');
  }

  void _warn(String message) {
    debugPrint('[PoseWebRTC][WARN] $message');
  }

  String get _primaryTask =>
      (requestedTasks.isNotEmpty ? requestedTasks.first : 'pose').toLowerCase();

  final String? _stunUrl;
  final String? _turnUrl;
  final String? _turnUsername;
  final String? _turnPassword;

  final RtcVideoEncoder _encoder;

  String _normalizeTask(String task) {
    final normalized = task.toLowerCase().trim();
    if (normalized.isEmpty) return _primaryTask;
    return normalized;
  }

  Future<_ParseWorker> _ensureWorker(String task) {
    final normalized = _normalizeTask(task);
    final existing = _parseWorkers[normalized];
    if (existing != null && existing.sendPort != null) {
      return Future.value(existing);
    }

    final pending = _workerFutures[normalized];
    if (pending != null) {
      return pending;
    }

    final worker = _ParseWorker(normalized, _handleWorkerMessage);
    _parseWorkers[normalized] = worker;

    final future = () async {
      await worker.start();
      await worker.ready;
      return worker;
    }();

    _workerFutures[normalized] = future;
    future.catchError((_) {}).whenComplete(() {
      _workerFutures.remove(normalized);
    });

    return future;
  }

  Future<void> _ensureWorkersForRequestedTasks() async {
    final requested = requestedTasks.isEmpty ? const ['pose'] : requestedTasks;
    final futures = <Future<_ParseWorker>>[];
    for (final raw in requested) {
      final normalized = _normalizeTask(raw);
      if (normalized.isEmpty || _jsonTasks.contains(normalized)) continue;
      futures.add(_ensureWorker(normalized));
    }
    if (futures.isEmpty) {
      final fallback = _normalizeTask(_primaryTask);
      if (!_jsonTasks.contains(fallback)) {
        futures.add(_ensureWorker(fallback));
      }
    }
    if (futures.isEmpty) return;
    await Future.wait(futures);
  }

  void _handleWorkerMessage(String task, dynamic message) {
    if (message is Map && ((message['task'] as String?)?.isEmpty ?? true)) {
      message['task'] = task;
    }
    _onParseResultFromIsolate(message);
  }

  RTCPeerConnection? _pc;

  RTCDataChannel? _dc;
  RTCDataChannel? _ctrl;
  final Map<String, RTCDataChannel> _resultsPerTask = {};
  final Map<String, _PendingEmit> _pendingByTask = {};
  final Set<String> _emitScheduled = {};
  final Map<String, int> _lastEmitUsByTask = {};

  int _minEmitIntervalMsFor(String task) => (1000 ~/ idealFps).clamp(8, 1000);

  // ===== Pre-parse drop helpers ===============================================
  bool _tooSoonForParse(String task) {
    final lastUs = _lastEmitUsByTask[task];
    if (lastUs == null) return false;
    final nowUs = _nowUs();
    final minGapUs = _minEmitIntervalMsFor(task) * 1000;
    final deltaUs = nowUs - lastUs;
    final tooSoon = deltaUs < minGapUs;
    if (tooSoon) {
      _log(
          'Throttle parse for "$task": Δ${(deltaUs / 1000).toStringAsFixed(2)}ms < ${(minGapUs / 1000).toStringAsFixed(2)}ms');
    }
    return tooSoon;
  }

  MediaStream? _localStream;
  @override
  MediaStream? get localStream => _localStream;

  RTCRtpTransceiver? _videoTransceiver;

  Timer? _rtpStatsTimer;
  Timer? _dcGuardTimer;
  bool _disposed = false;

  final Map<String, _ParseWorker> _parseWorkers = {};
  final Map<String, Future<_ParseWorker>> _workerFutures = {};

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

  final _jsonEventsCtrl =
      StreamController<Map<String, dynamic>>.broadcast(sync: true);
  Stream<Map<String, dynamic>> get jsonEvents => _jsonEventsCtrl.stream;

  final ValueNotifier<LmkState> _faceLmk = ValueNotifier<LmkState>(LmkState());
  @override
  ValueListenable<LmkState> get faceLandmarks => _faceLmk;
  List<List<Offset>>? _lastFace2D;
  List<Float32List>? _lastFaceFlat;

  final ValueNotifier<FaceRecogResult?> _faceRecogResult =
      ValueNotifier<FaceRecogResult?>(null);
  ValueListenable<FaceRecogResult?> get faceRecogResult => _faceRecogResult;

  final ValueNotifier<LmkState> _poseLmk = ValueNotifier<LmkState>(LmkState());
  @override
  ValueListenable<LmkState> get poseLandmarks => _poseLmk;
  ValueListenable<LmkState> get poseLmk => _poseLmk;
  ValueListenable<LmkState> get faceLmk => _faceLmk;

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

  final Map<String, Uint8List?> _pendingBin = {};
  int _lastAckSeqSent = -1;
  int _lastKfReqUs = 0;
  final Uint8List _ackBuf = Uint8List(5)..setAll(0, [0x41, 0x43, 0x4B, 0, 0]);

  String _forceTurnUdp(String url) => url.contains('?') ? url : '$url?transport=udp';

  // ====== Overlay repaint coalescing =========================================
  final ValueNotifier<int> overlayTick = ValueNotifier<int>(0);
  bool _overlayScheduled = false;
  late final int _minOverlayGapUs;
  int _lastTickUs = 0;

  void _bumpOverlay() {
    if (_overlayScheduled) return;
    final nowUs = _nowUs();
    if (nowUs - _lastTickUs < _minOverlayGapUs) return;
    _overlayScheduled = true;
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      _overlayScheduled = false;
      _lastTickUs = _nowUs();
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

    final body = <String, dynamic>{
      'type': local!.type,
      'sdp': local.sdp,
      'tasks': requestedTasks.isEmpty ? ['pose'] : requestedTasks,
    };
    if (taskParams.isNotEmpty) {
      final normalizedTaskParams = <String, Map<String, dynamic>>{};
      taskParams.forEach((task, params) {
        final normalizedTask = task.trim().toLowerCase();
        if (normalizedTask.isEmpty || params.isEmpty) return;
        normalizedTaskParams[normalizedTask] = Map<String, dynamic>.from(params);
      });
      if (normalizedTaskParams.isNotEmpty) {
        body['task_params'] = normalizedTaskParams;
      }
    }
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
    await _ensureWorkersForRequestedTasks();
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
    _lastFace2D = null;
    _lastFaceFlat = null;

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
    await _jsonEventsCtrl.close();

    _lastSeqPerTask.clear();
    _lastPosesPerTask.clear();

    final workers = List<_ParseWorker>.from(_parseWorkers.values);
    _parseWorkers.clear();
    _workerFutures.clear();
    for (final worker in workers) {
      await _silenceAsync(() => worker.dispose());
    }

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

  // ==================== Face publish (Lazy Offsets) ===========================
  void _publishFaceLmk(int w, int h, List<Float32List> faces2d, {int? seq}) {
    _lastFaceFlat = faces2d;
    _lastFace2D = null; // evitar construir Offsets por frame
    final current = _faceLmk.value;
    final nextSeq = seq ?? (current.lastSeq + 1);
    if (nextSeq != current.lastSeq || !identical(current.lastFlat, _lastFaceFlat)) {
      _faceLmk.value = LmkState(
        last: null,                 // lazy
        lastFlat: _lastFaceFlat,    // source of truth
        lastFlatZ: null,
        lastSeq: nextSeq,
        lastTs: DateTime.now(),
        imageSize: _szWHCached(w, h),
      );
      _bumpOverlay();
    }
  }
  // ===========================================================================

  void _deliverTaskJsonEvent(String task, Map<String, dynamic> payload) {
    if (_disposed || _jsonEventsCtrl.isClosed) return;
    final normalized = _normalizeTask(task);
    if (normalized == 'face_recog') {
      final rawCos = payload['cos_sim'];
      double? cosSim;
      if (rawCos is num) {
        cosSim = rawCos.toDouble();
      } else if (rawCos is String) {
        cosSim = double.tryParse(rawCos.trim());
      }

      final rawDecision = payload['decision'];
      final decision = rawDecision == null ? null : rawDecision.toString();

      final rawSeq = payload['seq'];
      int seq = 0;
      if (rawSeq is int) {
        seq = rawSeq;
      } else if (rawSeq is num) {
        seq = rawSeq.toInt();
      } else if (rawSeq is String) {
        seq = int.tryParse(rawSeq.trim()) ?? 0;
      }

      _faceRecogResult.value = FaceRecogResult(
        cosSim: cosSim,
        decision: decision,
        seq: seq,
        ts: DateTime.now(),
      );
    }
    _jsonEventsCtrl.add({
      'task': normalized,
      'payload': Map<String, dynamic>.from(payload),
    });
  }

  void _updateLmkStateFromFlat({
    required String task,
    required int seq,
    required int w,
    required int h,
    required Float32List flat,
  }) {
    final normalized = _normalizeTask(task);
    int resolvedW = w;
    int resolvedH = h;
    resolvedW = resolvedW > 0 ? resolvedW : (_lastW ?? _localRenderer.videoWidth);
    resolvedH = resolvedH > 0 ? resolvedH : (_lastH ?? _localRenderer.videoHeight);
    if (resolvedW <= 0 || resolvedH <= 0) {
      _warn('JSON $normalized sin dimensiones válidas (w=$resolvedW, h=$resolvedH)');
      return;
    }

    _lastW = resolvedW;
    _lastH = resolvedH;

    final imageSize = _szWHCached(resolvedW, resolvedH);
    final lastSeq = _lastSeqPerTask[normalized] ?? 0;
    final nextSeq = seq > 0 ? seq : (lastSeq + 1);
    _lastSeqPerTask[normalized] = nextSeq;

    final persons = List<Float32List>.unmodifiable(<Float32List>[flat]);
    _lastPosesPerTask[normalized] = mkPose3D(persons, null);

    if (normalized == 'face') {
      _lastFaceFlat = persons;
      _lastFace2D = null;
      _faceLmk.value = LmkState.fromFlat(
        persons,
        lastSeq: nextSeq,
        imageSize: imageSize,
      );
    } else if (normalized == 'pose') {
      _poseLmk.value = LmkState.fromFlat(
        persons,
        lastSeq: nextSeq,
        imageSize: imageSize,
      );
    }

    final frame = PoseFrame(
      imageSize: imageSize,
      posesPxFlat: persons,
    );
    _emitBinaryThrottled(
      frame,
      kind: 'JSON',
      seq: nextSeq,
      task: normalized,
    );
    _bumpOverlay();
  }

  void _handleParsed2D(Map msg, {String? fallbackTask}) {
    final t = (msg['task'] as String? ?? fallbackTask ?? 'pose').toLowerCase();
    final int w = (msg['w'] as int?) ?? _lastW ?? _localRenderer.videoWidth;
    final int h = (msg['h'] as int?) ?? _lastH ?? _localRenderer.videoHeight;
    if (w == 0 || h == 0) return;

    final int? seq = msg['seq'] as int?;
    final bool kf = (msg['keyframe'] as bool?) ?? false;
    final String kindStr = (msg['kind'] as String? ?? 'PD').toString().toUpperCase();
    final String emitKind = (kindStr == 'PO') ? 'PO' : (kf ? 'PD(KF)' : 'PD');

    _lastW = w; _lastH = h;
    if (seq != null) {
      final last = _lastSeqPerTask[t];
      if (last != null && !_isNewer16(seq, last)) return; // drop stale PDs
      _lastSeqPerTask[t] = seq;
    }

    final Float32List? positions = msg['positions'] as Float32List?;
    final Int32List? ranges = msg['ranges'] as Int32List?;
    final bool hasZ = (msg['hasZ'] as bool?) ?? false;
    final Float32List? zPositions = hasZ ? msg['zPositions'] as Float32List? : null;

    if (positions != null && ranges != null) {
      final imageSize = _szWHCached(w, h);
      _lastPosesPerTask[t] = mkPose3DFromPacked(positions, ranges, zPositions);

      if (t == 'face') {
        final current = _faceLmk.value;
        final nextSeq = seq ?? (current.lastSeq + 1);
        if (nextSeq != current.lastSeq ||
            !identical(current.packedPositions, positions) ||
            !identical(current.packedRanges, ranges)) {
          _lastFaceFlat = null;
          _lastFace2D = null;
          _faceLmk.value = LmkState.fromPacked(
            positions: positions,
            ranges: ranges,
            zPositions: null,
            lastSeq: nextSeq,
            imageSize: imageSize,
          );
          _bumpOverlay();
        }
      } else if (t == 'pose') {
        final current = _poseLmk.value;
        final nextSeq = seq ?? (current.lastSeq + 1);
        if (nextSeq != current.lastSeq ||
            !identical(current.packedPositions, positions) ||
            !identical(current.packedRanges, ranges) ||
            !identical(current.packedZPositions, zPositions)) {
          _poseLmk.value = LmkState.fromPacked(
            positions: positions,
            ranges: ranges,
            zPositions: zPositions,
            lastSeq: nextSeq,
            imageSize: imageSize,
          );
          _bumpOverlay();
        }
      }

      final frame = PoseFrame.packed(
        imageSize,
        positions,
        ranges,
        zPositions: zPositions,
      );
      _emitBinaryThrottled(frame, kind: emitKind, seq: seq, task: t);
      if ((msg['requestKF'] as bool?) == true) _maybeSendKF();
      return;
    }

    // legacy path from isolate
    final List<Float32List> poses2d =
        (msg['poses'] as List?)?.cast<Float32List>() ??
        (msg['poses2d'] as List?)?.cast<Float32List>() ??
        const <Float32List>[];
    if (t == 'face') {
      _publishFaceLmk(w, h, poses2d, seq: seq);
      _lastPosesPerTask[t] = mkPose3D(poses2d, null);
    } else {
      final posesZ = hasZ ? (msg['posesZ'] as List?)?.cast<Float32List>() : null;
      _lastPosesPerTask[t] = mkPose3D(poses2d, posesZ);
    }

    if ((msg['requestKF'] as bool?) == true) _maybeSendKF();

    final frame = PoseFrame(imageSize: _szWHCached(w, h), posesPxFlat: poses2d);
    _emitBinaryThrottled(frame, kind: emitKind, seq: seq, task: t);
  }

  void _onParseResultFromIsolate(dynamic msg) {
    if (_disposed || msg is! Map) return;

    final String? rawTask = (msg['task'] as String?)?.toLowerCase();
    final String? type = msg['type'] as String?;
    final String? task = rawTask == null ? null : _normalizeTask(rawTask);

    if (task != null) {
      msg['task'] = task;
      final worker = _parseWorkers[task];
      if (worker != null) {
        worker.busy = false;
      }
      if (_pendingBin.containsKey(task)) {
        if (_tooSoonForParse(task)) {
          // Try next frame instead of right-now microtask (keeps CPU cooler)
          SchedulerBinding.instance.scheduleFrameCallback((_) {
            if (_disposed) return;
            if (!_pendingBin.containsKey(task)) return;
            final w = _parseWorkers[task];
            if (w == null || w.busy) return;
            scheduleMicrotask(() => _drainParseLoop(task));
          });
        } else {
          scheduleMicrotask(() => _drainParseLoop(task));
        }
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
    final normalized = _normalizeTask(task);
    ch.onDataChannelState = (s) {};
    ch.onMessage = (RTCDataChannelMessage m) {
      if (_jsonTasks.contains(normalized)) {
        if (m.isBinary) {
          final data = m.binary;
          _warn('Binario inesperado en canal JSON "$normalized" (${data.length}B)');
          final decoded = _silence(() => utf8.decode(data));
          if (decoded != null && decoded.trim().isNotEmpty) {
            _jsonParser.handle(normalized, decoded);
          } else if (data.isNotEmpty) {
            _enqueueBinary(normalized, data);
          }
          return;
        }
        final text = m.text;
        if (text == null || text.trim().isEmpty) {
          _warn('Texto vacío recibido en canal JSON "$normalized"');
          return;
        }
        _jsonParser.handle(normalized, text);
        return;
      }

      if (!m.isBinary) {
        _warn('Descartando texto inesperado en canal binario "$normalized"');
        return;
      }

      _enqueueBinary(normalized, m.binary);
    };
  }

  void _wireCtrl(RTCDataChannel ch) {
    _lastAckSeqSent = -1;
    _lastKfReqUs = 0;
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
    _sendCtrlKF();
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
    final normalized = _normalizeTask(task);

    // Always replace with the freshest payload
    _pendingBin[normalized] = buf;

    final bool parseRunning = _parseWorkers[normalized]?.busy ?? false;
    if (logEverything) {
      _log(
          'enqueueBinary[$normalized]: buffer=${buf.length}B, parseRunning=$parseRunning, pending=${_pendingBin.length}');
    }

    if (parseRunning) {
      final bool throttled = _tooSoonForParse(normalized);
      if (throttled) {
        _log('enqueueBinary[$normalized]: isolate busy, throttling new payload');
        return; // cheap backpressure: avoid sending another job to the isolate
      }

      _log('enqueueBinary[$normalized]: isolate busy, keeping freshest payload');
      return; // we'll parse the freshest later
    }

    // Normal path: parser isn't running for this task → start it.
    _log('enqueueBinary[$normalized]: dispatching job to parse isolate');
    scheduleMicrotask(() => _drainParseLoop(normalized));
  }

  Future<void> _drainParseLoop(String task) async {
    final normalized = _normalizeTask(task);
    final Uint8List? buf = _pendingBin.remove(normalized);
    if (buf == null || _disposed) {
      return;
    }

    _ParseWorker worker;
    try {
      worker = await _ensureWorker(normalized);
    } catch (_) {
      _maybeSendKF();
      return;
    }

    if (_disposed) {
      return;
    }

    final sendPort = worker.sendPort;
    if (sendPort == null) {
      return;
    }

    try {
      final ttd = TransferableTypedData.fromList([buf]);
      worker.busy = true;
      sendPort.send({
        'type': 'job',
        'task': normalized,
        'data': ttd,
      });
    } catch (_) {
      worker.busy = false;
      _maybeSendKF();
    }
  }

  void _maybeSendKF() => _sendCtrlKF();

  void _emitBinaryThrottled(
    PoseFrame frame, {
    required String kind,
    int? seq,
    required String task,
  }) {
    if (_disposed) return;

    _pendingByTask[task] = _PendingEmit(frame, kind, seq);
    _scheduleEmitFlush(task);
  }

  void _scheduleEmitFlush(String task) {
    if (_emitScheduled.contains(task)) return;
    _emitScheduled.add(task);
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      _emitScheduled.remove(task);
      if (_disposed) return;

      final pending = _pendingByTask[task];
      if (pending == null) return;

      final nowUs = _nowUs();
      final lastUs = _lastEmitUsByTask[task] ?? 0;
      final minIntervalUs = _minEmitIntervalMsFor(task) * 1000;
      final deltaMs = (nowUs - lastUs) / 1000.0;
      final minGapMs = minIntervalUs / 1000.0;

      if (nowUs - lastUs < minIntervalUs) {
        _log(
            'emit[$task]: rescheduling ${pending.kind} seq=${pending.seq ?? '-'}; waited ${deltaMs.toStringAsFixed(2)}ms < ${minGapMs.toStringAsFixed(2)}ms');
        _scheduleEmitFlush(task);
        return;
      }

      _pendingByTask.remove(task);
      _lastEmitUsByTask[task] = nowUs;
      _log(
          'emit[$task]: delivering ${pending.kind} seq=${pending.seq ?? '-'} after ${deltaMs.toStringAsFixed(2)}ms');
      _doEmit(pending.frame,
          kind: pending.kind, seq: pending.seq, task: task);
    });
  }

  // ===== Pose flat reuse ======================================================
  List<Float32List>? _flatPoolPose;
  List<Float32List>? _flatListWrapper;
  static const int _POSE_LANDMARKS = 33;

  void _ensurePoseFlatPool(int persons, int perPoseLen) {
    final neededLen = perPoseLen * 2; // x,y per landmark
    final changed = _flatPoolPose == null ||
        _flatPoolPose!.length != persons ||
        (persons > 0 && _flatPoolPose!.first.length != neededLen);

    if (!changed) {
      if (_flatPoolPose != null && _flatListWrapper == null) {
        _flatListWrapper = List<Float32List>.unmodifiable(_flatPoolPose!);
      }
      return;
    }

    _flatPoolPose = List.generate(
      persons,
      (_) => Float32List(neededLen),
      growable: false,
    );
    _flatListWrapper = List<Float32List>.unmodifiable(_flatPoolPose!);
  }

  void _copyOffsetsToFlat(List<Offset> src, Float32List dst) {
    // assume lengths are matched
    for (int i = 0, j = 0; i < src.length; i++) {
      final p = src[i];
      dst[j++] = p.dx; dst[j++] = p.dy;
    }
  }
  // ===========================================================================

  void _doEmit(PoseFrame frame, {required String kind, int? seq, required String task}) {
    if (frame.packedPositions != null && frame.packedRanges != null) {
      _latestFrame.value = frame;
      if (_framesCtrl.hasListener && !_framesCtrl.isClosed) {
        _framesCtrl.add(frame);
      }
      return;
    }

    List<Float32List>? pxFlat = frame.posesPxFlat;
    final pxLegacy = frame.posesPx;

    if ((pxFlat == null || pxFlat.isEmpty) && pxLegacy != null && pxLegacy.isNotEmpty) {
      final persons = pxLegacy.length;
      final perPoseLen = pxLegacy[0].length; // ej. 33 para MediaPipe Pose
      _ensurePoseFlatPool(persons, perPoseLen);

      final reusedWrapper = _flatListWrapper!;
      List<Float32List>? fallback;

      for (int i = 0; i < persons; i++) {
        final dst = _flatPoolPose![i];
        final src = pxLegacy[i];
        if (src.length * 2 != dst.length) {
          // forma atípica; caer a una copia única
          fallback ??= List<Float32List>.from(reusedWrapper, growable: false);
          final f = Float32List(src.length * 2);
          for (int k = 0, j = 0; k < src.length; k++) {
            final p = src[k];
            f[j++] = p.dx;
            f[j++] = p.dy;
          }
          fallback[i] = f;
          continue;
        }
        _copyOffsetsToFlat(src, dst);
      }

      pxFlat = fallback ?? reusedWrapper;
    }

    _latestFrame.value = frame;

    if (task == 'face') {
      final lf  = _lastFace2D;   // puede ser null por lazy
      final lff = _lastFaceFlat;
      if (lf != null || lff != null) {
        _faceLmk.value = LmkState(
          last: lf,
          lastFlat: lff,
          lastFlatZ: null,
          lastSeq: seq ?? _faceLmk.value.lastSeq,
          lastTs: DateTime.now(),
          imageSize: frame.imageSize,
        );
      }
    }

    if (task == 'pose' && pxFlat != null && pxFlat.isNotEmpty) {
      final current = _poseLmk.value;
      final nextSeq = seq ?? (current.lastSeq + 1);
      if (nextSeq != current.lastSeq || !identical(current.lastFlat, pxFlat)) {
        _poseLmk.value = LmkState.fromFlat(
          pxFlat,
          z: current.lastFlatZ,
          lastSeq: nextSeq,
          imageSize: frame.imageSize,
        );
        _bumpOverlay();
      }
    }

    if (_framesCtrl.hasListener && !_framesCtrl.isClosed) {
      _framesCtrl.add(frame);
    }
  }

  void _handleTaskBinary(String task, Uint8List b) {
    final parser = _parsers.putIfAbsent(task, () => PoseBinaryParser());
    final currentLmk = _poseLmk.value;
    final res = parser.parseIntoFlat2D(
      b,
      reusePositions: currentLmk.packedPositions,
      reuseRanges: currentLmk.packedRanges,
      reuseZ: currentLmk.packedZPositions,
    );

    if (res is PoseParseOkPacked) {
      final int? seq = res.seq;

      if (res.kind == PacketKind.pd && !res.keyframe && seq != null) {
        final int? last = _lastSeqPerTask[task];
        if (last != null && !_isNewer16(seq, last)) {
          if (task == _primaryTask && res.ackSeq != null) {
            _sendCtrlAck(res.ackSeq!);
          }
          return;
        }
      }

      final msg = <String, dynamic>{
        'type': 'ok2d',
        'task': task,
        'w': res.w,
        'h': res.h,
        'seq': seq,
        'ackSeq': res.ackSeq,
        'requestKF': res.requestKeyframe,
        'keyframe': res.keyframe,
        'kind': res.kind == PacketKind.po ? 'PO' : 'PD',
        'positions': res.positions,
        'ranges': res.ranges,
        'hasZ': res.hasZ,
      };
      if (res.zPositions != null) {
        msg['zPositions'] = res.zPositions;
      }

      _handleParsed2D(msg, fallbackTask: task);

      if (task == _primaryTask && res.ackSeq != null) {
        _sendCtrlAck(res.ackSeq!);
      }
    } else if (res is PoseParseNeedKF) {
      _sendCtrlKF();
    }
  }

  void _sendCtrlKF() {
    final nowUs = _nowUs();
    if (nowUs - _lastKfReqUs < kfMinGapMs * 1000) {
      return;
    }
    _lastKfReqUs = nowUs;
    _ctrl.sendText('KF');
  }

  void _sendCtrlAck(int seq) {
    if (seq == _lastAckSeqSent) return;
    _lastAckSeqSent = seq;
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