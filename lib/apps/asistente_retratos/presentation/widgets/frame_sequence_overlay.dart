// lib/apps/asistente_retratos/presentation/widgets/frame_sequence_overlay.dart
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

/// How the sequence should play.
enum FramePlayMode { forward, reverse, pingPong }

/// Stores the last asset-loading "recipe" so we can reload with a new count.
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

/// Controller that owns the decoded frames, timing, and play state.
class FrameSequenceController extends ChangeNotifier {
  FrameSequenceController({
    double fps = 30,
    this.playMode = FramePlayMode.forward,
    this.loop = true,
    this.autoplay = true,
  }) : _fps = fps.clamp(1.0, 120.0).toDouble();

  // ── Playback config ───────────────────────────────────────────────────
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

  // ── State ─────────────────────────────────────────────────────────────
  bool get isLoaded => _frames.isNotEmpty;
  bool get isPlaying => _timer != null;
  int get frameCount => _frames.length; // total loaded
  int get currentIndex => _index;
  ui.Image? get currentFrame =>
      (0 <= _index && _index < _frames.length) ? _frames[_index] : null;

  // ── Internals ─────────────────────────────────────────────────────────
  final List<ui.Image> _frames = <ui.Image>[];
  final Stopwatch _clock = Stopwatch();
  Timer? _timer;
  int _index = 0;
  int _spanForPingPong = 0; // = N*2-2 when N>1
  int _loadGen = 0; // generation token to cancel overlapping loads

  // Dynamic playback window (for "count" at runtime)
  int? _activeCount; // null = use all loaded frames
  int get _len => _activeCount ?? _frames.length;

  // Last asset recipe (enables reload with larger count)
  _AssetPatternRecipe? _assetRecipe;

  // Track and control the "reverseOrder" behavior at runtime.
  bool _reverseOrderFlag = false;
  bool get reverseOrder => _reverseOrderFlag;
  set reverseOrder(bool v) {
    if (v == _reverseOrderFlag) return;
    _reverseOrderFlag = v;
    // Keep recipe in sync for future reloads
    if (_assetRecipe != null) _assetRecipe!.reverseOrder = v;

    // If not loaded yet, nothing to reverse right now.
    if (_frames.isEmpty) return;

    // Reverse the in-memory frames. Preserve the *visible* frame by mirroring index.
    final len = _len;
    _reverseFramesInPlace();
    _index = (len - 1 - _index).clamp(0, len - 1);
    // PingPong span depends only on len; unchanged.
    notifyListeners();
  }

  /// Public runtime "count" (playback window). Shrinks/grows up to what's loaded.
  /// To grow beyond what's loaded, call `setCountAndReloadIfNeeded(...)`.
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

  /// Reset to use all loaded frames.
  void useAllFrames() {
    if (_frames.isEmpty) return;
    _activeCount = null;
    _index = _index.clamp(0, _frames.length - 1);
    _spanForPingPong = (_frames.length > 1) ? (_frames.length * 2 - 2) : 1;
    notifyListeners();
  }

  /// If you ask for more frames than are currently loaded, this will reload
  /// using the last asset recipe (if available). Otherwise, it just clamps.
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

