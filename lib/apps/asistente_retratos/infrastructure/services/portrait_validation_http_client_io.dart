import 'dart:io' show HttpClient, X509Certificate;

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart' show IOClient;

http.Client createPortraitValidationHttpClient({
  required Uri endpoint,
  required bool allowInsecure,
}) {
  if (!allowInsecure || endpoint.scheme != 'https') {
    return http.Client();
  }

  final httpClient = HttpClient()
    ..badCertificateCallback =
        (X509Certificate cert, String host, int port) => host == endpoint.host;

  return IOClient(httpClient);
}

