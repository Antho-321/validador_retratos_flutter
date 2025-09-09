// lib/features/posture/services/parsers/pose_binary_parser.dart
//
// Binary PO/PD parser (Flutter/Dart) with subpixel quantization and optional Z.
// - scale (Q) = 1 << (ver & 0x03); baseline stored in quantized ints.
// - Z (if present):
//     * PO/PD(KF): z_q as i16 absolute per point
//     * PD(Δ): dz as i8 per changed point
//   Public z = z_q / (1<<POSE_Z_SHIFT). If Z is absent, z=null.
//
// Layout (little-endian):
// PO:
//   0:2 "PO", 2:1 ver, 3:2 nposes, 5:2 w_q, 7:2 h_q
//   per pose: npts:u16, then npts * { x_q:u16, y_q:u16 [, z_q:i16 ] }
// PD:
//   0:2 "PD", 2:1 ver, 3:1 flags(bit0=key), 4:2 seq, 6:2 nposes, 8:2 w_q, 10:2 h_q
//   if keyframe or no-baseline:
//       per pose: npts:u16, npts * { x_q:u16, y_q:u16 [, z_q:i16 ] }
//   else (delta):
//       per pose: npts:u16, mask:ceil(npts/8) bytes (LSB-first)
//       then for each bit=1 across all poses in order:
//            dx:i8, dy:i8 [, dz:i8]
//
// Notes (optimizaciones):
// - “Sticky Z”: detecta presencia de Z en PO o PD(KF) y la reutiliza en todos los PD(Δ)
//   siguientes (sin pre-scan caro). Si hay inconsistencia → Need KF.
// - No se construyen enteros gigantes para la máscara; se leen bytes on-the-fly.
// - Clamp en dominio quantized; expone w,h en px; PosePoint(x,y,z?) en px / z normalizado.

import 'dart:math' as math;
import 'dart:typed_data';
import '../../infrastructure/model/pose_point.dart';

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
  final int w; // px
  final int h; // px
  final List<List<PosePoint>> poses; // px; z==null if no Z present
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

// Quantized baseline point
class _PtQ {
  int x;
  int y;
  int? z; // quantized z (i16 domain), nullable if stream had no Z
  _PtQ(this.x, this.y, [this.z]);
}

class PoseBinaryParser {
  PoseBinaryParser({
    this.enforceBounds = true,
    this.poseZShift = 7, // must match server; exposed for tuning
  }) : zScale = 1 << ((poseZShift < 0) ? 0 : (poseZShift > 15 ? 15 : poseZShift));

  final bool enforceBounds;
  final int poseZShift;
  final int zScale; // 1<<poseZShift

  // Last published (float px)
  List<List<PosePoint>>? _lastPoses;
  int _errors = 0;

  // Baseline in Q
  List<List<_PtQ>>? _lastQ;
  int _lastScale = 1;
  int _lastWq = 0;
  int _lastHq = 0;

  // Sticky Z presence (null until first KF decides)
  bool? _hasZ;

  List<List<PosePoint>>? get lastPoses => _lastPoses;
  int get parseErrors => _errors;

