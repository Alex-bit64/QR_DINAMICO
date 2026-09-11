import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

typedef SesionLocal = ({String idTienda, String sessionId});

class SesionLocalService {
  SesionLocalService({FlutterSecureStorage? secureStorage})
    : _secureStorage = secureStorage ?? const FlutterSecureStorage();

  static final SesionLocalService instance = SesionLocalService();

  static const _idTiendaKey = 'id_tienda';
  static const _sessionIdKey = 'tienda_session_id';

  final FlutterSecureStorage _secureStorage;

  Future<SesionLocal?> cargar() async {
    final prefs = await SharedPreferences.getInstance();
    final idTienda = prefs.getString(_idTiendaKey)?.trim() ?? '';
    var sessionId = (await _secureStorage.read(key: _sessionIdKey))?.trim();

    // Migración transparente desde las versiones que guardaban el identificador
    // de sesión en preferencias sin cifrar.
    if (sessionId == null || sessionId.isEmpty) {
      sessionId = prefs.getString(_sessionIdKey)?.trim();
      if (sessionId != null && sessionId.isNotEmpty) {
        await _secureStorage.write(key: _sessionIdKey, value: sessionId);
        await prefs.remove(_sessionIdKey);
      }
    }

    await prefs.remove('qr_token');

    if (idTienda.isEmpty || sessionId == null || sessionId.isEmpty) {
      await _secureStorage.delete(key: _sessionIdKey);
      await prefs.remove(_sessionIdKey);
      return null;
    }
    return (idTienda: idTienda, sessionId: sessionId);
  }

  Future<void> guardar({
    required String idTienda,
    required String sessionId,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_idTiendaKey, idTienda);
    await _secureStorage.write(key: _sessionIdKey, value: sessionId);
    await prefs.remove(_sessionIdKey);

    // Datos heredados que ya no se necesitan y el token QR que nunca debe
    // permanecer en almacenamiento local.
    await prefs.remove('nombre');
    await prefs.remove('direccion');
    await prefs.remove('correo');
    await prefs.remove('qr_token');
  }

  Future<void> limpiar() async {
    final prefs = await SharedPreferences.getInstance();
    await _secureStorage.delete(key: _sessionIdKey);
    await prefs.remove(_idTiendaKey);
    await prefs.remove(_sessionIdKey);
    await prefs.remove('nombre');
    await prefs.remove('direccion');
    await prefs.remove('correo');
    await prefs.remove('qr_token');
  }
}
