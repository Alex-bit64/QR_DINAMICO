import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_dinamico/services/sesion_local_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('guarda la sesión sin dejar el session id en preferencias', () async {
    final service = SesionLocalService();

    await service.guardar(
      idTienda: 'f3d00f32-a22d-4477-b561-e81fb0a82756',
      sessionId: '0123456789abcdef0123456789abcdef',
    );

    final sesion = await service.cargar();
    final prefs = await SharedPreferences.getInstance();
    expect(sesion?.idTienda, 'f3d00f32-a22d-4477-b561-e81fb0a82756');
    expect(sesion?.sessionId, '0123456789abcdef0123456789abcdef');
    expect(prefs.getString('tienda_session_id'), isNull);
    expect(prefs.getString('qr_token'), isNull);
  });

  test('migra una sesión heredada al almacenamiento seguro', () async {
    SharedPreferences.setMockInitialValues({
      'id_tienda': 'f3d00f32-a22d-4477-b561-e81fb0a82756',
      'tienda_session_id': 'abcdef0123456789abcdef0123456789',
      'qr_token': 'no-debe-conservarse',
    });
    final service = SesionLocalService();

    final sesion = await service.cargar();
    final prefs = await SharedPreferences.getInstance();
    const secureStorage = FlutterSecureStorage();
    expect(sesion?.sessionId, 'abcdef0123456789abcdef0123456789');
    expect(prefs.getString('tienda_session_id'), isNull);
    expect(
      await secureStorage.read(key: 'tienda_session_id'),
      'abcdef0123456789abcdef0123456789',
    );
  });

  test('limpiar elimina tanto la sesión nueva como la heredada', () async {
    final service = SesionLocalService();
    await service.guardar(
      idTienda: 'f3d00f32-a22d-4477-b561-e81fb0a82756',
      sessionId: '0123456789abcdef0123456789abcdef',
    );

    await service.limpiar();

    expect(await service.cargar(), isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('id_tienda'), isNull);
    expect(prefs.getString('tienda_session_id'), isNull);
  });
}
