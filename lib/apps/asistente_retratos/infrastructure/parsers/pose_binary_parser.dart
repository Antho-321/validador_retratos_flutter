// lib/apps/asistente_retratos/infrastructure/parsers/pose_binary_parser.dart
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
enum PacketKind { po, pd }

abstract class PoseParseResult {
  const PoseParseResult();
}

class PoseParseOkPacked extends PoseParseResult {
  const PoseParseOkPacked({
    required this.kind,
    required this.w,
    required this.h,
    required this.positions,
    required this.ranges,
    required this.hasZ,
    this.zPositions,
    this.seq,
    required this.keyframe,
    this.ackSeq,
    this.requestKeyframe = false,
  });

  final PacketKind kind;
  final int w;
  final int h;
  final Float32List positions;
  final Int32List ranges;
  final bool hasZ;
  final Float32List? zPositions;
  final int? seq;
  final bool keyframe;
  final int? ackSeq;
  final bool requestKeyframe;
}

class PoseParseNeedKF extends PoseParseResult {
  const PoseParseNeedKF(this.reason);
  final String reason;
}

class PoseBinaryParser {
  PoseBinaryParser({
    this.enforceBounds = true,
    this.poseZShift = 7, // must match server; exposed for tuning
  }) : zScale = 1 << ((poseZShift < 0) ? 0 : (poseZShift > 15 ? 15 : poseZShift));

  final bool enforceBounds;
  final int poseZShift;
  final int zScale; // 1<<poseZShift

  int _errors = 0;

  // Compact baseline in Q-domain
  Uint16List? _baseXY; // [x0,y0, x1,y1, ...]
  Int16List? _baseZ; // nullable when stream has no Z
  Int32List? _lastRangesBuf; // cached ranges (start,len per pose)
  int _lastTotalPts = 0;
  int _lastNposes = 0;
  int _lastScale = 1;
  int _lastWq = 0;
  int _lastHq = 0;

  // Sticky Z presence (null until first KF decides)
  bool? _hasZ;

  Float32List? _positions;
  Float32List? _positionsView;
  int _positionsViewLen = 0;

  Int32List? _ranges;
  Int32List? _rangesView;
  int _rangesViewLen = 0;

  Float32List? _z;
  Float32List? _zView;
  int _zViewLen = 0;
  int get parseErrors => _errors;

  void reset() {
    _baseXY = null;
    _baseZ = null;
    _lastRangesBuf = null;
    _lastTotalPts = 0;
    _lastNposes = 0;
    _lastScale = 1;
    _lastWq = 0;
    _lastHq = 0;
    _errors = 0;
    _hasZ = null;
    _positions = null;
    _positionsView = null;
    _positionsViewLen = 0;
    _ranges = null;
    _rangesView = null;
    _rangesViewLen = 0;
    _z = null;
    _zView = null;
    _zViewLen = 0;
  }

  PoseParseResult parse(Uint8List b) => _parsePacked(b);

  PoseParseResult parseIntoFlat2D(
    Uint8List b, {
    Float32List? reusePositions,
    Int32List? reuseRanges,
    Float32List? reuseZ,
  }) =>
      _parsePacked(
        b,
        reusePositions: reusePositions,
        reuseRanges: reuseRanges,
        reuseZ: reuseZ,
        allowReuse: true,
      );

  PoseParseResult _parsePacked(
    Uint8List b, {
    Float32List? reusePositions,
    Int32List? reuseRanges,
    Float32List? reuseZ,
    bool allowReuse = false,
  }) {
    try {
      if (b.length < 2) {
        _errors++;
        return const PoseParseNeedKF('short packet');
      }
      if (b[0] == 0x50 && b[1] == 0x4F) { // 'PO'
        return _parsePOPacked(
          b,
          reusePositions: reusePositions,
          reuseRanges: reuseRanges,
          reuseZ: reuseZ,
          allowReuse: allowReuse,
        );
      }
      if (b[0] == 0x50 && b[1] == 0x44) { // 'PD'
        return _parsePDPacked(
          b,
          reusePositions: reusePositions,
          reuseRanges: reuseRanges,
          reuseZ: reuseZ,
          allowReuse: allowReuse,
        );
      }
      _errors++;
      return const PoseParseNeedKF('unknown header (not PO/PD)');
    } catch (e) {
      _errors++;
      return PoseParseNeedKF('parse error: $e');
    }
  }

