// lib/apps/asistente_retratos/presentation/widgets/frame_sequence_overlay.dart
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

/// How the sequence should play.
enum FramePlayMode { forward, reverse, pingPong }

/// Clave inmutable para identificar una "receta" de carga/corte/orden.
@immutable
class _RecipeKey {
  const _RecipeKey({
    required this.directory,
    required this.pattern,
    required this.startNumber,
    required this.count,
    required this.xStart,
    required this.xEnd,
    required this.reverseOrder,
  });

  final String directory;
  final String pattern;
  final int startNumber;
  final int count;
  final int? xStart;
  final int? xEnd;
  final bool reverseOrder;

  @override
  bool operator ==(Object other) {
    return other is _RecipeKey &&
        other.directory == directory &&
        other.pattern == pattern &&
        other.startNumber == startNumber &&
        other.count == count &&
        other.xStart == xStart &&
        other.xEnd == xEnd &&
        other.reverseOrder == reverseOrder;
  }

  @override
  int get hashCode => Object.hash(
        directory,
        pattern,
        startNumber,
        count,
        xStart,
        xEnd,
        reverseOrder,
      );
}

/// Entrada de caché: lista de frames decodificados/cortados.
/// Nota: No se hace refcount ni se dispone; se mantiene por la vida del proceso.
class _CacheEntry {
  _CacheEntry({required this.frames}) : loadedAt = DateTime.now();
  final List<ui.Image> frames;
  final DateTime loadedAt;
}

/// Caché global muy simple (lifetime del proceso).
/// - Clave: receta completa (incluye reverseOrder y count).
/// - Valor: frames ya decodificados y (si aplica) recortados.
/// Concurrency: si dos cargas piden la misma receta, la segunda espera a la
/// misma `Future` en _inflight.
class FrameSequenceCache {
  static final Map<_RecipeKey, _CacheEntry> _cache = <_RecipeKey, _CacheEntry>{};
  static final Map<_RecipeKey, Future<List<ui.Image>>> _inflight = <_RecipeKey, Future<List<ui.Image>>>{};

  static bool contains(_RecipeKey key) => _cache.containsKey(key);

  static List<ui.Image>? get(_RecipeKey key) => _cache[key]?.frames;

  static Future<List<ui.Image>> getOrLoad({
    required String directory,
    required String pattern,
    required int startNumber,
    required int count,
    int? xStart,
    int? xEnd,
    required bool reverseOrder,
  }) async {
    final key = _RecipeKey(
      directory: directory,
      pattern: pattern,
      startNumber: startNumber,
      count: count,
      xStart: xStart,
      xEnd: xEnd,
      reverseOrder: reverseOrder,
    );

    final cached = _cache[key];
    if (cached != null) return cached.frames;

    // Si ya hay una carga en progreso para esta receta, espera esa misma.
    final inflight = _inflight[key];
    if (inflight != null) return await inflight;

    // Inicia carga/decodificación + recorte
    final fut = _loadRecipe(key);
    _inflight[key] = fut;
    try {
      final frames = await fut;
      _cache[key] = _CacheEntry(frames: frames);
      return frames;
    } finally {
      _inflight.remove(key);
    }
  }

  static Future<List<ui.Image>> _loadRecipe(_RecipeKey key) async {
    // Construye la lista de rutas respetando reverseOrder y count.
    final List<String> paths = <String>[];
    if (!key.reverseOrder) {
      for (int i = 0; i < key.count; i++) {
        final n = key.startNumber + i;
        paths.add('${key.directory}/${FrameSequenceController._formatPattern(key.pattern, n)}');
      }
    } else {
      for (int i = 0; i < key.count; i++) {
        final n = key.startNumber + (key.count - 1 - i);
        paths.add('${key.directory}/${FrameSequenceController._formatPattern(key.pattern, n)}');
      }
    }

    final List<ui.Image> frames = <ui.Image>[];
    for (final p in paths) {
      final bd = await rootBundle.load(p);
      var img = await _decodeBytes(bd.buffer.asUint8List());
      if (key.xStart != null && key.xEnd != null) {
        int left = key.xStart!;
        int right = key.xEnd!;
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
      frames.add(img);
    }
    return frames;
  }

  // Helpers compartidos con el controlador (decodificación/corte)
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

  /// Limpieza manual (opcional). No se usa por defecto para evitar cold-starts.
  static Future<void> clear() async {
    // Si deseas liberar memoria, descomenta el dispose:
    // for (final e in _cache.values) {
    //   for (final img in e.frames) {
    //     try { img.dispose(); } catch (_) {}
    //   }
    // }
    _cache.clear();
  }
}

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

  /// Cuando los frames provienen del caché, el controlador **no** es dueño
  /// de esas imágenes y **no** debe disponerlas.
  bool _ownsFrames = true;

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

  /// Ahora con caché: primero intenta recuperar los frames de FrameSequenceCache.
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

    // Limpia frames actuales
    await _disposeFrames();

    // 1) Intenta obtener del caché
    List<ui.Image>? cached = FrameSequenceCache.get(_RecipeKey(
      directory: directory,
      pattern: pattern,
      startNumber: startNumber,
      count: count,
      xStart: xStart,
      xEnd: xEnd,
      reverseOrder: reverseOrder,
    ));

    if (cached == null) {
      // 2) No hay caché → cargar/decodificar y poblar caché
      cached = await FrameSequenceCache.getOrLoad(
        directory: directory,
        pattern: pattern,
        startNumber: startNumber,
        count: count,
        xStart: xStart,
        xEnd: xEnd,
        reverseOrder: reverseOrder,
      );
      if (gen != _loadGen) return;
    }

    // Copiamos las referencias a las imágenes del caché a _frames,
    // pero indicamos que NO somos dueños (no se deben disponer).
    _ownsFrames = false;
    _frames.addAll(cached);

    _afterLoad();
    if (wasPlaying || autoplay) play();
  }

  /// Carga directa de rutas de assets (sin caché). Mantengo por compatibilidad.
  Future<void> loadAssets(List<String> assetPaths) async {
    final bool wasPlaying = isPlaying;
    pause();

    _assetRecipe = null;
    final int gen = ++_loadGen;
    await _disposeFrames();

    // No caché aquí por ser rutas arbitrarias
    await _decodeAssets(assetPaths, expectGen: gen);
    if (gen != _loadGen) return;

    _afterLoad();
    if (wasPlaying || autoplay) play();
  }

  /// Carga desde archivos (sin caché).
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

    _ownsFrames = true; // somos dueños de estas imágenes
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

  // --------- Decodificación local (sin caché) para loadAssets -----------
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
    _ownsFrames = true; // estas imágenes sí son de este controlador
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
    // Si los frames vienen del caché, NO los disponemos.
    if (_ownsFrames) {
      for (final f in _frames) {
        try {
          // ignore: invalid_use_of_protected_member
          f.dispose();
        } catch (_) {}
      }
    }
    _frames.clear();
    _ownsFrames = true; // reset: por defecto asumimos propiedad
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
