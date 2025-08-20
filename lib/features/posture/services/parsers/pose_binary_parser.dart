// lib/features/posture/services/parsers/pose_binary_parser.dart
//
// Stateful PO/PD binary parser for pose packets.
// - Accepts Uint8List packets beginning with 'PO' (0x50 0x4F) or 'PD' (0x50 0x44)
// - Maintains last full pose frame (for PD deltas) and expected PD sequence
// - Bounds-clamps deltas into [0, w-1] x [0, h-1]
// - Surfaces "need keyframe" when header is unknown, parsing fails, or PD seq mismatches
//
// This class is UI-agnostic and has ZERO dependencies on PoseWebRTCService.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset;

/// Packet type.
enum PacketKind { po, pd }

/// Successful parsed packet (either PO or PD).
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
  /// Present for PD packets (0..65535); null for PO.
  final int? seq;
  /// True when PD has keyframe flag set.
  final bool keyframe;
}

/// Base class for parsing outcomes.
abstract class PoseParseResult {
  const PoseParseResult();
}

/// OK: a packet was parsed.
/// - [packet] contains poses.
/// - [ackSeq] is set for PD (seq to ACK), null for PO.
/// - [requestKeyframe] suggests sending KF (e.g., PD seq mismatch) *in addition* to using this packet.
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

/// Indicates we could not use the packet and a KF should be requested.
class PoseParseNeedKF extends PoseParseResult {
  const PoseParseNeedKF(this.reason);
  final String reason;
}

/// A small, stateful PO/PD parser.
class PoseBinaryParser {
  PoseBinaryParser({this.enforceBounds = true});

  /// Clamp PD results to [0, w-1] x [0, h-1].
  final bool enforceBounds;

  List<List<Offset>>? _lastPoses;
  int? _expectedSeq;
  int _errors = 0;

  /// Last fully reconstructed poses (from PO or PD), if any.
  List<List<Offset>>? get lastPoses => _lastPoses;

  /// Number of parse errors so far.
  int get parseErrors => _errors;

  /// Reset internal state (forget baseline + expected seq).
  void reset() {
    _lastPoses = null;
    _expectedSeq = null;
    _errors = 0;
  }

  /// Feed one binary packet.
  PoseParseResult parse(Uint8List b) {
    try {
      if (b.length < 2) {
        _errors++;
        return const PoseParseNeedKF('short packet');
      }

      // 'P' 'O'
      if (b[0] == 0x50 && b[1] == 0x4F) {
        final pkt = _parsePO(b);
        _lastPoses = pkt.poses;
        _expectedSeq = null; // reset sequence after a full frame
        return PoseParseOk(packet: pkt, ackSeq: null, requestKeyframe: false);
      }

      // 'P' 'D'
      if (b[0] == 0x50 && b[1] == 0x44) {
        final pkt = _parsePD(b, _lastPoses);

        bool needKF = false;
        if (_expectedSeq != null && pkt.seq != _expectedSeq) {
          // Signal KF but still return the parsed packet (matches original behavior).
          needKF = true;
          _expectedSeq = null;
        }
        _expectedSeq = ((pkt.seq ?? 0) + 1) & 0xFFFF;

        _lastPoses = pkt.poses;
        return PoseParseOk(
          packet: pkt,
          ackSeq: pkt.seq,
          requestKeyframe: needKF,
        );
      }

      _errors++;
      return const PoseParseNeedKF('unknown header (not PO/PD)');
    } catch (e) {
      _errors++;
      return PoseParseNeedKF('parse error: $e');
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Internals
  // ───────────────────────────────────────────────────────────────────────────

  PosePacket _parsePO(Uint8List b) {
    int i = 2; // skip 'P','O'

    _require(i + 1 <= b.length, 'PO missing ver');
    i += 1; // version

    _require(i + 1 <= b.length, 'PO missing nposes');
    final nposes = b[i];
    i += 1;

    _require(i + 2 <= b.length, 'PO missing w');
    final w = _u16le(b, i);
    i += 2;

    _require(i + 2 <= b.length, 'PO missing h');
    final h = _u16le(b, i);
    i += 2;

    final poses = <List<Offset>>[];

    for (int p = 0; p < nposes; p++) {
      _require(i + 1 <= b.length, 'PO pose[$p] missing npts');
      final npts = b[i];
      i += 1;

      final need = npts * 4;
      _require(i + need <= b.length, 'PO pose[$p] points short');

      final pts = <Offset>[];
      for (int k = 0; k < npts; k++) {
        final x = _u16le(b, i);
        i += 2;
        final y = _u16le(b, i);
        i += 2;
        pts.add(Offset(x.toDouble(), y.toDouble()));
      }
      poses.add(pts);
    }

    return PosePacket(
      kind: PacketKind.po,
      w: w,
      h: h,
      poses: poses,
      seq: null,
      keyframe: true,
    );
  }

  PosePacket _parsePD(Uint8List b, List<List<Offset>>? prev) {
    int i = 2; // skip 'P','D'
    _require(i + 1 + 1 + 2 + 1 + 2 + 2 <= b.length, 'PD header short');

    i += 1; // version
    final flags = b[i];
    i += 1;

    final seq = _u16le(b, i);
    i += 2;

    final nposes = b[i];
    i += 1;

    final w = _u16le(b, i);
    i += 2;

    final h = _u16le(b, i);
    i += 2;

    final isKey = (flags & 1) != 0;

    // If keyframe flag is set or we don't have a baseline, read absolute points.
    if (isKey || prev == null) {
      final poses = <List<Offset>>[];
      for (int p = 0; p < nposes; p++) {
        _require(i + 1 <= b.length, 'PD(KF) pose[$p] missing npts');
        final npts = b[i];
        i += 1;

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

    // Delta from previous.
    _require(prev.length == nposes, 'PD(Δ) nposes mismatch');

    final poses = <List<Offset>>[];
    for (int p = 0; p < nposes; p++) {
      _require(i + 1 <= b.length, 'PD(Δ) pose[$p] missing npts');
      final npts = b[i];
      i += 1;

      final maskBytes = (npts + 7) >> 3;
      _require(i + maskBytes <= b.length, 'PD(Δ) pose[$p] mask short');

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
