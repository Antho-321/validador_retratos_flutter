// lib/apps/asistente_retratos/infrastructure/parsers/face_recog_result_parser.dart

import 'dart:convert' show jsonDecode, utf8, base64, gzip, ZLibCodec;
import 'dart:typed_data';

class FaceRecogResult {
  const FaceRecogResult({
    this.cosineSimilarity,
    this.distance,
    this.score,
    this.decision,
    this.embedding,
    this.imageWidth,
    this.imageHeight,
    this.fromBinary = false,
  });

  final double? cosineSimilarity;
  final double? distance;
  final double? score;
  final String? decision;
  final Float32List? embedding;
  final int? imageWidth;
  final int? imageHeight;
  final bool fromBinary;

  int? get embeddingLength => embedding?.length;

  bool get hasPayload => cosineSimilarity != null || decision != null || embedding != null;
}

class FaceRecogResultParser {
  const FaceRecogResultParser();

  FaceRecogResult? parseText(String text) {
    final map = _parseTextToMap(text);
    if (map == null) return null;
    return _fromMap(map, fromBinary: false);
  }

  FaceRecogResult? parseBytes(Uint8List data) {
    final map = _decodeBinaryPayload(data);
    if (map != null) {
      return _fromMap(map, fromBinary: true);
    }
    final fallback = _fallbackEmbedding(data);
    return fallback;
  }

  // ── Text parsing ──────────────────────────────────────────────────────
  Map<String, dynamic>? _parseTextToMap(String text) {
    if (text.isEmpty) return null;
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;

    final candidates = <String>[trimmed];
    final lines = trimmed.split(RegExp(r'[\r\n]+'));
    for (final line in lines.reversed) {
      final candidate = line.trim();
      if (candidate.isNotEmpty && !candidates.contains(candidate)) {
        candidates.add(candidate);
      }
    }

    for (final cand in candidates) {
      final map = _tryDecodeJson(cand);
      if (map != null) return map;
    }

    for (final cand in candidates) {
      final map = _tryDecodePythonRepr(cand);
      if (map != null) return map;
    }

    return null;
  }

