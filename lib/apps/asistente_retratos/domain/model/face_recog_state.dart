// lib/apps/asistente_retratos/domain/model/face_recog_state.dart

class FaceRecogState {
  const FaceRecogState({
    this.cosineSimilarity,
    this.distance,
    this.decision,
    this.embeddingLength,
    this.rawScore,
    this.imageWidth,
    this.imageHeight,
    this.updatedAt,
    this.fromBinary = false,
  });

  final double? cosineSimilarity;
  final double? distance;
  final double? rawScore;
  final String? decision;
  final int? embeddingLength;
  final int? imageWidth;
  final int? imageHeight;
  final DateTime? updatedAt;
  final bool fromBinary;

  static const FaceRecogState empty = FaceRecogState();

  FaceRecogState copyWith({
    double? cosineSimilarity,
    double? distance,
    double? rawScore,
    String? decision,
    int? embeddingLength,
    int? imageWidth,
    int? imageHeight,
    DateTime? updatedAt,
    bool? fromBinary,
  }) {
    return FaceRecogState(
      cosineSimilarity: cosineSimilarity ?? this.cosineSimilarity,
      distance: distance ?? this.distance,
      rawScore: rawScore ?? this.rawScore,
      decision: decision ?? this.decision,
      embeddingLength: embeddingLength ?? this.embeddingLength,
      imageWidth: imageWidth ?? this.imageWidth,
      imageHeight: imageHeight ?? this.imageHeight,
      updatedAt: updatedAt ?? this.updatedAt,
      fromBinary: fromBinary ?? this.fromBinary,
    );
  }

  /// Decision normalized to upper-case (MATCH/NO_MATCH/UNKNOWN...).
  String? get normalizedDecision {
    final value = decision?.trim();
    if (value == null || value.isEmpty) return null;
    return value.toUpperCase();
  }

  bool get hasScore => cosineSimilarity != null || rawScore != null;

  double? get primaryScore => cosineSimilarity ?? rawScore;

  bool get isMatch => normalizedDecision == 'MATCH';

  bool get isNoMatch {
    const failures = {'NO_MATCH', 'MISMATCH', 'FAIL', 'FAILURE'};
    final nd = normalizedDecision;
    if (nd == null) return false;
    return failures.contains(nd);
  }

  bool isFresh([Duration ttl = const Duration(milliseconds: 1500)]) {
    final ts = updatedAt;
    if (ts == null) return false;
    return DateTime.now().difference(ts) <= ttl;
  }
}

