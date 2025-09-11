// lib/apps/guia_retrato/infrastructure/repository/posture_repository_imp.dart
import 'dart:async';
import 'dart:typed_data';
import '../../domain/repository/posture_repository.dart';
import '../../domain/service/pose_capture_service.dart';

class PostureRepositoryImp implements PostureRepository {
  final PoseCaptureService _webrtc;
  PostureRepositoryImp(this._webrtc);

  final _aliveCtrl = StreamController<bool>.broadcast();
  StreamSubscription? _sub;

  @override
  Future<void> start() async {
    await _webrtc.init();
    unawaited(_webrtc.connect());
    _sub ??= _webrtc.frames.listen((_) {
      _aliveCtrl.add(true);
    });
  }

  @override
  Future<void> stop() async {
    await _webrtc.dispose();
    await _sub?.cancel();
    _sub = null;
  }

  @override
  Stream<bool> onStreamAlive() => _aliveCtrl.stream;

  @override
  Future<void> processFrame(Uint8List frameBytes) async {
    // Si no tienes procesamiento local, deja vacío o elimina del contrato
  }
}
