import 'package:http/http.dart' as http;

http.Client createPortraitValidationHttpClient({
  required Uri endpoint,
  required bool allowInsecure,
}) {
  return http.Client();
}

