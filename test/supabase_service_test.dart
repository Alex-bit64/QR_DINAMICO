import 'package:flutter_test/flutter_test.dart';
import 'package:qr_dinamico/services/supabase_service.dart';

void main() {
  group('generarPayloadQrDinamico', () {
    final servicio = SupabaseService.instance;
    const token = 'token-de-prueba';

    test('mantiene el mismo payload dentro del intervalo de 30 segundos', () {
      final inicio = DateTime.utc(2026, 7, 22, 12);
      final primero = servicio.generarPayloadQrDinamico(
        token: token,
        fechaHora: inicio,
      );
      final segundo = servicio.generarPayloadQrDinamico(
        token: token,
        fechaHora: inicio.add(const Duration(seconds: 29)),
      );

      expect(segundo, primero);
      expect(primero, startsWith('app-qr-dinamico://'));
    });

    test('genera un payload nuevo al cambiar de intervalo', () {
      final inicio = DateTime.utc(2026, 7, 22, 12);
      final primero = servicio.generarPayloadQrDinamico(
        token: token,
        fechaHora: inicio,
      );
      final siguiente = servicio.generarPayloadQrDinamico(
        token: token,
        fechaHora: inicio.add(const Duration(seconds: 30)),
      );

      expect(siguiente, isNot(primero));
    });
  });
}
