import 'package:test/test.dart';

import 'package:validador_retratos_flutter/apps/asistente_retratos/infrastructure/webrtc/sdp_utils.dart';

void main() {
  group('patchAppMLinePorts', () {
    test('rewrites application m-line port zero to nine', () {
      const original = 'v=0\r\n'
          'o=- 1 1 IN IP4 127.0.0.1\r\n'
          's=-\r\n'
          't=0 0\r\n'
          'm=application 0 DTLS/SCTP 5000\r\n'
          'a=sctp-port:5000\r\n';

      final patched = patchAppMLinePorts(original);
      expect(patched, contains('m=application 9 DTLS/SCTP 5000'));
    });

    test('leaves non-zero application ports untouched', () {
      const original = 'v=0\r\n'
          'o=- 1 1 IN IP4 127.0.0.1\r\n'
          's=-\r\n'
          't=0 0\r\n'
          'm=application 9 DTLS/SCTP 5000\r\n'
          'a=sctp-port:5000\r\n';

      final patched = patchAppMLinePorts(original);
      expect(patched, equals(original));
    });
  });
}
