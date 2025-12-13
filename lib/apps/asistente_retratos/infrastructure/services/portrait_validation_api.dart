import 'dart:convert' show utf8;
import 'dart:typed_data';

import 'package:http/http.dart' as http;

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
    required Uint8List jpegBytes,
    required String cedula,
    required String nacionalidad,
    required String etnia,
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
            jpegBytes,
            filename: '$cedula.jpg',
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
}