  PoseParseOkPacked _parsePOPacked(
    Uint8List b, {
    Float32List? reusePositions,
    Int32List? reuseRanges,
    Float32List? reuseZ,
    bool allowReuse = false,
  }) {
    int i = 2;
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
    final int wpx = wq ~/ scale;
    final int hpx = hq ~/ scale;
    final double invScale = 1.0 / scale;

    int j = i;
    int totalPts = 0;
    for (int p = 0; p < nposes; p++) {
      _require(j + 2 <= b.length, 'PO pre-scan: missing npts @pose $p');
      final npts = _u16le(b, j);
      j += 2;
      totalPts += npts;
      _require(totalPts >= 0, 'overflow');
    }
    final bool hasZ =
        (b.length == (j + totalPts * 6)) || ((b.length - j) == totalPts * 6);
    _hasZ = hasZ;

    final int positionsFloats = totalPts * 2;
    final int rangesLen = nposes * 2;

    final Float32List positionsBuf = allowReuse
        ? _ensurePositions(positionsFloats, reusePositions)
        : Float32List(positionsFloats);
    _positions = positionsBuf;
    _positionsView = null;
    _positionsViewLen = positionsFloats;
    final Float32List positions = allowReuse
        ? _viewPositions(positionsBuf, positionsFloats)
        : positionsBuf;

    Float32List? zBuf;
    Float32List? zPositions;
    if (hasZ) {
      zBuf = allowReuse
          ? _ensureZ(totalPts, reuseZ)
          : Float32List(totalPts);
      _z = zBuf;
      _zView = null;
      _zViewLen = totalPts;
      zPositions = allowReuse ? _viewZ(zBuf, totalPts) : zBuf;
    } else {
      _z = null;
      _zView = null;
      _zViewLen = 0;
    }

    final Int32List rangesBuf = allowReuse
        ? _ensureRanges(rangesLen, reuseRanges)
        : Int32List(rangesLen);
    _ranges = rangesBuf;
    _rangesView = null;
    _rangesViewLen = rangesLen;
    final Int32List ranges = allowReuse
        ? _viewRanges(rangesBuf, rangesLen)
        : rangesBuf;

    final int needXY = totalPts << 1;
    Uint16List baseXY = _baseXY ?? Uint16List(needXY);
    if (baseXY.length < needXY) {
      baseXY = Uint16List(needXY);
    }
    _baseXY = baseXY;

    Int16List? baseZ;
    if (hasZ) {
      baseZ = _baseZ ?? Int16List(totalPts);
      if (baseZ.length < totalPts) {
        baseZ = Int16List(totalPts);
      }
      _baseZ = baseZ;
    } else {
      _baseZ = null;
    }

    int writePos = 0;
    int writeZ = 0;
    int startPt = 0;
    int writeXY = 0;

    for (int p = 0; p < nposes; p++) {
      _require(i + 2 <= b.length, 'PO pose[$p] missing npts');
      final npts = _u16le(b, i);
      i += 2;
      final need = npts * (hasZ ? 6 : 4);
      _require(i + need <= b.length, 'PO pose[$p] points short');

      rangesBuf[(p << 1)] = startPt;
      rangesBuf[(p << 1) + 1] = npts;
      startPt += npts;

      for (int k = 0; k < npts; k++) {
        int xq = _u16le(b, i);
        i += 2;
        int yq = _u16le(b, i);
        i += 2;
        xq = _clampQ(xq, wq);
        yq = _clampQ(yq, hq);
        baseXY[writeXY++] = xq;
        baseXY[writeXY++] = yq;
        positionsBuf[writePos++] = xq * invScale;
        positionsBuf[writePos++] = yq * invScale;
        if (hasZ) {
          int zq = _i16le(b, i);
          i += 2;
          zq = _clampZq(zq);
          baseZ![writeZ] = zq;
          zBuf![writeZ++] = zq / zScale;
        }
      }
    }

    _lastRangesBuf = rangesBuf;
    _lastTotalPts = totalPts;
    _lastNposes = nposes;
    _lastScale = scale;
    _lastWq = wq;
    _lastHq = hq;

    return PoseParseOkPacked(
      kind: PacketKind.po,
      w: wpx,
      h: hpx,
      positions: positions,
      ranges: ranges,
      hasZ: hasZ,
      zPositions: zPositions,
      keyframe: true,
    );
  }