  Map<String, dynamic>? _tryDecodeJson(String text) {
    try {
      final decoded = jsonDecode(text);
      return _toNormalizedMap(decoded);
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic>? _tryDecodePythonRepr(String text) {
    final replacedKeys = text.replaceAllMapped(
      RegExp(r"([\\{\\[,]\\s*)'([^'\\s]+)'\\s*:"),
      (m) => '${m[1]}"${m[2]}":',
    );

    final replacedVals = replacedKeys.replaceAllMapped(
      RegExp(r":\\s*'([^']*)'"),
      (m) {
        final inner = m[1]!
            .replaceAll('\\\\', '\\\\')
            .replaceAll('"', '\\"');
        return ': "${inner}"';
      },
    );

    final normalized = replacedVals
        .replaceAll('None', 'null')
        .replaceAll('True', 'true')
        .replaceAll('False', 'false');

    if (normalized == text) return null;
    return _tryDecodeJson(normalized);
  }

  // ── Binary decoding ───────────────────────────────────────────────────
  Map<String, dynamic>? _decodeBinaryPayload(Uint8List data, {int depth = 0}) {
    if (data.isEmpty) return null;
    if (depth > 3) return null;

    if (data.length >= 2 && data[0] == 0x1F && data[1] == 0x8B) {
      try {
        final decoded = Uint8List.fromList(gzip.decode(data));
        final map = _decodeBinaryPayload(decoded, depth: depth + 1);
        if (map != null) return map;
      } catch (_) {}
    }

    try {
      final decoded = Uint8List.fromList(const ZLibCodec().decode(data));
      if (decoded.isNotEmpty && decoded.length != data.length) {
        final map = _decodeBinaryPayload(decoded, depth: depth + 1);
        if (map != null) return map;
      }
    } catch (_) {}

    try {
      final decoded = utf8.decode(data);
      final map = _parseTextToMap(decoded);
      if (map != null) return map;
    } catch (_) {}

    try {
      final decoded = utf8.decode(data, allowMalformed: true);
      final map = _parseTextToMap(decoded);
      if (map != null) return map;
    } catch (_) {}

    try {
      final reader = _MsgpackReader(data);
      final dynamic value = reader.read();
      final map = _toNormalizedMap(value);
      if (map != null) return map;
    } catch (_) {}

    try {
      final reader = _CborReader(data);
      final dynamic value = reader.read();
      final map = _toNormalizedMap(value);
      if (map != null) return map;
    } catch (_) {}

    return null;
  }

  FaceRecogResult? _fallbackEmbedding(Uint8List data) {
    if (data.length < 16) return null;
    if (data.length % 4 == 0) {
      final floats = Float32List(data.length ~/ 4);
      final byteData = ByteData.sublistView(data);
      for (int i = 0; i < floats.length; i++) {
        floats[i] = byteData.getFloat32(i * 4, Endian.little);
      }
      return FaceRecogResult(embedding: floats, fromBinary: true);
    }
    if (data.length % 8 == 0) {
      final doubles = Float64List.view(data.buffer, data.offsetInBytes, data.length ~/ 8);
      final floats = Float32List(doubles.length);
      for (int i = 0; i < doubles.length; i++) {
        floats[i] = doubles[i].toDouble();
      }
      return FaceRecogResult(embedding: floats, fromBinary: true);
    }
    return null;
  }

  // ── Helpers ───────────────────────────────────────────────────────────
  FaceRecogResult? _fromMap(Map<String, dynamic> raw, {required bool fromBinary}) {
    if (raw.isEmpty) return null;
    final normalized = _flatten(raw);

    final cos = _asDouble(normalized['cos_sim'] ??
        normalized['cosine_similarity'] ??
        normalized['cosine'] ??
        normalized['similarity'] ??
        normalized['match_score']);
    final score = _asDouble(normalized['score']);
    final distance = _asDouble(normalized['distance'] ?? normalized['dist']);
    final decision = _asString(normalized['decision'] ??
        normalized['status'] ??
        normalized['result'] ??
        normalized['match']);
    final emb = _parseEmbedding(normalized['embedding'] ??
        normalized['vector'] ??
        normalized['emb']);

    final dims = _parseImageSize(normalized['image_size'] ??
        normalized['imageSize'] ??
        normalized['size']);

    return FaceRecogResult(
      cosineSimilarity: cos,
      score: score,
      distance: distance,
      decision: decision,
      embedding: emb,
      imageWidth: dims?.$1,
      imageHeight: dims?.$2,
      fromBinary: fromBinary,
    );
  }

  Map<String, dynamic> _flatten(Map<String, dynamic> raw) {
    final out = <String, dynamic>{};

    void merge(Map<String, dynamic> src) {
      src.forEach((key, value) {
        out[key] = value;
        if (value is Map) {
          final lower = key.toLowerCase();
          if (lower == 'data' || lower == 'payload' || lower == 'result') {
            merge(_normalizeMap(value));
          }
        }
      });
    }

    merge(raw);
    return out;
  }

  Map<String, dynamic> _normalizeMap(Map<dynamic, dynamic> map) {
    final out = <String, dynamic>{};
    map.forEach((key, value) {
      if (key == null) return;
      out[key.toString()] = value;
    });
    return out;
  }

  Map<String, dynamic>? _toNormalizedMap(dynamic value) {
    if (value is Map) {
      return _normalizeMap(value);
    }
    if (value is List) {
      for (final element in value.reversed) {
        final map = _toNormalizedMap(element);
        if (map != null) return map;
      }
    }
    return null;
  }

  double? _asDouble(dynamic value) {
    if (value == null) return null;
    if (value is double) return value;
    if (value is int) return value.toDouble();
    if (value is num) return value.toDouble();
    if (value is String) {
      final trimmed = value.trim();
      if (trimmed.isEmpty) return null;
      return double.tryParse(trimmed);
    }
    return null;
  }

  int? _asInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) {
      final trimmed = value.trim();
      if (trimmed.isEmpty) return null;
      return int.tryParse(trimmed);
    }
    return null;
  }

  String? _asString(dynamic value) {
    if (value == null) return null;
    if (value is String) {
      final trimmed = value.trim();
      return trimmed.isEmpty ? null : trimmed;
    }
    return value.toString();
  }