    // Fallback: no recipe to reload from; just use what's available.
    count = _frames.length;
  }

  // ── Loaders ───────────────────────────────────────────────────────────
  /// Load frames from assets using a printf-like pattern, e.g.:
  /// directory: 'assets/frames', pattern: 'frame_%04d.png',
  /// startNumber: 14, count: 17  -> frame_0014.png .. frame_0030.png
  ///
  /// Optional [xStart] (inclusive) and [xEnd] (exclusive) define a vertical
  /// strip to crop from each decoded frame. If omitted, the full width is used.
  ///
  /// If [reverseOrder] is true, frames are loaded from last to first
  /// (e.g., 0030, 0029, …, 0014).
  Future<void> loadFromAssets({
    required String directory,
    required String pattern,
    required int startNumber,
    required int count,
    int? xStart, // inclusive
    int? xEnd, // exclusive
    bool reverseOrder = false,
  }) async {
    // Pause ticker to avoid start-of-animation jumps.
    final bool wasPlaying = isPlaying;
    pause();

    // Save the recipe so we can reload with a different count later.
    _assetRecipe = _AssetPatternRecipe(
      directory: directory,
      pattern: pattern,
      startNumber: startNumber,
      count: count,
      xStart: xStart,
      xEnd: xEnd,
      reverseOrder: reverseOrder,
    );
    // Also sync the runtime flag so the setter reflects current load state.
    _reverseOrderFlag = reverseOrder;

    final int gen = ++_loadGen; // bump generation
    await _disposeFrames();

    final paths = <String>[];
    if (!reverseOrder) {
      // Normal order: startNumber .. startNumber + count - 1
      for (int i = 0; i < count; i++) {
        final n = startNumber + i;
        paths.add('$directory/${_formatPattern(pattern, n)}');
      }
    } else {
      // Reversed order: startNumber + count - 1 down to startNumber
      for (int i = 0; i < count; i++) {
        final n = startNumber + (count - 1 - i);
        paths.add('$directory/${_formatPattern(pattern, n)}');
      }
    }

    await _decodeAssets(paths, xStart: xStart, xEnd: xEnd, expectGen: gen);
    if (gen != _loadGen) return; // a newer load started; drop this result

    _afterLoad();

    // Clean restart: honor prior playing state or autoplay.
    if (wasPlaying || autoplay) play();
  }

  /// Load frames from explicit asset paths (already ordered).
  Future<void> loadAssets(List<String> assetPaths) async {
    final bool wasPlaying = isPlaying;
    pause();

    _assetRecipe = null; // unknown recipe; cannot expand later automatically
    final int gen = ++_loadGen;
    await _disposeFrames();
    await _decodeAssets(assetPaths, expectGen: gen);
    if (gen != _loadGen) return;

    _afterLoad();
    if (wasPlaying || autoplay) play();
  }

  /// Load frames from absolute file paths (e.g., temp dir); ordered list.
  Future<void> loadFiles(List<String> filePaths) async {
    final bool wasPlaying = isPlaying;
    pause();

    _assetRecipe = null; // unknown recipe; cannot expand later automatically
    final int gen = ++_loadGen;
    await _disposeFrames();
    for (final p in filePaths) {
      // Abort mid-loop if a newer load started
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

  // ── Controls ──────────────────────────────────────────────────────────
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

  // ── Overlay helpers ───────────────────────────────────────────────────
  Size? get imageSize {
    final f = currentFrame;
    if (f == null) return null;
    return Size(f.width.toDouble(), f.height.toDouble());
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────
  @override
  void dispose() {
    pause();
    _disposeFrames();
    super.dispose();
  }

  // ── Private helpers ───────────────────────────────────────────────────
  void _afterLoad() {
    _index = 0;
    _activeCount = null; // default to using all newly loaded frames
    _spanForPingPong = (_len > 1) ? (_len * 2 - 2) : 1;

    // If someone swapped frames without pausing, defensively reset the clock.
    if (isPlaying) {
      _restartClockIfPlaying();
    }

    notifyListeners();
    // Note: start (play) is handled by loaders to respect wasPlaying/autoplay.
  }

  Future<void> _decodeAssets(
    List<String> paths, {
    int? xStart,
    int? xEnd,
    int? expectGen, // abort if generation changes mid-decode
  }) async {
    for (final p in paths) {
      if (expectGen != null && expectGen != _loadGen) return;

      final bd = await rootBundle.load(p);
      if (expectGen != null && expectGen != _loadGen) return;

      var img = await _decodeBytes(bd.buffer.asUint8List());
      if (expectGen != null && expectGen != _loadGen) return;

      // Crop horizontally to [xStart, xEnd) if provided
      if (xStart != null && xEnd != null) {
        int left = xStart;
        int right = xEnd; // exclusive
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

  /// Crop a [src] image to the vertical strip [left, right) across full height.
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

    // Free original if not reused elsewhere.
    try {
      // ignore: invalid_use_of_protected_member
      src.dispose();
    } catch (_) {}

    return out;
  }

  Future<Uint8List> _readFileBytes(String absPath) async {
    // Minimal file read without dart:io import exposure here:
    // (You can replace with File(absPath).readAsBytes() if allowed in your target.)
    final data = await rootBundle.load(absPath); // treat as asset-like; adjust if needed
    return data.buffer.asUint8List();
  }

  Future<void> _disposeFrames() async {
    if (_frames.isEmpty) return;
    for (final f in _frames) {
      // ui.Image has dispose() on recent SDKs; guard for older.
      try {
        // ignore: invalid_use_of_protected_member
        f.dispose();
      } catch (_) {}
    }
    _frames.clear();
  }

  // Phase offset so first computed index is 0 even if clock wasn't reset.
  int? _phaseRaw; // null => not captured yet

  void _startTicker() {
    _clock.reset();
    _clock.start();
    _phaseRaw = null; // capture on first tick

    // Drive at ~120Hz (fast enough to match any fps up to 120).
    _timer = Timer.periodic(const Duration(milliseconds: 8), (_) {
      if (!isLoaded) return;

      final len = _len;
      if (len <= 0) return;

      final elapsed = _clock.elapsedMicroseconds / 1e6; // seconds
      final raw = (elapsed * _fps).floor();             // logical frame count since start

      // Capture phase on first usable tick
      _phaseRaw ??= raw;
      final stepped = raw - _phaseRaw!; // starts at 0

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
            final span = _spanForPingPong; // N*2-2 for current active window
            final int r = loop ? (stepped % span) : stepped.clamp(0, span - 1).toInt();
            newIndex = (r < len) ? r : (span - r); // bounce back
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
    // Restart to avoid big jumps when FPS or sequence changes.
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

  // Supports patterns like "frame_%04d.png" or "img_%d.png"
  static String _formatPattern(String pattern, int number) {
    final re = RegExp(r'%0?(\d*)d');
    final m = re.firstMatch(pattern);
    if (m == null) return pattern; // no placeholder; unlikely
    final padStr = m.group(1);
    final pad = (padStr == null || padStr.isEmpty) ? 0 : int.parse(padStr);
    final numStr = number.toString().padLeft(pad, '0');
    return pattern.replaceFirst(re, numStr);
  }
}

/// The painter-based overlay that draws the *current* frame with fit & mirror.
class FrameSequenceOverlay extends StatelessWidget {
  const FrameSequenceOverlay({
    super.key,
    required this.controller,
    this.mirror = false,
    this.fit = BoxFit.contain,
    this.opacity = 1.0,
  });

  final FrameSequenceController controller;
  final bool mirror;
  final BoxFit fit;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _FrameSequencePainter(
        controller,
        mirror: mirror,
        fit: fit,
        opacity: opacity,
      ),
      size: Size.infinite,
      isComplex: true,
      willChange: true,
    );
    // Note: if you intend to change mirror/fit/opacity while paused,
    // consider updating shouldRepaint in the painter.
  }
}

class _FrameSequencePainter extends CustomPainter {
  _FrameSequencePainter(
    this.controller, {
    required this.mirror,
    required this.fit,
    required this.opacity,
  }) : super(repaint: controller);

  final FrameSequenceController controller;
  final bool mirror;
  final BoxFit fit;
  final double opacity;

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
    if (opacity < 1.0) paint.color = Colors.white.withOpacity(opacity);

    // Draw entire source into the destination box (already scaled via canvas).
    final src = Rect.fromLTWH(0, 0, fw, fh);
    final dst = Rect.fromLTWH(0, 0, fw, fh);
    canvas.drawImageRect(img, src, dst, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _FrameSequencePainter oldDelegate) => false;
}
