class ImagesUploadAck {
  final String requestId;
  final bool? uploadOk;
  final String? status;
  final String? photoId;
  final String? error;

  const ImagesUploadAck({
    required this.requestId,
    this.uploadOk,
    this.status,
    this.photoId,
    this.error,
  });

  @override
  String toString() =>
      'ImagesUploadAck(requestId=$requestId, uploadOk=$uploadOk, status=$status, photoId=$photoId, error=$error)';
}
