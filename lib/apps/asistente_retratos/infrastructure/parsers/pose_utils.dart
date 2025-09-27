// lib/apps/asistente_retratos/infrastructure/parsers/pose_utils.dart
import 'dart:typed_data';
import 'dart:ui' show Offset;

import '../model/pose_point.dart';

typedef F32 = Float32List;

/// Convierte listas planas [x0,y0,x1,y1,...] a listas de Offsets.
List<List<Offset>> toOffsets2D(List<F32> flats) => flats
    .map((f) => List<Offset>.generate(
          f.length >> 1,
          (i) => Offset(f[i << 1], f[(i << 1) + 1]),
          growable: false,
        ))
    .toList(growable: false);

/// Extrae landmarks de caras desde JSON (posiblemente normalizados) a Float32List.
List<F32> faces2DFromJson(List<dynamic> faces, int w, int h) {
  final out = <F32>[];
  for (final face in faces) {
    final lmk = face as List<dynamic>;
    final f = F32(lmk.length * 2);
    for (var i = 0; i < lmk.length; i++) {
      final pt = lmk[i] as Map<String, dynamic>;
      final x = (pt['x'] as num).toDouble();
      final y = (pt['y'] as num).toDouble();
      final nrm = (x >= 0 && x <= 1.2 && y >= 0 && y <= 1.2);
      f[i << 1] = nrm ? (x * w) : x;
      f[(i << 1) + 1] = nrm ? (y * h) : y;
    }
    out.add(f);
  }
  return out;
}

/// Crea PosePoint 2D/3D a partir de listas planas XY y opcional Z.
List<List<PosePoint>> mkPose3D(List<F32> xy, [List<F32>? z]) {
  final out = <List<PosePoint>>[];
  for (var i = 0; i < xy.length; i++) {
    final f = xy[i];
    final n = f.length >> 1;
    final zf = (z != null && i < z.length) ? z[i] : null;
    out.add(List<PosePoint>.generate(
      n,
      (j) => PosePoint(
        x: f[j << 1],
        y: f[(j << 1) + 1],
        z: (zf != null && j < zf.length) ? zf[j] : null,
      ),
      growable: false,
    ));
  }
  return out;
}

/// Crea PosePoint desde buffers empaquetados.
List<List<PosePoint>> mkPose3DFromPacked(
  Float32List positions,
  Int32List ranges, [
  Float32List? zPositions,
]) {
  final out = <List<PosePoint>>[];
  for (int i = 0; i + 1 < ranges.length; i += 2) {
    final int startPt = ranges[i];
    final int countPt = ranges[i + 1];
    final int startF = startPt << 1; // *2
    final int endF = startF + (countPt << 1);
    out.add(List<PosePoint>.generate(countPt, (j) {
      final int idx = startF + (j << 1);
      final double x = positions[idx];
      final double y = positions[idx + 1];
      double? z;
      if (zPositions != null) {
        final int zIdx = startPt + j;
        if (zIdx < zPositions.length) {
          z = zPositions[zIdx];
        }
      }
      return PosePoint(x: x, y: y, z: z);
    }, growable: false));
  }
  return out;
}
