import 'dart:convert' show utf8;
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' show MediaType;

import 'portrait_validation_http_client.dart'
    show createPortraitValidationHttpClient;

class PortraitValidationApi {
  PortraitValidationApi({
    required this.endpoint,
    required this.allowInsecure,
    http.Client? client,
  }) : _client = client;

  final Uri endpoint;
  final bool allowInsecure;
  final http.Client? _client;

  Future<String> validarImagen({
    required Uint8List imageBytes,
    required String filename,
    required String cedula,
    required String nacionalidad,
    required String etnia,
    String? contentType,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final client = _client ??
        createPortraitValidationHttpClient(
          endpoint: endpoint,
          allowInsecure: allowInsecure,
        );

    try {
      final request = http.MultipartRequest('POST', endpoint)
        ..fields['cedula'] = cedula
        ..fields['nacionalidad'] = nacionalidad
        ..fields['etnia'] = etnia
        ..files.add(
          http.MultipartFile.fromBytes(
            'imagen',
            imageBytes,
            filename: filename,
            contentType:
                (contentType == null || contentType.trim().isEmpty)
                    ? null
                    : MediaType.parse(contentType.trim()),
          ),
        );

      final streamedResponse = await client.send(request).timeout(timeout);
      final response = await http.Response.fromStream(streamedResponse);
      final body = utf8.decode(response.bodyBytes);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('HTTP ${response.statusCode}: $body');
      }

      return body;
    } finally {
      if (_client == null) client.close();
    }
  }

  /// Calls /segmentar-imagen endpoint to segment a person from the background.
  /// Returns the segmented image bytes (JPEG with white background).
  Future<Uint8List> segmentarImagen({
    required Uint8List imageBytes,
    required String filename,
    String? contentType,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final client = _client ??
        createPortraitValidationHttpClient(
          endpoint: endpoint,
          allowInsecure: allowInsecure,
        );

    try {
      final request = http.MultipartRequest('POST', endpoint)
        ..files.add(
          http.MultipartFile.fromBytes(
            'imagen',
            imageBytes,
            filename: filename,
            contentType:
                (contentType == null || contentType.trim().isEmpty)
                    ? null
                    : MediaType.parse(contentType.trim()),
          ),
        );

      final streamedResponse = await client.send(request).timeout(timeout);
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        final body = utf8.decode(response.bodyBytes);
        throw Exception('HTTP ${response.statusCode}: $body');
      }

      // Return raw bytes (the segmented image)
      return response.bodyBytes;
    } finally {
      if (_client == null) client.close();
    }
  }

  /// Calls /procesar-imagen-segmentada endpoint to process a segmented image.
  /// Returns the processed image bytes (PNG).
  Future<Uint8List> procesarImagenSegmentada({
    required Uint8List imageBytes,
    required String filename,
    String? contentType,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final client = _client ??
        createPortraitValidationHttpClient(
          endpoint: endpoint,
          allowInsecure: allowInsecure,
        );

    // Adjust endpoint path
    final processingEndpoint = endpoint.replace(
      path: endpoint.path.replaceAll('segmentar-imagen', 'procesar-imagen-segmentada'),
    );

    try {
      final request = http.MultipartRequest('POST', processingEndpoint)
        ..files.add(
          http.MultipartFile.fromBytes(
            'imagen',
            imageBytes,
            filename: filename,
            contentType:
                (contentType == null || contentType.trim().isEmpty)
                    ? null
                    : MediaType.parse(contentType.trim()),
          ),
        );

      final streamedResponse = await client.send(request).timeout(timeout);
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        final body = utf8.decode(response.bodyBytes);
        throw Exception('HTTP ${response.statusCode}: $body');
      }

      // Return raw bytes (the processed image)
      return response.bodyBytes;
    } finally {
      if (_client == null) client.close();
    }
  }
}
