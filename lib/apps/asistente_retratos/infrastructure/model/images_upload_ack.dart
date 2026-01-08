class ImagesUploadAck {
  final String requestId;
  final bool? uploadOk;
  final String? status;
  final String? photoId;
  final String? error;
  final Map<String, dynamic>? validationResult;

  const ImagesUploadAck({
    required this.requestId,
    this.uploadOk,
    this.status,
    this.photoId,
    this.error,
    this.validationResult,
  });

  @override
  String toString() =>
      'ImagesUploadAck(requestId=$requestId, uploadOk=$uploadOk, status=$status, photoId=$photoId, error=$error, validationResult=$validationResult)';
}