  PoseParseOkPacked _parsePDPacked(
    Uint8List b, {
    Float32List? reusePositions,
    Int32List? reuseRanges,
    Float32List? reuseZ,
    bool allowReuse = false,
  }) {
    int i = 2;
    _require(i + 1 <= b.length, 'PD missing ver');
    final ver = b[i];
    i += 1;
    _require(i + 1 <= b.length, 'PD missing flags');
    final flags = b[i];
    i += 1;
    _require(i + 2 <= b.length, 'PD missing seq');
    final seq = _u16le(b, i);
    i += 2;
    _require(i + 2 <= b.length, 'PD missing nposes');
    final nposes = _u16le(b, i);
    i += 2;
    _require(i + 2 <= b.length, 'PD missing w');
    final wq = _u16le(b, i);
    i += 2;
    _require(i + 2 <= b.length, 'PD missing h');
    final hq = _u16le(b, i);
    i += 2;

    final bool isKey = (flags & 1) != 0;
    final int scale = _deriveScale(ver, wq, hq);
    final int wpx = wq ~/ scale;
    final int hpx = hq ~/ scale;
    final double invScale = 1.0 / scale;

    final bool noBaseline = (_baseXY == null || _lastRangesBuf == null);
    final bool scaleChanged = (!noBaseline && _lastScale != scale);
    final bool dimsChanged = (!noBaseline && (_lastWq != wq || _lastHq != hq));
    if (!isKey && (scaleChanged || dimsChanged)) {
      throw StateError('PD: Q/dims changed without keyframe');
    }

    if (isKey || noBaseline) {
      int j = i;
      int totalPts = 0;
      for (int p = 0; p < nposes; p++) {
        _require(j + 2 <= b.length, 'PD(KF) pre-scan: missing npts @pose $p');
        final npts = _u16le(b, j);
        j += 2;
        totalPts += npts;
      }
      final bool hasZ =
          (b.length == (j + totalPts * 6)) || ((b.length - j) == totalPts * 6);
      _hasZ = hasZ;

      final int positionsFloats = totalPts * 2;
      final int rangesLen = nposes * 2;

      final Float32List positionsBuf = allowReuse
          ? _ensurePositions(positionsFloats, reusePositions)
          : Float32List(positionsFloats);
      _positions = positionsBuf;
      _positionsView = null;
      _positionsViewLen = positionsFloats;
      final Float32List positions = allowReuse
          ? _viewPositions(positionsBuf, positionsFloats)
          : positionsBuf;

      Float32List? zBuf;
      Float32List? zPositions;
      if (hasZ) {
        zBuf = allowReuse
            ? _ensureZ(totalPts, reuseZ)
            : Float32List(totalPts);
        _z = zBuf;
        _zView = null;
        _zViewLen = totalPts;
        zPositions = allowReuse ? _viewZ(zBuf, totalPts) : zBuf;
      } else {
        _z = null;
        _zView = null;
        _zViewLen = 0;
      }

      final Int32List rangesBuf = allowReuse
          ? _ensureRanges(rangesLen, reuseRanges)
          : Int32List(rangesLen);
      _ranges = rangesBuf;
      _rangesView = null;
      _rangesViewLen = rangesLen;
      final Int32List ranges = allowReuse
          ? _viewRanges(rangesBuf, rangesLen)
          : rangesBuf;

      final int needXY = totalPts << 1;
      Uint16List baseXY = _baseXY ?? Uint16List(needXY);
      if (baseXY.length < needXY) {
        baseXY = Uint16List(needXY);
      }
      _baseXY = baseXY;

      Int16List? baseZ;
      if (hasZ) {
        baseZ = _baseZ ?? Int16List(totalPts);
        if (baseZ.length < totalPts) {
          baseZ = Int16List(totalPts);
        }
        _baseZ = baseZ;
      } else {
        _baseZ = null;
      }

      int writePos = 0;
      int writeZ = 0;
      int startPt = 0;
      int writeXY = 0;

      for (int p = 0; p < nposes; p++) {
        _require(i + 2 <= b.length, 'PD(KF) pose[$p] missing npts');
        final npts = _u16le(b, i);
        i += 2;
        final need = npts * (hasZ ? 6 : 4);
        _require(i + need <= b.length, 'PD(KF) pose[$p] points short');

        rangesBuf[(p << 1)] = startPt;
        rangesBuf[(p << 1) + 1] = npts;
        startPt += npts;

        for (int k = 0; k < npts; k++) {
          int xq = _u16le(b, i);
          i += 2;
          int yq = _u16le(b, i);
          i += 2;
          xq = _clampQ(xq, wq);
          yq = _clampQ(yq, hq);
          baseXY[writeXY++] = xq;
          baseXY[writeXY++] = yq;
          positionsBuf[writePos++] = xq * invScale;
          positionsBuf[writePos++] = yq * invScale;
          if (hasZ) {
            int zq = _i16le(b, i);
            i += 2;
            zq = _clampZq(zq);
            baseZ![writeZ] = zq;
            zBuf![writeZ++] = zq / zScale;
          }
        }
      }

      _lastRangesBuf = rangesBuf;
      _lastTotalPts = totalPts;
      _lastNposes = nposes;
      _lastScale = scale;
      _lastWq = wq;
      _lastHq = hq;

      return PoseParseOkPacked(
        kind: PacketKind.pd,
        w: wpx,
        h: hpx,
        positions: positions,
        ranges: ranges,
        hasZ: hasZ,
        zPositions: zPositions,
        seq: seq,
        keyframe: true,
        ackSeq: seq,
      );
    }

    if (_hasZ == null) {
      throw StateError('PD(Δ): unknown Z presence (need keyframe)');
    }
    final bool hasZ = _hasZ!;

    final Uint16List? baseXY = _baseXY;
    final Int32List? cachedRanges = _lastRangesBuf;
    _require(baseXY != null && cachedRanges != null, 'PD(Δ) missing baseline');
    _require(_lastNposes == nposes, 'PD(Δ) nposes mismatch');

    final List<int> counts = List<int>.filled(nposes, 0, growable: false);
    int totalPts = 0;
    int scan = i;
    int maskOr = 0;
    for (int p = 0; p < nposes; p++) {
      _require(scan + 2 <= b.length, 'PD(Δ) pose[$p] missing npts');
      final npts = _u16le(b, scan);
      scan += 2;
      final int maskBytes = (npts + 7) >> 3;
      _require(scan + maskBytes <= b.length, 'PD(Δ) pose[$p] mask short');
      for (int m = 0; m < maskBytes; m++) {
        maskOr |= b[scan + m];
      }
      scan += maskBytes;
      counts[p] = npts;
      totalPts += npts;
    }

    _require(_lastTotalPts == totalPts, 'PD(Δ) total points mismatch');

    final int positionsFloats = totalPts * 2;
    final int rangesLen = nposes * 2;

    Float32List posBuf;
    if (_positions != null && _positions!.length >= positionsFloats) {
      posBuf = _positions!;
    } else {
      posBuf = allowReuse
          ? _ensurePositions(positionsFloats, reusePositions)
          : Float32List(positionsFloats);
    }
    _positions = posBuf;
    _positionsView = null;
    _positionsViewLen = positionsFloats;
    final Float32List positions = allowReuse
        ? _viewPositions(posBuf, positionsFloats)
        : posBuf;

    Float32List? zBuf;
    if (hasZ) {
      final Int16List? baseZ = _baseZ;
      if (baseZ == null) {
        throw StateError('PD(Δ) missing Z baseline');
      }
      if (_z != null && _z!.length >= totalPts) {
        zBuf = _z!;
      } else {
        zBuf = allowReuse
            ? _ensureZ(totalPts, reuseZ)
            : Float32List(totalPts);
      }
      _z = zBuf;
      _zView = null;
      _zViewLen = totalPts;
    } else {
      _z = null;
      _zView = null;
      _zViewLen = 0;
    }

    final Int32List rangesBuf = cachedRanges;
    _ranges = rangesBuf;
    _rangesView = null;
    _rangesViewLen = rangesLen;
    final Int32List ranges = allowReuse
        ? _viewRanges(rangesBuf, rangesLen)
        : rangesBuf;

    if (maskOr == 0) {
      _lastScale = scale;
      _lastWq = wq;
      _lastHq = hq;
      return PoseParseOkPacked(
        kind: PacketKind.pd,
        w: wpx,
        h: hpx,
        positions: positions,
        ranges: ranges,
        hasZ: hasZ,
        zPositions: hasZ ? _viewZ(zBuf!, totalPts) : null,
        seq: seq,
        keyframe: false,
        ackSeq: seq,
      );
    }

    int ptr = i;

    for (int p = 0; p < nposes; p++) {
      final int npts = counts[p];
      _require(ptr + 2 <= b.length, 'PD(Δ) pose[$p] missing npts');
      final readNpts = _u16le(b, ptr);
      ptr += 2;
      _require(readNpts == npts, 'PD(Δ) pose[$p] inconsistent npts');

      final int maskBytes = (npts + 7) >> 3;
      _require(ptr + maskBytes <= b.length, 'PD(Δ) pose[$p] mask short');
      final int maskStart = ptr;
      ptr += maskBytes;

      final int start = cachedRanges[(p << 1)];
      int g = start;

      for (int mb = 0; mb < maskBytes; mb++) {
        int m = b[maskStart + mb];
        final int upto = (mb == maskBytes - 1) ? (npts - (mb << 3)) : 8;
        for (int bit = 0; bit < upto; bit++, g++) {
          if ((m & 1) != 0) {
            _require(ptr + 2 <= b.length, 'PD(Δ) pose[$p] dxdy short @pt $g');
            final int xyIndex = g << 1;
            int xq = baseXY[xyIndex] + _asInt8(b[ptr]);
            int yq = baseXY[xyIndex + 1] + _asInt8(b[ptr + 1]);
            ptr += 2;

            if (hasZ) {
              _require(ptr + 1 <= b.length, 'PD(Δ) pose[$p] dz short @pt $g');
              int zq = _baseZ![g] + _asInt8(b[ptr]);
              ptr += 1;
              zq = _clampZq(zq);
              _baseZ![g] = zq;
              zBuf![g] = zq / zScale;
            }

            xq = _clampQ(xq, wq);
            yq = _clampQ(yq, hq);

            baseXY[xyIndex] = xq;
            baseXY[xyIndex + 1] = yq;
            posBuf[xyIndex] = xq * invScale;
            posBuf[xyIndex + 1] = yq * invScale;
          }
          m >>= 1;
        }
      }
    }

    _lastRangesBuf = rangesBuf;
    _lastTotalPts = totalPts;
    _lastNposes = nposes;
    _lastScale = scale;
    _lastWq = wq;
    _lastHq = hq;

    return PoseParseOkPacked(
      kind: PacketKind.pd,
      w: wpx,
      h: hpx,
      positions: positions,
      ranges: ranges,
      hasZ: hasZ,
      zPositions: hasZ ? _viewZ(zBuf!, totalPts) : null,
      seq: seq,
      keyframe: false,
      ackSeq: seq,
    );
  }

