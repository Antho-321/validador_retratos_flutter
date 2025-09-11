// lib/apps/asistente_retratos/presentation/widgets/frame_sequence_overlay.dart
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

/// How the sequence should play.
enum FramePlayMode { forward, reverse, pingPong }

class _AssetPatternRecipe {
  _AssetPatternRecipe({
    required this.directory,
    required this.pattern,
    required this.startNumber,
    required this.count,
    this.xStart,
    this.xEnd,
    required this.reverseOrder,
  });

  String directory;
  String pattern;
  int startNumber;
  int count;
  int? xStart;
  int? xEnd;
  bool reverseOrder;
}

class FrameSequenceController extends ChangeNotifier {
  FrameSequenceController({
    double fps = 30,
    this.playMode = FramePlayMode.forward,
    this.loop = true,
    this.autoplay = true,
  }) : _fps = fps.clamp(1.0, 120.0).toDouble();

  double get fps => _fps;
  set fps(double v) {
    final nv = v.clamp(1.0, 120.0).toDouble();
    if (_fps != nv) {
      _fps = nv;
      _restartClockIfPlaying();
    }
  }

  double _fps;
  FramePlayMode playMode;
  bool loop;
  bool autoplay;

  bool get isLoaded => _frames.isNotEmpty;
  bool get isPlaying => _timer != null;
  int get frameCount => _frames.length;
  int get currentIndex => _index;
  ui.Image? get currentFrame =>
      (0 <= _index && _index < _frames.length) ? _frames[_index] : null;

  final List<ui.Image> _frames = <ui.Image>[];
  final Stopwatch _clock = Stopwatch();
  Timer? _timer;
  int _index = 0;
  int _spanForPingPong = 0;
  int _loadGen = 0;

  int? _activeCount;
  int get _len => _activeCount ?? _frames.length;

  _AssetPatternRecipe? _assetRecipe;

  bool _reverseOrderFlag = false;
  bool get reverseOrder => _reverseOrderFlag;
  set reverseOrder(bool v) {
    if (v == _reverseOrderFlag) return;
    _reverseOrderFlag = v;
    if (_assetRecipe != null) _assetRecipe!.reverseOrder = v;

    if (_frames.isEmpty) return;

    final len = _len;
    _reverseFramesInPlace();
    _index = (len - 1 - _index).clamp(0, len - 1);
    notifyListeners();
  }

  int get count => _len;
  set count(int v) {
    if (v <= 0 || _frames.isEmpty) return;
    final max = _frames.length;
    final nv = v.clamp(1, max).toInt();
    final prev = _len;

    _activeCount = (nv == max) ? null : nv;
    _index = _index.clamp(0, _len - 1);
    _spanForPingPong = (_len > 1) ? (_len * 2 - 2) : 1;

    if (prev != _len) notifyListeners();
  }

  void useAllFrames() {
    if (_frames.isEmpty) return;
    _activeCount = null;
    _index = _index.clamp(0, _frames.length - 1);
    _spanForPingPong = (_frames.length > 1) ? (_frames.length * 2 - 2) : 1;
    notifyListeners();
  }

  Future<void> setCountAndReloadIfNeeded(int newCount) async {
    if (newCount <= 0) return;

    if (newCount <= _frames.length) {
      count = newCount;
      return;
    }

    final r = _assetRecipe;
    if (r != null) {
      await loadFromAssets(
        directory: r.directory,
        pattern: r.pattern,
        startNumber: r.startNumber,
        count: newCount,
        xStart: r.xStart,
        xEnd: r.xEnd,
        reverseOrder: r.reverseOrder,
      );
      return;
    }

    count = _frames.length;
  }

  Future<void> loadFromAssets({
    required String directory,
    required String pattern,
    required int startNumber,
    required int count,
    int? xStart,
    int? xEnd,
    bool reverseOrder = false,
  }) async {
    final bool wasPlaying = isPlaying;
    pause();

    _assetRecipe = _AssetPatternRecipe(
      directory: directory,
      pattern: pattern,
      startNumber: startNumber,
      count: count,
      xStart: xStart,
      xEnd: xEnd,
      reverseOrder: reverseOrder,
    );
    _reverseOrderFlag = reverseOrder;

    final int gen = ++_loadGen;
    await _disposeFrames();

    final paths = <String>[];
    if (!reverseOrder) {
      for (int i = 0; i < count; i++) {
        final n = startNumber + i;
        paths.add('$directory/${_formatPattern(pattern, n)}');
      }
    } else {
      for (int i = 0; i < count; i++) {
        final n = startNumber + (count - 1 - i);
        paths.add('$directory/${_formatPattern(pattern, n)}');
      }
    }

    await _decodeAssets(paths, xStart: xStart, xEnd: xEnd, expectGen: gen);
    if (gen != _loadGen) return;

    _afterLoad();
    if (wasPlaying || autoplay) play();
  }