  void reset() {
    _lastPoses = null;
    _lastQ = null;
    _lastScale = 1;
    _lastWq = 0;
    _lastHq = 0;
    _errors = 0;
    _hasZ = null;
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
        return PoseParseOk(packet: pkt, ackSeq: pkt.seq);
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
    int i = 2; // skip 'PO'
    _require(i + 1 <= b.length, 'PO missing ver');
    final ver = b[i];
    i += 1;

    _require(i + 2 <= b.length, 'PO missing nposes');
    final nposes = _u16le(b, i);
    i += 2;

    _require(i + 2 <= b.length, 'PO missing w');
    final wq = _u16le(b, i);
    i += 2;

    _require(i + 2 <= b.length, 'PO missing h');
    final hq = _u16le(b, i);
    i += 2;

    final scale = _deriveScale(ver, wq, hq);
    final wpx = wq ~/ scale;
    final hpx = hq ~/ scale;

    // Pre-scan para detectar Z una sola vez
    int j = i;
    int totalPts = 0;
    for (int p = 0; p < nposes; p++) {
      _require(j + 2 <= b.length, 'PO pre-scan: missing npts @pose $p');
      final npts = _u16le(b, j);
      j += 2;
      totalPts += npts;
      _require(totalPts >= 0, 'overflow');
    }
    final int expectedXY = j + totalPts * 4;
    final int expectedXYZ = j + totalPts * 6;
    final bool hasZ = (b.length == expectedXYZ) || ((b.length - j) == totalPts * 6);
    _hasZ = hasZ; // STICKY Z

    final posesQ = <List<_PtQ>>[];
    final posesPx = <List<PosePoint>>[];

    for (int p = 0; p < nposes; p++) {
      _require(i + 2 <= b.length, 'PO pose[$p] missing npts');
      final npts = _u16le(b, i);
      i += 2;

      final need = npts * (hasZ ? 6 : 4);
      _require(i + need <= b.length, 'PO pose[$p] points short');

      final ptsQ = <_PtQ>[];
      final ptsPx = <PosePoint>[];

      for (int k = 0; k < npts; k++) {
        final xq = _u16le(b, i); i += 2;
        final yq = _u16le(b, i); i += 2;
        int? zq;
        if (hasZ) {
          zq = _i16le(b, i); i += 2;
          zq = _clampZq(zq);
        }

        final cxq = _clampQ(xq, wq);
        final cyq = _clampQ(yq, hq);
        ptsQ.add(_PtQ(cxq, cyq, zq));
        ptsPx.add(PosePoint(
          x: cxq / scale,
          y: cyq / scale,
          z: zq != null ? (zq / zScale) : null,
        ));
      }
      posesQ.add(ptsQ);
      posesPx.add(ptsPx);
    }

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
    int i = 2; // skip 'PD'

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

    // Paridad con Python: no aceptar cambios de Q o dims sin KF
    final noBaseline = (_lastQ == null);
    final scaleChanged = (!noBaseline && _lastScale != scale);
    final dimsChanged = (!noBaseline && (_lastWq != wq || _lastHq != hq));
    if (!isKey && (scaleChanged || dimsChanged)) {
      throw StateError('PD: Q/dims changed without keyframe');
    }

    // KEYFRAME (o no baseline): leer absoluto y fijar hasZ
    if (isKey || noBaseline) {
      int j = i;
      int totalPts = 0;
      for (int p = 0; p < nposes; p++) {
        _require(j + 2 <= b.length, 'PD(KF) pre-scan: missing npts @pose $p');
        final npts = _u16le(b, j);
        j += 2;
        totalPts += npts;
      }
      final expectedXY = j + totalPts * 4;
      final expectedXYZ = j + totalPts * 6;
      final hasZ = (b.length == expectedXYZ) || ((b.length - j) == totalPts * 6);
      _hasZ = hasZ; // STICKY Z

      final posesQ = <List<_PtQ>>[];
      final posesPx = <List<PosePoint>>[];

      for (int p = 0; p < nposes; p++) {
        _require(i + 2 <= b.length, 'PD(KF) pose[$p] missing npts');
        final npts = _u16le(b, i);
        i += 2;

        final need = npts * (hasZ ? 6 : 4);
        _require(i + need <= b.length, 'PD(KF) pose[$p] points short');

        final ptsQ = <_PtQ>[];
        final ptsPx = <PosePoint>[];

        for (int k = 0; k < npts; k++) {
          final xq = _u16le(b, i); i += 2;
          final yq = _u16le(b, i); i += 2;
          int? zq;
          if (hasZ) {
            zq = _i16le(b, i); i += 2;
            zq = _clampZq(zq);
          }

          final cxq = _clampQ(xq, wq);
          final cyq = _clampQ(yq, hq);
          ptsQ.add(_PtQ(cxq, cyq, zq));
          ptsPx.add(PosePoint(
            x: cxq / scale,
            y: cyq / scale,
            z: zq != null ? (zq / zScale) : null,
          ));
        }

        posesQ.add(ptsQ);
        posesPx.add(ptsPx);
      }

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

    // DELTA: usar sticky _hasZ sin pre-scan caro
    if (_hasZ == null) {
      throw StateError('PD(Δ): unknown Z presence (need keyframe)');
    }
    final bool hasZ = _hasZ!;

    final prevQ = _lastQ!;
    _require(prevQ.length == nposes, 'PD(Δ) nposes mismatch');

    final posesQ = <List<_PtQ>>[];
    final posesPx = <List<PosePoint>>[];

    for (int p = 0; p < nposes; p++) {
      _require(i + 2 <= b.length, 'PD(Δ) pose[$p] missing npts');
      final npts = _u16le(b, i);
      i += 2;

      final maskBytes = (npts + 7) >> 3;
      _require(i + maskBytes <= b.length, 'PD(Δ) pose[$p] mask short');

      final int maskStart = i; // no subsections/allocations; leemos on-the-fly
      i += maskBytes;

      final prevPts = prevQ[p];
      _require(prevPts.length == npts, 'PD(Δ) pose[$p] npts mismatch');

      final outQ = <_PtQ>[];
      final outPx = <PosePoint>[];

      for (int j = 0; j < npts; j++) {
        final mb = j >> 3;         // index del byte
        final bb = j & 7;          // bit en el byte (LSB primero)
        final changed = ((b[maskStart + mb] >> bb) & 1) == 1;

        int xq = prevPts[j].x;
        int yq = prevPts[j].y;
        int? zq = prevPts[j].z;

        if (changed) {
          _require(i + 2 <= b.length, 'PD(Δ) pose[$p] dxdy short @pt $j');
          xq += _asInt8(b[i]); i += 1;
          yq += _asInt8(b[i]); i += 1;
          if (hasZ) {
            _require(i + 1 <= b.length, 'PD(Δ) pose[$p] dz short @pt $j');
            final dz = _asInt8(b[i]); i += 1;
            final prevZ = zq ?? 0;
            zq = _clampZq(prevZ + dz);
          }
        }
        xq = _clampQ(xq, wq);
        yq = _clampQ(yq, hq);

        outQ.add(_PtQ(xq, yq, zq));
        outPx.add(PosePoint(
          x: xq / scale,
          y: yq / scale,
          z: (hasZ && zq != null) ? (zq / zScale) : null,
        ));
      }

      posesQ.add(outQ);
      posesPx.add(outPx);
    }

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

  static int _i16le(Uint8List b, int i) {
    final v = b[i] | (b[i + 1] << 8);
    return (v & 0x8000) != 0 ? (v - 0x10000) : v;
  }

  static int _asInt8(int u) => (u & 0x80) != 0 ? (u - 256) : u;

  // (ya no se usa en el flujo optimizado; se deja por si te sirve en debug)
  static int _popcount(int x) {
    int c = 0;
    var t = x;
    while (t != 0) {
      c += (t & 1);
      t >>= 1;
    }
    return c;
  }

  int _clampQ(int v, int limitQ) {
    if (!enforceBounds) return v;
    return math.max(0, math.min(limitQ - 1, v));
  }

  int _clampZq(int zq) {
    // int16 clamp
    if (zq < -32768) return -32768;
    if (zq > 32767) return 32767;
    return zq;
  }

  static int _deriveScale(int ver, int wq, int hq) {
    final pow2 = ver & 0x03; // bits 0..1
    int s = 1 << pow2;
    if (s < 1) s = 1;
    if (s != 1) {
      if ((wq % s) != 0 || (hq % s) != 0) {
        // Conservative fallback if header dims aren't scaled
        return 1;
      }
    }
    return s;
  }

  static void _require(bool cond, String msg) {
    if (!cond) throw StateError(msg);
  }
}