  Float32List _ensurePositions(int needed, Float32List? reuse) {
    if (reuse != null && reuse.length >= needed) {
      return reuse;
    }
    final Float32List? current = _positions;
    if (current == null || current.length < needed) {
      final buf = Float32List(needed);
      _positions = buf;
      _positionsView = buf;
      _positionsViewLen = needed;
      return buf;
    }
    return current;
  }

  Float32List _viewPositions(Float32List data, int needed) {
    if (data.length == needed) {
      return data;
    }
    if (identical(data, _positions)) {
      if (_positionsView == null || _positionsViewLen != needed) {
        _positionsView = Float32List.view(data.buffer, data.offsetInBytes, needed);
        _positionsViewLen = needed;
      }
      return _positionsView!;
    }
    return Float32List.sublistView(data, 0, needed);
  }

  Int32List _ensureRanges(int needed, Int32List? reuse) {
    if (reuse != null && reuse.length >= needed) {
      return reuse;
    }
    final Int32List? current = _ranges;
    if (current == null || current.length < needed) {
      final buf = Int32List(needed);
      _ranges = buf;
      _rangesView = buf;
      _rangesViewLen = needed;
      return buf;
    }
    return current;
  }

  Int32List _viewRanges(Int32List data, int needed) {
    if (data.length == needed) {
      return data;
    }
    if (identical(data, _ranges)) {
      if (_rangesView == null || _rangesViewLen != needed) {
        _rangesView = Int32List.view(data.buffer, data.offsetInBytes, needed);
        _rangesViewLen = needed;
      }
      return _rangesView!;
    }
    return Int32List.sublistView(data, 0, needed);
  }

  Float32List _ensureZ(int needed, Float32List? reuse) {
    if (reuse != null && reuse.length >= needed) {
      return reuse;
    }
    final Float32List? current = _z;
    if (current == null || current.length < needed) {
      final buf = Float32List(needed);
      _z = buf;
      _zView = buf;
      _zViewLen = needed;
      return buf;
    }
    return current;
  }

  Float32List _viewZ(Float32List data, int needed) {
    if (data.length == needed) {
      return data;
    }
    if (identical(data, _z)) {
      if (_zView == null || _zViewLen != needed) {
        _zView = Float32List.view(data.buffer, data.offsetInBytes, needed);
        _zViewLen = needed;
      }
      return _zView!;
    }
    return Float32List.sublistView(data, 0, needed);
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