  Future<void> loadAssets(List<String> assetPaths) async {
    final bool wasPlaying = isPlaying;
    pause();

    _assetRecipe = null;
    final int gen = ++_loadGen;
    await _disposeFrames();
    await _decodeAssets(assetPaths, expectGen: gen);
    if (gen != _loadGen) return;

    _afterLoad();
    if (wasPlaying || autoplay) play();
  }

  Future<void> loadFiles(List<String> filePaths) async {
    final bool wasPlaying = isPlaying;
    pause();

    _assetRecipe = null;
    final int gen = ++_loadGen;
    await _disposeFrames();
    for (final p in filePaths) {
      if (gen != _loadGen) return;

      final bd = await _readFileBytes(p);
      if (gen != _loadGen) return;

      final img = await _decodeBytes(bd);
      if (gen != _loadGen) return;

      _frames.add(img);
    }
    if (gen != _loadGen) return;

    _afterLoad();
    if (wasPlaying || autoplay) play();
  }

  void play() {
    if (!isLoaded || isPlaying) return;
    _startTicker();
  }

  void pause() {
    _timer?.cancel();
    _timer = null;
    _clock.stop();
  }

  void stop() {
    pause();
    _index = 0;
    notifyListeners();
  }

  void seekFrame(int i) {
    if (!isLoaded) return;
    _index = i.clamp(0, _len - 1).toInt();
    notifyListeners();
  }

  Size? get imageSize {
    final f = currentFrame;
    if (f == null) return null;
    return Size(f.width.toDouble(), f.height.toDouble());
  }

  @override
  void dispose() {
    pause();
    _disposeFrames();
    super.dispose();
  }

  void _afterLoad() {
    _index = 0;
    _activeCount = null;
    _spanForPingPong = (_len > 1) ? (_len * 2 - 2) : 1;

    if (isPlaying) {
      _restartClockIfPlaying();
    }

    notifyListeners();
  }

  Future<void> _decodeAssets(
    List<String> paths, {
    int? xStart,
    int? xEnd,
    int? expectGen,
  }) async {
    for (final p in paths) {
      if (expectGen != null && expectGen != _loadGen) return;

      final bd = await rootBundle.load(p);
      if (expectGen != null && expectGen != _loadGen) return;

      var img = await _decodeBytes(bd.buffer.asUint8List());
      if (expectGen != null && expectGen != _loadGen) return;

      if (xStart != null && xEnd != null) {
        int left = xStart;
        int right = xEnd;
        final w = img.width;

        left = left.clamp(0, w);
        right = right.clamp(0, w);
        if (right < left) {
          final t = left;
          left = right;
          right = t;
        }

        final cropW = right - left;
        if (cropW > 0 && (left != 0 || right != w)) {
          img = await _cropImageXRange(img, left, right);
        }
      }

      if (expectGen != null && expectGen != _loadGen) return;
      _frames.add(img);
    }
  }

  static Future<ui.Image> _decodeBytes(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final fi = await codec.getNextFrame();
    return fi.image;
  }

  static Future<ui.Image> _cropImageXRange(
    ui.Image src,
    int left,
    int right,
  ) async {
    final cropW = right - left;
    final h = src.height;
    if (cropW <= 0) return src;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final paint = Paint()..filterQuality = FilterQuality.high;

    final srcRect = Rect.fromLTWH(
      left.toDouble(),
      0,
      cropW.toDouble(),
      h.toDouble(),
    );
    final dstRect = Rect.fromLTWH(0, 0, cropW.toDouble(), h.toDouble());

    canvas.drawImageRect(src, srcRect, dstRect, paint);
    final picture = recorder.endRecording();
    final out = await picture.toImage(cropW, h);

    try {
      // ignore: invalid_use_of_protected_member
      src.dispose();
    } catch (_) {}

    return out;
  }

  Future<Uint8List> _readFileBytes(String absPath) async {
    final data = await rootBundle.load(absPath);
    return data.buffer.asUint8List();
  }

  Future<void> _disposeFrames() async {
    if (_frames.isEmpty) return;
    for (final f in _frames) {
      try {
        // ignore: invalid_use_of_protected_member
        f.dispose();
      } catch (_) {}
    }
    _frames.clear();
  }

  int? _phaseRaw;

