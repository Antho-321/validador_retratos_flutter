// lib/apps/asistente_retratos/infrastructure/parsers/pose_parse_isolate.dart
//
// Isolate de parseo: recibe binarios por SendPort, parsea con PoseBinaryParser
// (vía parseFlat2D) y devuelve un DTO plano con metadatos + listas Float32List.
//
// Mensajes de ENTRADA (al isolate):
//   {
//     "type": "job",
//     "task": String,                        // p.ej. "pose" | "face"
//     "data": TransferableTypedData,        // binario recibido del DC
//     "ackHint": int?                       // opcional, por si quieres eco
//   }
//
// Mensajes de SALIDA (del isolate al main):
//   OK:
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
//     "poses": List<Float32List>,           // [x0,y0,x1,y1,...] por persona
//   }
//
//   NEED_KF / ERROR:
//   {
//     "type": "result",
//     "status": "need_kf" | "err",
//     "task": String,
//     "error": String?,                     // set si status == "err"
//   }
//
// Handshake inicial: el entrypoint envía su SendPort de recepción a main.

import 'dart:isolate';
import 'dart:typed_data';

import 'pose_binary_parser.dart';

/// Entry point del isolate. Debe usarse con:
///   final rx = ReceivePort();
///   final iso = await Isolate.spawn(poseParseIsolateEntry, rx.sendPort);
///   final SendPort isoSend = await rx.first; // handshake
///   // Luego: isoSend.send({... "type":"job", ...});
void poseParseIsolateEntry(SendPort mainSendPort) {
  final recv = ReceivePort();

  // Handshake: enviamos nuestro SendPort de recepción al main isolate.
  mainSendPort.send(recv.sendPort);

  // Un parser por "task" para reusar estado interno (si aplica).
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
    final TransferableTypedData ttd =
        msg['data'] as TransferableTypedData; // obligatorio

    // Materializar el binario en este isolate (cero copias desde main)
    final Uint8List buf = ttd.materialize().asUint8List();

    // Reutiliza un parser por task
    final parser = parsers.putIfAbsent(task, () => PoseBinaryParser());

    // Ruta rápida (flat 2D)
    final res = parser.parseFlat2D(buf);

    if (res is PoseParseOk2D) {
      final pkt = res.packet;

      reply.send(<String, dynamic>{
        'type': 'result',
        'status': 'ok',
        'task': task,
        'w': pkt.w,
        'h': pkt.h,
        'seq': pkt.seq,
        'ackSeq': res.ackSeq,
        'requestKF': res.requestKeyframe,
        'keyframe': pkt.keyframe,
        'kind': pkt.kind == PacketKind.po ? 'PO' : 'PD',
        'poses': pkt.poses2d, // List<Float32List>
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

    // Cualquier otro caso
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