  Float32List? _parseEmbedding(dynamic value) {
    if (value == null) return null;
    if (value is Float32List) return value;
    if (value is Float64List) {
      final floats = Float32List(value.length);
      for (int i = 0; i < value.length; i++) {
        floats[i] = value[i].toDouble();
      }
      return floats;
    }
    if (value is Uint8List) {
      if (value.isEmpty || value.length % 4 != 0) return null;
      final floats = Float32List(value.length ~/ 4);
      final view = ByteData.sublistView(value);
      for (int i = 0; i < floats.length; i++) {
        floats[i] = view.getFloat32(i * 4, Endian.little);
      }
      return floats;
    }
    if (value is List) {
      final floats = Float32List(value.length);
      for (int i = 0; i < value.length; i++) {
        final v = _asDouble(value[i]);
        floats[i] = v ?? 0.0;
      }
      return floats;
    }
    if (value is String) {
      final trimmed = value.trim();
      if (trimmed.isEmpty) return null;
      try {
        final bytes = base64.decode(trimmed);
        if (bytes.length % 4 == 0) {
          final floats = Float32List(bytes.length ~/ 4);
          final view = ByteData.sublistView(bytes);
          for (int i = 0; i < floats.length; i++) {
            floats[i] = view.getFloat32(i * 4, Endian.little);
          }
          return floats;
        }
      } catch (_) {
        final parts = trimmed.split(RegExp(r'[\s,]+'));
        final floats = Float32List(parts.length);
        for (int i = 0; i < parts.length; i++) {
          floats[i] = double.tryParse(parts[i]) ?? 0.0;
        }
        return floats;
      }
    }
    return null;
  }

  (int?, int?)? _parseImageSize(dynamic value) {
    if (value == null) return null;
    if (value is Map) {
      final norm = _normalizeMap(value);
      final w = _asInt(norm['w'] ?? norm['width'] ?? norm['cols']);
      final h = _asInt(norm['h'] ?? norm['height'] ?? norm['rows']);
      return (w, h);
    }
    if (value is List && value.length >= 2) {
      final w = _asInt(value[0]);
      final h = _asInt(value[1]);
      return (w, h);
    }
    if (value is String) {
      final parts = value.split(RegExp(r'[x, ]+'));
      if (parts.length >= 2) {
        final w = int.tryParse(parts[0]);
        final h = int.tryParse(parts[1]);
        return (w, h);
      }
    }
    return null;
  }
}

// ── Minimal MessagePack reader ──────────────────────────────────────────
class _MsgpackReader {
  _MsgpackReader(this.data);

  final Uint8List data;
  int _offset = 0;

  bool get _eof => _offset >= data.length;

  int _readByte() {
    if (_eof) {
      throw StateError('Unexpected EOF in msgpack stream');
    }
    return data[_offset++];
  }

  Uint8List _readBytes(int count) {
    if (_offset + count > data.length) {
      throw StateError('Buffer underflow');
    }
    final bytes = data.sublist(_offset, _offset + count);
    _offset += count;
    return Uint8List.fromList(bytes);
  }

  int _readUint(int bytes) {
    final bd = ByteData(bytes);
    for (int i = 0; i < bytes; i++) {
      bd.setUint8(i, _readByte());
    }
    return switch (bytes) {
      1 => bd.getUint8(0),
      2 => bd.getUint16(0, Endian.big),
      4 => bd.getUint32(0, Endian.big),
      8 => bd.getUint64(0, Endian.big),
      _ => 0,
    };
  }

  int _readInt(int bytes) {
    final bd = ByteData(bytes);
    for (int i = 0; i < bytes; i++) {
      bd.setUint8(i, _readByte());
    }
    return switch (bytes) {
      1 => bd.getInt8(0),
      2 => bd.getInt16(0, Endian.big),
      4 => bd.getInt32(0, Endian.big),
      8 => bd.getInt64(0, Endian.big),
      _ => 0,
    };
  }

  double _readFloat32() {
    final bd = ByteData(4);
    for (int i = 0; i < 4; i++) {
      bd.setUint8(i, _readByte());
    }
    return bd.getFloat32(0, Endian.big);
  }

  double _readFloat64() {
    final bd = ByteData(8);
    for (int i = 0; i < 8; i++) {
      bd.setUint8(i, _readByte());
    }
    return bd.getFloat64(0, Endian.big);
  }

