import 'package:flutter_test/flutter_test.dart';
import 'package:qr_dinamico/services/actualizacion_service.dart';

void main() {
  group('ActualizacionDisponible', () {
    test('acepta una versión con build superior y URL HTTPS', () {
      final hash = List.filled(64, 'a').join();
      final actualizacion = ActualizacionDisponible.desdeRespuesta({
        'disponible': true,
        'version_actual': '1.1.0',
        'build_actual': 2,
        'version_publicada': '1.2.0',
        'build_publicado': 3,
        'url_descarga': 'https://example.com/qr-sucursal.apk',
        'mensaje': 'Nueva versión',
        'sha256': hash,
      });

      expect(actualizacion, isNotNull);
      expect(actualizacion!.versionPublicada, '1.2.0');
      expect(actualizacion.buildPublicado, 3);
      expect(actualizacion.sha256, hash);
    });

    test('ignora respuestas sin una actualización real', () {
      final actualizacion = ActualizacionDisponible.desdeRespuesta({
        'disponible': true,
        'version_actual': '1.2.0',
        'build_actual': 3,
        'version_publicada': '1.2.0',
        'build_publicado': 3,
        'url_descarga': 'https://example.com/qr-sucursal.apk',
      });

      expect(actualizacion, isNull);
    });

    test('rechaza enlaces de descarga que no sean HTTPS', () {
      final actualizacion = ActualizacionDisponible.desdeRespuesta({
        'disponible': true,
        'version_actual': '1.1.0',
        'build_actual': 2,
        'version_publicada': '1.2.0',
        'build_publicado': 3,
        'url_descarga': 'http://example.com/qr-sucursal.apk',
      });

      expect(actualizacion, isNull);
    });
  });
}
