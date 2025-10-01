// lib/apps/asistente_retratos/infrastructure/parsers/pose_json_parser.dart

import 'dart:convert';
import 'dart:typed_data';

typedef WarnCallback = void Function(String message);
typedef UpdateLmkStateFromFlat = void Function({
  required String task,
  required int seq,
  required int w,
  required int h,
  required Float32List flat,
});
typedef DeliverTaskJsonEvent = void Function(
  String task,
  Map<String, dynamic> payload,
);

class PoseJsonParser {
  PoseJsonParser({
    required this.warn,
    required this.updateLmkStateFromFlat,
    required this.deliverTaskJsonEvent,
  });

  final WarnCallback warn;
  final UpdateLmkStateFromFlat updateLmkStateFromFlat;
  final DeliverTaskJsonEvent deliverTaskJsonEvent;

  void handle(String task, dynamic objOrText) {
    dynamic obj = objOrText;
    if (objOrText is String) {
      final st = objOrText.trim();
      if (st.isEmpty) {
        warn('JSON $task vacío tras trim');
        return;
      }
      if (st.contains('\n')) {
        dynamic lastOk;
        for (final line in st.split('\n')) {
          final ln = line.trim();
          if (ln.startsWith('{') || ln.startsWith('[')) {
            try {
              lastOk = jsonDecode(ln);
            } catch (_) {}
          }
        }
        if (lastOk != null) {
          obj = lastOk;
        } else {
          warn('JSON $task NDJSON sin objetos válidos');
          return;
        }
      } else if (st.startsWith('{') || st.startsWith('[')) {
        try {
          obj = jsonDecode(st);
        } catch (err) {
          warn('JSON $task inválido: $err');
          return;
        }
      } else {
        warn('JSON $task ignorado (no es objeto JSON)');
        return;
      }
    }

    if (obj is! Map) {
      warn('JSON $task no es objeto Map tras normalizar');
      return;
    }

    final map = obj as Map;

    List<double>? embedding;
    final emb = map['embedding'] ?? map['emb'];
    if (emb is List) {
      final tmp = <double>[];
      for (final v in emb) {
        final d = _toDouble(v);
        if (d == null) {
          tmp.clear();
          break;
        }
        tmp.add(d);
      }
      if (tmp.isNotEmpty) embedding = tmp;
    }

    List<List<double>> kpts = const [];
    final rawK = map['kpts5'] ?? map['kp'] ?? map['kps'] ?? map['landmarks'];
    if (rawK is List) {
      final out = <List<double>>[];
      for (final it in rawK) {
        if (it is List && it.length >= 2) {
          final x = _toDouble(it[0]);
          final y = _toDouble(it[1]);
          if (x != null && y != null) {
            out.add([x, y]);
          }
        }
      }
      if (out.isNotEmpty) kpts = out;
    }

    int w = 0, h = 0;
    if (map['image_size'] is Map) {
      final im = map['image_size'] as Map;
      w = _toInt(im['w']);
      h = _toInt(im['h']);
    } else {
      w = _toInt(map['w']);
      h = _toInt(map['h']);
    }

    final double? cosSim = _toDouble(map['cos_sim']);
    final String? decision = (map['decision'] ?? map['verdict'])?.toString();
    final int seq = _toInt(map['seq']);

    if (kpts.isNotEmpty) {
      final flat = Float32List(kpts.length * 2);
      for (var i = 0; i < kpts.length; i++) {
        flat[i << 1] = kpts[i][0].toDouble();
        flat[(i << 1) + 1] = kpts[i][1].toDouble();
      }
      updateLmkStateFromFlat(
        task: task,
        seq: seq,
        w: w,
        h: h,
        flat: flat,
      );
      return;
    }

    if (embedding != null && embedding.isNotEmpty) {
      deliverTaskJsonEvent(task, {
        'embedding': embedding,
        'cos_sim': cosSim,
        'decision': decision,
        'seq': seq,
      });
      return;
    }

    if (cosSim != null || (decision != null && decision.isNotEmpty)) {
      final payload = <String, dynamic>{'seq': seq};
      if (cosSim != null) payload['cos_sim'] = cosSim;
      if (decision != null && decision.isNotEmpty) {
        payload['decision'] = decision;
      }
      deliverTaskJsonEvent(task, payload);
      return;
    }

    warn('JSON $task normalizado pero sin kpts ni embedding');
  }

  double? _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value.trim());
    return null;
  }

  int _toInt(dynamic value) {
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim()) ?? 0;
    return 0;
  }
}
