// lib/features/posture/services/parsers/pose_binary_parser.dart
//
// Binary PO/PD parser (Flutter/Dart) aligned with the Python GI client:
//
// Layout (all integers little-endian unless noted):
// PO:
//   0:2  "PO"
//   2:1  ver (u8)
//   3:2  nposes (u16 LE)
//   5:2  w (u16 LE)
//   7:2  h (u16 LE)
//   ...  per pose:
//        - npts (u16 LE)
//        - npts * { x(u16 LE), y(u16 LE) }
//
// PD:
//   0:2  "PD"
//   2:1  ver (u8)
//   3:1  flags (u8)  bit0 = keyframe (absolute)
//   4:2  seq (u16 LE)
//   6:2  nposes (u16 LE)
//   8:2  w (u16 LE)
//  10:2  h (u16 LE)
//   ...  per pose:
//        - npts (u16 LE)
//        - if keyframe || no baseline:
//             npts * { x(u16 LE), y(u16 LE) }   // absolute
//          else (delta):
//             mask = ceil(npts/8) bytes (LSB-first)
//             for j in 0..npts-1:
//               if mask bit j == 1: dx(i8), dy(i8)
//               else: copy previous point
//             then clamp to [0..w-1]x[0..h-1]
//
// Notes:
// - No extra per-pose "score" field.
// - Parser does not enforce sequence continuity (mirrors Python client).
//   It surfaces `ackSeq` for PD packets; requestKeyframe is only used on parse errors.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset;

enum PacketKind { po, pd }

class PosePacket {
  const PosePacket({
    required this.kind,
    required this.w,
    required this.h,
    required this.poses,
    this.seq,
    this.keyframe = false,
  });

  final PacketKind kind;
  final int w;
  final int h;
  final List<List<Offset>> poses;
  final int? seq;
  final bool keyframe;
}

abstract class PoseParseResult {
  const PoseParseResult();
}

class PoseParseOk extends PoseParseResult {
  const PoseParseOk({
    required this.packet,
    this.ackSeq,
    this.requestKeyframe = false,
  });

  final PosePacket packet;
  final int? ackSeq;
  final bool requestKeyframe;
}

class PoseParseNeedKF extends PoseParseResult {
  const PoseParseNeedKF(this.reason);
  final String reason;
}

class PoseBinaryParser {
  PoseBinaryParser({this.enforceBounds = true});

  final bool enforceBounds;

  List<List<Offset>>? _lastPoses;
  int _errors = 0;

  List<List<Offset>>? get lastPoses => _lastPoses;
  int get parseErrors => _errors;

  void reset() {
    _lastPoses = null;
    _errors = 0;
  }

  PoseParseResult parse(Uint8List b) {
    try {
      if (b.length < 2) {
        _errors++;
        return const PoseParseNeedKF('short packet');
      }

      // 'P''O'
      if (b[0] == 0x50 && b[1] == 0x4F) {
        final pkt = _parsePO(b);
        _lastPoses = pkt.poses;

        // (Optional) tiny debug sample
        final pts = pkt.poses.isNotEmpty ? pkt.poses.first : const <Offset>[];
        if (pts.isNotEmpty) {
          final a = pts.first, m = pts[pts.length ~/ 2];
          // ignore: avoid_print
          print('[pose:PO] first=${a.dx.toInt()},${a.dy.toInt()} '
              'mid=${m.dx.toInt()},${m.dy.toInt()} of ${pts.length}');
        }

        return PoseParseOk(packet: pkt);
      }

      // 'P''D'
      if (b[0] == 0x50 && b[1] == 0x44) {
        final pkt = _parsePD(b, _lastPoses);
        _lastPoses = pkt.poses;

        // (Optional) tiny debug sample
        final pts = pkt.poses.isNotEmpty ? pkt.poses.first : const <Offset>[];
        if (pts.isNotEmpty) {
          final a = pts.first, m = pts[pts.length ~/ 2];
          // ignore: avoid_print
          print('[pose:PD${pkt.keyframe ? "(KF)" : ""}] first=${a.dx.toInt()},${a.dy.toInt()} '
              'mid=${m.dx.toInt()},${m.dy.toInt()} of ${pts.length} seq=${pkt.seq}');
        }

        // Mirror Python client: do not auto-request KF on seq gaps here.
        return PoseParseOk(packet: pkt, ackSeq: pkt.seq, requestKeyframe: false);
      }

      _errors++;
      return const PoseParseNeedKF('unknown header (not PO/PD)');
    } catch (e) {
      _errors++;
      return PoseParseNeedKF('parse error: $e');
    }
  }

  // ── Internals ──────────────────────────────────────────────────────────────

