// lib/apps/asistente_retratos/infrastructure/parsers/pose_parse_isolate.dart
//
// Isolate de parseo: recibe binarios por SendPort, parsea con PoseBinaryParser
// y devuelve un DTO plano con metadatos + listas Float32List.
//
// ENTRADA:
//   { "type":"job", "task":String, "data":TransferableTypedData, "ackHint":int? }
//
// SALIDA OK:
//   {
//     "type": "result",
//     "status": "ok",
//     "task": String,
//     "w": int,
//     "h": int,
//     "seq": int?,
//     "ackSeq": int?,
//     "requestKF": bool,
//     "keyframe": bool,
//     "kind": "PO" | "PD",
//     "positions": Float32List,             // [x0,y0,x1,y1,...] packed por frame
//     "ranges": Int32List,                  // [startPts,countPts,...] por persona
//     "hasZ": bool,
//     "zPositions": Float32List?            // [z0,z1,...] packed o null si !hasZ
//   }
//
// SALIDA NEED_KF/ERROR: igual a antes.

import 'dart:isolate';
import 'dart:typed_data';

import 'pose_binary_parser.dart';

void poseParseIsolateEntry(SendPort mainSendPort) {
  final recv = ReceivePort();
  mainSendPort.send(recv.sendPort);

  final parsers = <String, PoseBinaryParser>{};

  recv.listen((dynamic message) {
    if (message is Map) {
      final String? type = message['type'] as String?;
      if (type == 'job') {
        _handleJob(message, mainSendPort, parsers);
      } else if (type == 'shutdown') {
        recv.close();
      }
    }
  });
}

void _handleJob(
  Map msg,
  SendPort reply,
  Map<String, PoseBinaryParser> parsers,
) {
  try {
    final String task = (msg['task'] as String?) ?? 'pose';
    final TransferableTypedData ttd = msg['data'] as TransferableTypedData;

    final Uint8List buf = ttd.materialize().asUint8List();
    final parser = parsers.putIfAbsent(task, () => PoseBinaryParser());

    final res = parser.parse(buf);

    if (res is PoseParseOkPacked) {
      reply.send(<String, dynamic>{
        'type': 'result',
        'status': 'ok',
        'task': task,
        'w': res.w,
        'h': res.h,
        'seq': res.seq,
        'ackSeq': res.ackSeq,
        'requestKF': res.requestKeyframe,
        'keyframe': res.keyframe,
        'kind': res.kind == PacketKind.po ? 'PO' : 'PD',
        'positions': res.positions,
        'ranges': res.ranges,
        'hasZ': res.hasZ,
        if (res.zPositions != null) 'zPositions': res.zPositions,
      });
      return;
    }

    if (res is PoseParseNeedKF) {
      reply.send(<String, dynamic>{
        'type': 'result',
        'status': 'need_kf',
        'task': (msg['task'] as String?) ?? 'pose',
        'error': res.reason,
      });
      return;
    }

    reply.send(<String, dynamic>{
      'type': 'result',
      'status': 'err',
      'task': (msg['task'] as String?) ?? 'pose',
      'error': 'Unknown parse result type',
    });
  } catch (e) {
    reply.send(<String, dynamic>{
      'type': 'result',
      'status': 'err',
      'task': (msg['task'] as String?) ?? 'pose',
      'error': e.toString(),
    });
  }
}