  dynamic read() {
    final int byte = _readByte();

    if (byte <= 0x7F) return byte; // positive fixint
    if (byte >= 0xE0) return byte - 0x100; // negative fixint

    if (byte >= 0x80 && byte <= 0x8F) {
      final length = byte & 0x0F;
      return _readMap(length);
    }
    if (byte >= 0x90 && byte <= 0x9F) {
      final length = byte & 0x0F;
      return _readArray(length);
    }
    if (byte >= 0xA0 && byte <= 0xBF) {
      final length = byte & 0x1F;
      return utf8.decode(_readBytes(length), allowMalformed: true);
    }

    switch (byte) {
      case 0xC0:
        return null;
      case 0xC2:
        return false;
      case 0xC3:
        return true;
      case 0xC4:
        return _readBytes(_readByte());
      case 0xC5:
        return _readBytes(_readUint(2));
      case 0xC6:
        return _readBytes(_readUint(4));
      case 0xC7:
        return _readBytes(_readByte());
      case 0xC8:
        return _readBytes(_readUint(2));
      case 0xC9:
        return _readBytes(_readUint(4));
      case 0xCA:
        return _readFloat32();
      case 0xCB:
        return _readFloat64();
      case 0xCC:
        return _readUint(1);
      case 0xCD:
        return _readUint(2);
      case 0xCE:
        return _readUint(4);
      case 0xCF:
        return _readUint(8);
      case 0xD0:
        return _readInt(1);
      case 0xD1:
        return _readInt(2);
      case 0xD2:
        return _readInt(4);
      case 0xD3:
        return _readInt(8);
      case 0xD9:
        return utf8.decode(_readBytes(_readByte()), allowMalformed: true);
      case 0xDA:
        return utf8.decode(_readBytes(_readUint(2)), allowMalformed: true);
      case 0xDB:
        return utf8.decode(_readBytes(_readUint(4)), allowMalformed: true);
      case 0xDC:
        return _readArray(_readUint(2));
      case 0xDD:
        return _readArray(_readUint(4));
      case 0xDE:
        return _readMap(_readUint(2));
      case 0xDF:
        return _readMap(_readUint(4));
      default:
        throw StateError('Unsupported msgpack type: 0x${byte.toRadixString(16)}');
    }
  }

  List<dynamic> _readArray(int length) {
    final list = List<dynamic>.filled(length, null, growable: false);
    for (int i = 0; i < length; i++) {
      list[i] = read();
    }
    return list;
  }

  Map<String, dynamic> _readMap(int length) {
    final map = <String, dynamic>{};
    for (int i = 0; i < length; i++) {
      final key = read();
      final value = read();
      if (key == null) continue;
      map[key.toString()] = value;
    }
    return map;
  }
}

// ── Minimal CBOR reader ─────────────────────────────────────────────────
class _CborReader {
  _CborReader(this.data);

  final Uint8List data;
  int _offset = 0;

  bool get _eof => _offset >= data.length;

  int _readByte() {
    if (_eof) throw StateError('Unexpected EOF in CBOR stream');
    return data[_offset++];
  }

  int _readUint(int bytes) {
    int value = 0;
    for (int i = 0; i < bytes; i++) {
      value = (value << 8) | _readByte();
    }
    return value;
  }

  double _readFloat(int bytes) {
    final bd = ByteData(bytes);
    for (int i = 0; i < bytes; i++) {
      bd.setUint8(i, _readByte());
    }
    return bytes == 4
        ? bd.getFloat32(0, Endian.big)
        : bd.getFloat64(0, Endian.big);
  }

  dynamic read() {
    final int initial = _readByte();
    final int major = initial >> 5;
    final int minor = initial & 0x1F;

    switch (major) {
      case 0: // unsigned int
        return _readLength(minor);
      case 1: // negative int
        final value = _readLength(minor);
        return -1 - value;
      case 2: // byte string
        final length = _readLength(minor);
        return Uint8List.fromList(List<int>.generate(length, (_) => _readByte()));
      case 3: // text string
        final length = _readLength(minor);
        final bytes = List<int>.generate(length, (_) => _readByte());
        return utf8.decode(bytes, allowMalformed: true);
      case 4: // array
        final length = _readLength(minor);
        final list = List<dynamic>.filled(length, null, growable: false);
        for (int i = 0; i < length; i++) {
          list[i] = read();
        }
        return list;
      case 5: // map
        final length = _readLength(minor);
        final map = <String, dynamic>{};
        for (int i = 0; i < length; i++) {
          final key = read();
          final value = read();
          if (key == null) continue;
          map[key.toString()] = value;
        }
        return map;
      case 6: // tag — skip tag and read nested value
        _readLength(minor);
        return read();
      case 7:
        switch (minor) {
          case 20:
            return false;
          case 21:
            return true;
          case 22:
            return null;
          case 26:
            return _readFloat(4);
          case 27:
            return _readFloat(8);
          default:
            return null;
        }
      default:
        return null;
    }
  }

  int _readLength(int minor) {
    if (minor < 24) return minor;
    if (minor == 24) return _readByte();
    if (minor == 25) return _readUint(2);
    if (minor == 26) return _readUint(4);
    if (minor == 27) return _readUint(8);
    throw StateError('Unsupported CBOR length');
  }
}