  PosePacket _parsePO(Uint8List b) {
    int i = 2; // skip 'P','O'
    _require(i + 1 <= b.length, 'PO missing ver');
    i += 1; // ver

    _require(i + 2 <= b.length, 'PO missing nposes');
    final nposes = _u16le(b, i); i += 2;

    _require(i + 2 <= b.length, 'PO missing w');
    final w = _u16le(b, i); i += 2;

    _require(i + 2 <= b.length, 'PO missing h');
    final h = _u16le(b, i); i += 2;

    final poses = <List<Offset>>[];
    for (int p = 0; p < nposes; p++) {
      _require(i + 2 <= b.length, 'PO pose[$p] missing npts');
      final npts = _u16le(b, i); i += 2;

      final need = npts * 4;
      _require(i + need <= b.length, 'PO pose[$p] points short');

      final pts = <Offset>[];
      for (int k = 0; k < npts; k++) {
        final x = _u16le(b, i); i += 2;
        final y = _u16le(b, i); i += 2;
        pts.add(Offset(x.toDouble(), y.toDouble()));
      }
      poses.add(pts);
    }

    return PosePacket(
      kind: PacketKind.po,
      w: w,
      h: h,
      poses: poses,
      keyframe: true,
    );
  }

  PosePacket _parsePD(Uint8List b, List<List<Offset>>? prev) {
    int i = 2; // skip 'P','D'

    _require(i + 1 <= b.length, 'PD missing ver');
    i += 1; // ver

    _require(i + 1 <= b.length, 'PD missing flags');
    final flags = b[i]; i += 1;

    _require(i + 2 <= b.length, 'PD missing seq');
    final seq = _u16le(b, i); i += 2;

    _require(i + 2 <= b.length, 'PD missing nposes');
    final nposes = _u16le(b, i); i += 2;

    _require(i + 2 <= b.length, 'PD missing w');
    final w = _u16le(b, i); i += 2;

    _require(i + 2 <= b.length, 'PD missing h');
    final h = _u16le(b, i); i += 2;

    final isKey = (flags & 1) != 0;

    // Absolute (keyframe) or no baseline available
    if (isKey || prev == null) {
      final poses = <List<Offset>>[];
      for (int p = 0; p < nposes; p++) {
        _require(i + 2 <= b.length, 'PD(KF) pose[$p] missing npts');
        final npts = _u16le(b, i); i += 2;

        final need = npts * 4;
        _require(i + need <= b.length, 'PD(KF) pose[$p] points short');

        final pts = <Offset>[];
        for (int k = 0; k < npts; k++) {
          final x = _u16le(b, i); i += 2;
          final y = _u16le(b, i); i += 2;
          pts.add(_clampedOffset(x, y, w, h));
        }
        poses.add(pts);
      }

      return PosePacket(
        kind: PacketKind.pd,
        w: w,
        h: h,
        poses: poses,
        seq: seq,
        keyframe: true,
      );
    }

    // Delta from previous baseline
    _require(prev.length == nposes, 'PD(Δ) nposes mismatch');

    final poses = <List<Offset>>[];
    for (int p = 0; p < nposes; p++) {
      _require(i + 2 <= b.length, 'PD(Δ) pose[$p] missing npts');
      final npts = _u16le(b, i); i += 2;

      final maskBytes = (npts + 7) >> 3;
      _require(i + maskBytes <= b.length, 'PD(Δ) pose[$p] mask short');

      // Build LSB-first mask as an integer
      int mask = 0;
      for (int mb = 0; mb < maskBytes; mb++) {
        mask |= (b[i + mb] << (8 * mb));
      }
      i += maskBytes;

      final prevPts = prev[p];
      _require(prevPts.length == npts, 'PD(Δ) pose[$p] npts mismatch');

      final out = <Offset>[];
      for (int j = 0; j < npts; j++) {
        int x = prevPts[j].dx.toInt();
        int y = prevPts[j].dy.toInt();

        if (((mask >> j) & 1) == 1) {
          _require(i + 2 <= b.length, 'PD(Δ) pose[$p] dxdy short @pt $j');
          x += _asInt8(b[i]); i += 1;
          y += _asInt8(b[i]); i += 1;
        }
        out.add(_clampedOffset(x, y, w, h));
      }
      poses.add(out);
    }

    return PosePacket(
      kind: PacketKind.pd,
      w: w,
      h: h,
      poses: poses,
      seq: seq,
      keyframe: false,
    );
  }

  // ── helpers ────────────────────────────────────────────────────────────────
  static int _u16le(Uint8List b, int i) => b[i] | (b[i + 1] << 8);
  static int _asInt8(int u) => (u & 0x80) != 0 ? (u - 256) : u;

  Offset _clampedOffset(int x, int y, int w, int h) {
    if (!enforceBounds) return Offset(x.toDouble(), y.toDouble());
    final cx = math.max(0, math.min(w - 1, x));
    final cy = math.max(0, math.min(h - 1, y));
    return Offset(cx.toDouble(), cy.toDouble());
  }

  static void _require(bool cond, String msg) {
    if (!cond) {
      throw StateError(msg);
    }
  }
}
