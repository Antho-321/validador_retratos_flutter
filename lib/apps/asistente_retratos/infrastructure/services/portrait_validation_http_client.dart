import 'package:http/http.dart' as http;

import 'portrait_validation_http_client_stub.dart'
    if (dart.library.io) 'portrait_validation_http_client_io.dart' as impl;

http.Client createPortraitValidationHttpClient({
  required Uri endpoint,
  required bool allowInsecure,
}) {
  return impl.createPortraitValidationHttpClient(
    endpoint: endpoint,
    allowInsecure: allowInsecure,
  );
}

