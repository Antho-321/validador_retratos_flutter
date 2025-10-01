// lib/apps/asistente_retratos/domain/model/face_recog_result.dart

class FaceRecogResult {
  const FaceRecogResult({
    required this.seq,
    required this.ts,
    this.cosSim,
    this.decision,
  });

  final double? cosSim;
  final String? decision;
  final int seq;
  final DateTime ts;
}
