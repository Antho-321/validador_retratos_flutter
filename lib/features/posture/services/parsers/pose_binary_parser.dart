// lib/features/posture/services/parsers/pose_binary_parser.dart
//
// Binary PO/PD parser (Flutter/Dart) with subpixel quantization support.
// - Reads scale from `ver` low bits: scale = 1 << (ver & 0x03)
// - Stores previous baseline in *quantized ints* to avoid drift with int8 deltas.
//
// Layout (little-endian):
// PO:
//   0:2  "PO"
//   2:1  ver (u8)  -> scale = 1 << (ver & 0x03)  [fallback=1 if inconsistent]
//   3:2  nposes (u16)
//   5:2  w_q (u16)  (quantized: w_px * scale)
//   7:2  h_q (u16)
//   ...  per pose:
//        - npts (u16)
//        - npts * { x_q(u16), y_q(u16) }   (quantized)
//
// PD:
//   0:2  "PD"
//   2:1  ver (u8)  -> scale = 1 << (ver & 0x03)  [fallback=1 if inconsistent]
//   3:1  flags (u8)  bit0 = keyframe
//   4:2  seq (u16)
//   6:2  nposes (u16)
//   8:2  w_q (u16)
//  10:2  h_q (u16)
//   ...  per pose:
//        - npts (u16)
//        - if keyframe (absolute):
//             npts * { x_q(u16), y_q(u16) }
//          else (delta vs baseline):
//             mask = ceil(npts/8) bytes (LSB-first)
//             for j in 0..npts-1:
//               if bit j == 1: dx_q(i8), dy_q(i8)   (quantized deltas)
//               else: copy previous point
//
// Notes:
// - We clamp in the quantized domain [0..w_q-1]x[0..h_q-1] and then divide by `scale`.
// - Public packet exposes w,h in *pixels* (ints) and poses as `Offset` in pixels (floats).
// - If scale changes mid-stream and the packet is not a KF, we request KF.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset;

enum PacketKind { po, pd }

class PosePacket {
  const PosePacket({
    required this.kind,
    required this.w,   // pixels (int)
    required this.h,   // pixels (int)
    required this.poses, // Offsets in pixels (float)
    this.seq,
    this.keyframe = false,
  });

  final PacketKind kind;
  final int w; // px
  final int h; // px
  final List<List<Offset>> poses; // px (float)
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

// Internal quantized point (integers)
class _PtQ {
  int x;
  int y;
  _PtQ(this.x, this.y);
}

class PoseBinaryParser {
  PoseBinaryParser({this.enforceBounds = true});

  final bool enforceBounds;

  // Last published (float px) — external visibility
  List<List<Offset>>? _lastPoses;
  int _errors = 0;

  // Baseline in quantized integers — used to apply int8 deltas precisely
  List<List<_PtQ>>? _lastQ;
  int _lastScale = 1;   // last quantization scale (1,2,4…)
  int _lastWq = 0;      // last width in quantized units
  int _lastHq = 0;      // last height in quantized units

  List<List<Offset>>? get lastPoses => _lastPoses;
  int get parseErrors => _errors;

  void reset() {
    _lastPoses = null;
    _lastQ = null;
    _lastScale = 1;
    _lastWq = 0;
    _lastHq = 0;
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
        return PoseParseOk(packet: pkt);
      }

      // 'P''D'
      if (b[0] == 0x50 && b[1] == 0x44) {
        final pkt = _parsePD(b);
        _lastPoses = pkt.poses;
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
    final ver = b[i]; i += 1;

    _require(i + 2 <= b.length, 'PO missing nposes');
    final nposes = _u16le(b, i); i += 2;

    _require(i + 2 <= b.length, 'PO missing w');
    final wq = _u16le(b, i); i += 2;

    _require(i + 2 <= b.length, 'PO missing h');
    final hq = _u16le(b, i); i += 2;

    final scale = _deriveScale(ver, wq, hq);
    final wpx = wq ~/ scale;
    final hpx = hq ~/ scale;

    final posesQ = <List<_PtQ>>[];
    final posesPx = <List<Offset>>[];

    for (int p = 0; p < nposes; p++) {
      _require(i + 2 <= b.length, 'PO pose[$p] missing npts');
      final npts = _u16le(b, i); i += 2;

      final need = npts * 4;
      _require(i + need <= b.length, 'PO pose[$p] points short');

      final ptsQ = <_PtQ>[];
      final ptsPx = <Offset>[];
      for (int k = 0; k < npts; k++) {
        final xq = _u16le(b, i); i += 2;
        final yq = _u16le(b, i); i += 2;

        final cxq = _clampQ(xq, wq);
        final cyq = _clampQ(yq, hq);
        ptsQ.add(_PtQ(cxq, cyq));
        ptsPx.add(Offset(cxq / scale, cyq / scale));
      }
      posesQ.add(ptsQ);
      posesPx.add(ptsPx);
    }

    // Update baseline (quantized)
    _lastQ = posesQ;
    _lastScale = scale;
    _lastWq = wq;
    _lastHq = hq;

    return PosePacket(
      kind: PacketKind.po,
      w: wpx,
      h: hpx,
      poses: posesPx,
      keyframe: true,
    );
  }

