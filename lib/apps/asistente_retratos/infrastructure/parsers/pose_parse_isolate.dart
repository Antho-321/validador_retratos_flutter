// lib/apps/asistente_retratos/infrastructure/parsers/pose_parse_isolate.dart
//
// Isolate de parseo: recibe binarios por SendPort, parsea con PoseBinaryParser
// (vía parseFlat2D) y devuelve un DTO plano con metadatos + listas Float32List.
//
// ENTRADA: [0, taskId:int, TransferableTypedData]
// SALIDA OK:
//   [1, taskId, w, h, seqOr-1, ackSeqOr-1, requestKF?1:0, keyframe?1:0,
//    kindCode (0=PO,1=PD), hasZ?1:0, positions:Float32List, ranges:Int32List,
//    zPositions?:Float32List]
// SALIDA NEED_KF: [2, taskId]
// SALIDA ERROR:  [3, taskId]

import 'dart:isolate';
import 'dart:typed_data';

import 'pose_binary_parser.dart';

void poseParseIsolateEntry(SendPort mainSendPort) {
  final recv = ReceivePort();
  mainSendPort.send(recv.sendPort);

  const int msgJob = 0;
  const int msgResult = 1;
  const int msgNeedKf = 2;
  const int msgError = 3;
  const int msgShutdown = 4;

  final parsers = <int, PoseBinaryParser>{};

  recv.listen((dynamic message) {
    if (message is! List || message.isEmpty) return;
    final int type = message[0] as int;
    if (type == msgJob) {
      _handleJob(message, mainSendPort, parsers,
          msgResult: msgResult, msgNeedKf: msgNeedKf, msgError: msgError);
    } else if (type == msgShutdown) {
      recv.close();
    }
  });
}

void _handleJob(
  List<dynamic> msg,
  SendPort reply,
  Map<int, PoseBinaryParser> parsers, {
  required int msgResult,
  required int msgNeedKf,
  required int msgError,
}) {
  try {
    if (msg.length < 3) return;
    final int taskId = msg[1] as int? ?? 0;
    final TransferableTypedData ttd = msg[2] as TransferableTypedData;

    final Uint8List buf = ttd.materialize().asUint8List();
    final parser = parsers.putIfAbsent(taskId, () => PoseBinaryParser());

    final res = parser.parseIntoFlat2D(buf);

    if (res is PoseParseOkPacked) {
      reply.send([
        msgResult,
        taskId,
        res.w,
        res.h,
        res.seq ?? -1,
        res.ackSeq ?? -1,
        res.requestKeyframe ? 1 : 0,
        res.keyframe ? 1 : 0,
        res.kind == PacketKind.po ? 0 : 1,
        res.hasZ ? 1 : 0,
        res.positions,
        res.ranges,
        if (res.hasZ && res.zPositions != null) res.zPositions!,
      ]);
      return;
    }

    if (res is PoseParseNeedKF) {
      reply.send([msgNeedKf, taskId]);
      return;
    }

    reply.send([msgError, taskId]);
  } catch (e) {
    reply.send([msgError, msg.length > 1 ? (msg[1] as int? ?? 0) : 0]);
  }
}