  void _startTicker() {
    _clock.reset();
    _clock.start();
    _phaseRaw = null;

    _timer = Timer.periodic(const Duration(milliseconds: 8), (_) {
      if (!isLoaded) return;

      final len = _len;
      if (len <= 0) return;

      final elapsed = _clock.elapsedMicroseconds / 1e6;
      final raw = (elapsed * _fps).floor();

      _phaseRaw ??= raw;
      final stepped = raw - _phaseRaw!;

      int newIndex;

      switch (playMode) {
        case FramePlayMode.forward:
          if (loop) {
            newIndex = stepped % len;
          } else {
            newIndex = stepped.clamp(0, len - 1).toInt();
            if (newIndex == len - 1) pause();
          }
          break;
        case FramePlayMode.reverse:
          if (loop) {
            newIndex = len - 1 - (stepped % len);
          } else {
            newIndex = (len - 1 - stepped).clamp(0, len - 1).toInt();
            if (newIndex == 0) pause();
          }
          break;
        case FramePlayMode.pingPong:
          if (len == 1) {
            newIndex = 0;
          } else {
            final span = _spanForPingPong; // N*2-2
            final int r = loop ? (stepped % span) : stepped.clamp(0, span - 1).toInt();
            newIndex = (r < len) ? r : (span - r);
            if (!loop && r == span - 1) pause();
          }
          break;
      }

      if (newIndex != _index) {
        _index = newIndex;
        notifyListeners();
      }
    });
  }

  void _restartClockIfPlaying() {
    if (!isPlaying) return;
    pause();
    play();
  }

  void _reverseFramesInPlace() {
    final n = _frames.length;
    for (int i = 0; i < n ~/ 2; i++) {
      final j = n - 1 - i;
      final tmp = _frames[i];
      _frames[i] = _frames[j];
      _frames[j] = tmp;
    }
  }

  static String _formatPattern(String pattern, int number) {
    final re = RegExp(r'%0?(\d*)d');
    final m = re.firstMatch(pattern);
    if (m == null) return pattern;
    final padStr = m.group(1);
    final pad = (padStr == null || padStr.isEmpty) ? 0 : int.parse(padStr);
    final numStr = number.toString().padLeft(pad, '0');
    return pattern.replaceFirst(re, numStr);
  }
}

/// Painter-based overlay for the current frame.
/// Usa la paleta del Theme para el “tinte” cuando opacity < 1.0.
class FrameSequenceOverlay extends StatelessWidget {
  const FrameSequenceOverlay({
    super.key,
    required this.controller,
    this.mirror = false,
    this.fit = BoxFit.contain,
    this.opacity = 1.0,
    this.tintColor, // ⬅️ nuevo: color de paleta; si es null, usa onSurface del tema
  });

  final FrameSequenceController controller;
  final bool mirror;
  final BoxFit fit;
  final double opacity;
  final Color? tintColor;

  @override
  Widget build(BuildContext context) {
    // Obtenemos el color de la paleta desde el Theme si no se pasa uno explícito
    final scheme = Theme.of(context).colorScheme;
    final tint = tintColor ?? scheme.onSurface;

    return CustomPaint(
      painter: _FrameSequencePainter(
        controller,
        mirror: mirror,
        fit: fit,
        opacity: opacity,
        tintColor: tint,
      ),
      size: Size.infinite,
      isComplex: true,
      willChange: true,
    );
  }
}

class _FrameSequencePainter extends CustomPainter {
  _FrameSequencePainter(
    this.controller, {
    required this.mirror,
    required this.fit,
    required this.opacity,
    required this.tintColor,
  }) : super(repaint: controller);

  final FrameSequenceController controller;
  final bool mirror;
  final BoxFit fit;
  final double opacity;
  final Color tintColor;

  @override
  void paint(Canvas canvas, Size size) {
    final img = controller.currentFrame;
    if (img == null) return;

    final fw = img.width.toDouble();
    final fh = img.height.toDouble();
    if (fw <= 0 || fh <= 0) return;

    final scaleW = size.width / fw;
    final scaleH = size.height / fh;
    final s = (fit == BoxFit.cover)
        ? (scaleW > scaleH ? scaleW : scaleH)
        : (scaleW < scaleH ? scaleW : scaleH);

    final drawW = fw * s;
    final drawH = fh * s;
    final offX = (size.width - drawW) / 2.0;
    final offY = (size.height - drawH) / 2.0;

    canvas.save();
    if (mirror) {
      canvas.translate(size.width - offX, offY);
      canvas.scale(-s, s);
    } else {
      canvas.translate(offX, offY);
      canvas.scale(s, s);
    }

    final paint = Paint()..filterQuality = FilterQuality.high;

    // ⬇️ Usamos ColorFilter con BlendMode.modulate para aplicar opacidad y tinte del Theme.
    if (opacity < 1.0) {
      paint.colorFilter = ui.ColorFilter.mode(
        tintColor.withOpacity(opacity),
        BlendMode.modulate,
      );
    }

    final src = Rect.fromLTWH(0, 0, fw, fh);
    final dst = Rect.fromLTWH(0, 0, fw, fh);
    canvas.drawImageRect(img, src, dst, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _FrameSequencePainter oldDelegate) {
    return oldDelegate.mirror != mirror ||
           oldDelegate.fit != fit ||
           oldDelegate.opacity != opacity ||
           oldDelegate.tintColor != tintColor ||
           oldDelegate.controller != controller;
  }
}