  PosePacket _parsePD(Uint8List b) {
    int i = 2; // skip 'P','D'

    _require(i + 1 <= b.length, 'PD missing ver');
    final ver = b[i]; i += 1;

    _require(i + 1 <= b.length, 'PD missing flags');
    final flags = b[i]; i += 1;

    _require(i + 2 <= b.length, 'PD missing seq');
    final seq = _u16le(b, i); i += 2;

    _require(i + 2 <= b.length, 'PD missing nposes');
    final nposes = _u16le(b, i); i += 2;

    _require(i + 2 <= b.length, 'PD missing w');
    final wq = _u16le(b, i); i += 2;

    _require(i + 2 <= b.length, 'PD missing h');
    final hq = _u16le(b, i); i += 2;

    final bool isKey = (flags & 1) != 0;
    final scale = _deriveScale(ver, wq, hq);
    final wpx = wq ~/ scale;
    final hpx = hq ~/ scale;

    // If KF or no valid baseline/scale mismatch → decode absolute like PO
    final noBaseline = (_lastQ == null);
    final scaleChanged = (!noBaseline && _lastScale != scale);
    if (isKey || noBaseline || scaleChanged) {
      final posesQ = <List<_PtQ>>[];
      final posesPx = <List<Offset>>[];

      for (int p = 0; p < nposes; p++) {
        _require(i + 2 <= b.length, 'PD(KF) pose[$p] missing npts');
        final npts = _u16le(b, i); i += 2;

        final need = npts * 4;
        _require(i + need <= b.length, 'PD(KF) pose[$p] points short');

        final ptsQ = <_PtQ>[];
        final ptsPx = <Offset>[];
        for (int k = 0; k < npts; k++) {
          final xq = _u16le(b, i); i += 2;
          final yq = _u16le(b, i); i += 2;
          final cxq = _clampQ(xq, wq);
          final cyq = _clampQ(yq, hq);
          ptsQ.add(_PtQ(cxq, cyq));
          ptsPx.add(Offset(cxq / scale, cyq / scale));
        }
        posesQ.add(ptsQ);
        posesPx.add(ptsPx);
      }

      // Update baseline (quantized)
      _lastQ = posesQ;
      _lastScale = scale;
      _lastWq = wq;
      _lastHq = hq;

      return PosePacket(
        kind: PacketKind.pd,
        w: wpx,
        h: hpx,
        poses: posesPx,
        seq: seq,
        keyframe: true,
      );
    }

    // Delta from previous baseline
    final prevQ = _lastQ!;
    _require(prevQ.length == nposes, 'PD(Δ) nposes mismatch');

    final posesQ = <List<_PtQ>>[];
    final posesPx = <List<Offset>>[];

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

      final prevPts = prevQ[p];
      _require(prevPts.length == npts, 'PD(Δ) pose[$p] npts mismatch');

      final outQ = <_PtQ>[];
      final outPx = <Offset>[];

      for (int j = 0; j < npts; j++) {
        int xq = prevPts[j].x;
        int yq = prevPts[j].y;

        if (((mask >> j) & 1) == 1) {
          _require(i + 2 <= b.length, 'PD(Δ) pose[$p] dxdy short @pt $j');
          xq += _asInt8(b[i]); i += 1;
          yq += _asInt8(b[i]); i += 1;
        }

        // Clamp in quantized domain, then convert to px
        xq = _clampQ(xq, wq);
        yq = _clampQ(yq, hq);
        outQ.add(_PtQ(xq, yq));
        outPx.add(Offset(xq / scale, yq / scale));
      }

      posesQ.add(outQ);
      posesPx.add(outPx);
    }

    // Update baseline (quantized)
    _lastQ = posesQ;
    _lastScale = scale;
    _lastWq = wq;
    _lastHq = hq;

    return PosePacket(
      kind: PacketKind.pd,
      w: wpx,
      h: hpx,
      poses: posesPx,
      seq: seq,
      keyframe: false,
    );
  }

  // ── helpers ────────────────────────────────────────────────────────────────

  static int _u16le(Uint8List b, int i) => b[i] | (b[i + 1] << 8);
  static int _asInt8(int u) => (u & 0x80) != 0 ? (u - 256) : u;

  // Clamp an integer coordinate in quantized domain [0..limit-1]
  int _clampQ(int v, int limitQ) {
    if (!enforceBounds) return v;
    return math.max(0, math.min(limitQ - 1, v));
    // (if limitQ==0 we never get here because headers would be invalid)
  }

  // Derive scale from ver low bits; fall back to 1 if inconsistent.
  static int _deriveScale(int ver, int wq, int hq) {
    final pow2 = ver & 0x03; // bits 0..1
    int s = 1 << pow2;
    if (s < 1) s = 1;

    // Back-compat guard: if header doesn't look quantized to s, use 1.
    if (s != 1) {
      if ((wq % s) != 0 || (hq % s) != 0) {
        // Older servers might set ver=2 but not scale the dims; be conservative.
        return 1;
      }
    }
    return s;
  }

  static void _require(bool cond, String msg) {
    if (!cond) {
      throw StateError(msg);
    }
  }
}
