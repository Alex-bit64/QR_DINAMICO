import 'package:supabase_flutter/supabase_flutter.dart';

import 'informacion_aplicacion_service.dart';

class SupabaseService {
  SupabaseService._();

  static final SupabaseService instance = SupabaseService._();

  final _informacionAplicacionService = InformacionAplicacionService.instance;
  bool? _rpcVersionSesionDisponible;

  SupabaseClient get _client => Supabase.instance.client;

  /// Autentica y toma la sesión de la tienda en una única operación atómica.
  ///
  /// El fallback mantiene operativa la app mientras se despliega la migración
  /// nueva. Después del despliegue, los RPC heredados quedan sin permiso para
  /// clientes anónimos y solo se utiliza la ruta segura.
  Future<Map<String, dynamic>> iniciarSesionTiendaSegura({
    required String correo,
    required String contrasena,
    required String sessionId,
    required String dispositivo,
    required double latitud,
    required double longitud,
    required double precisionMetros,
  }) async {
    final informacion = await _obtenerInformacionSegura(dispositivo);

    if (_rpcVersionSesionDisponible == false) {
      return _iniciarSesionTiendaSeguraCompatible(
        correo: correo,
        contrasena: contrasena,
        sessionId: sessionId,
        dispositivo: dispositivo,
        latitud: latitud,
        longitud: longitud,
        precisionMetros: precisionMetros,
      );
    }

    try {
      final data = await _rpcMaybeSingle(
        'iniciar_sesion_tienda_segura',
        params: {
          'p_correo': correo.trim().toLowerCase(),
          'p_contrasena': contrasena,
          'p_session_id': sessionId,
          'p_dispositivo': dispositivo,
          'p_latitud': latitud,
          'p_longitud': longitud,
          'p_precision_metros': precisionMetros,
          'p_version_aplicacion': informacion.version,
          'p_build_aplicacion': informacion.build,
        },
      );
      if (data == null) {
        throw Exception('Supabase no devolvió el resultado del inicio.');
      }
      _rpcVersionSesionDisponible = true;
      return data;
    } on PostgrestException catch (error) {
      if (!_esFuncionNoDisponible(error, 'iniciar_sesion_tienda_segura')) {
        rethrow;
      }

      _rpcVersionSesionDisponible = false;
      return _iniciarSesionTiendaSeguraCompatible(
        correo: correo,
        contrasena: contrasena,
        sessionId: sessionId,
        dispositivo: dispositivo,
        latitud: latitud,
        longitud: longitud,
        precisionMetros: precisionMetros,
      );
    }
  }

  /// Consulta la versión publicada para la plataforma actual.
  ///
  /// Devuelve `null` cuando todavía no se ha publicado una fila activa.
  Future<Map<String, dynamic>?> obtenerActualizacionAplicacion({
    required String plataforma,
    required String versionActual,
    required int buildActual,
  }) {
    return _rpcMaybeSingle(
      'obtener_actualizacion_aplicacion',
      params: {
        'p_plataforma': plataforma,
        'p_version_actual': versionActual,
        'p_build_actual': buildActual,
      },
    );
  }

  /// Recupera los datos de la tienda únicamente si la sesión sigue activa.
  Future<Map<String, dynamic>?> obtenerTiendaSesion({
    required String idTienda,
    required String sessionId,
  }) async {
    try {
      final data = await _rpcMaybeSingle(
        'obtener_sesion_tienda',
        params: {'p_id_tienda': idTienda, 'p_session_id': sessionId},
      );
      return data == null ? null : _mapearTienda(data);
    } on PostgrestException catch (error) {
      if (!_esFuncionNoDisponible(error, 'obtener_sesion_tienda')) {
        rethrow;
      }

      final validacion = await validarSesionTienda(
        idTienda: idTienda,
        sessionId: sessionId,
      );
      if (validacion['permitido'] != true) return null;

      final data = await _rpcMaybeSingle(
        'obtener_tienda_por_id',
        params: {'p_id_tienda': idTienda},
      );
      return data == null ? null : _mapearTienda(data);
    }
  }

  Future<Map<String, dynamic>> obtenerPayloadQrTienda({
    required String idTienda,
    required String sessionId,
  }) async {
    final data = await _rpcMaybeSingle(
      'obtener_payload_qr_tienda',
      params: {'p_id_tienda': idTienda, 'p_session_id': sessionId},
    );

    final payload = data?['payload']?.toString().trim() ?? '';
    if (payload.isEmpty) {
      throw Exception('No se pudo generar el QR temporal.');
    }
    return data!;
  }

  Future<Map<String, dynamic>> renovarSesionTienda({
    required String idTienda,
    required String sessionId,
    required String dispositivo,
    required double latitud,
    required double longitud,
    required double precisionMetros,
  }) async {
    final informacion = await _obtenerInformacionSegura(dispositivo);
    Map<String, dynamic>? data;

    if (_rpcVersionSesionDisponible != false) {
      try {
        data = await _rpcMaybeSingle(
          'renovar_sesion_tienda',
          params: {
            'p_id_tienda': idTienda,
            'p_session_id': sessionId,
            'p_dispositivo': dispositivo,
            'p_latitud': latitud,
            'p_longitud': longitud,
            'p_precision_metros': precisionMetros,
            'p_version_aplicacion': informacion.version,
            'p_build_aplicacion': informacion.build,
          },
        );
        _rpcVersionSesionDisponible = true;
      } on PostgrestException catch (error) {
        if (!_esFuncionNoDisponible(error, 'renovar_sesion_tienda')) rethrow;
        _rpcVersionSesionDisponible = false;
      }
    }

    if (_rpcVersionSesionDisponible == false) {
      data = await _rpcMaybeSingle(
        'renovar_sesion_tienda',
        params: {
          'p_id_tienda': idTienda,
          'p_session_id': sessionId,
          'p_dispositivo': dispositivo,
          'p_latitud': latitud,
          'p_longitud': longitud,
          'p_precision_metros': precisionMetros,
        },
      );
    }

    if (data == null) {
      throw Exception('No se pudo renovar la sesión de tienda.');
    }
    return data;
  }

  Future<Map<String, dynamic>> validarSesionTienda({
    required String idTienda,
    required String sessionId,
  }) async {
    final data = await _rpcMaybeSingle(
      'renovar_sesion_tienda',
      params: {'p_id_tienda': idTienda, 'p_session_id': sessionId},
    );

    if (data == null) {
      throw Exception('No se pudo validar la sesión de tienda.');
    }
    return data;
  }

  Future<bool> cerrarSesionTienda({
    required String idTienda,
    required String sessionId,
  }) async {
    final response = await _client.rpc(
      'cerrar_sesion_tienda',
      params: {'p_id_tienda': idTienda, 'p_session_id': sessionId},
    );
    return response == true;
  }

  Future<Map<String, dynamic>> _iniciarSesionTiendaLegacy({
    required String correo,
    required String contrasena,
    required String sessionId,
    required String dispositivo,
    required double latitud,
    required double longitud,
    required double precisionMetros,
  }) async {
    final tiendaData = await _rpcMaybeSingle(
      'login_tienda',
      params: {
        'p_correo': correo.trim().toLowerCase(),
        'p_contrasena': contrasena,
      },
    );
    if (tiendaData == null) {
      return {
        'permitido': false,
        'mensaje': 'Correo o contraseña incorrectos.',
      };
    }

    final tienda = _mapearTienda(tiendaData);
    final sesion = await _rpcMaybeSingle(
      'iniciar_sesion_tienda',
      params: {
        'p_id_tienda': tienda['id_tienda'],
        'p_session_id': sessionId,
        'p_dispositivo': dispositivo,
        'p_latitud': latitud,
        'p_longitud': longitud,
        'p_precision_metros': precisionMetros,
      },
    );
    if (sesion == null) {
      throw Exception('No se pudo iniciar la sesión de tienda.');
    }

    return {...tienda, ...sesion};
  }

  Future<Map<String, dynamic>> _iniciarSesionTiendaSeguraCompatible({
    required String correo,
    required String contrasena,
    required String sessionId,
    required String dispositivo,
    required double latitud,
    required double longitud,
    required double precisionMetros,
  }) async {
    try {
      final data = await _rpcMaybeSingle(
        'iniciar_sesion_tienda_segura',
        params: {
          'p_correo': correo.trim().toLowerCase(),
          'p_contrasena': contrasena,
          'p_session_id': sessionId,
          'p_dispositivo': dispositivo,
          'p_latitud': latitud,
          'p_longitud': longitud,
          'p_precision_metros': precisionMetros,
        },
      );
      if (data == null) {
        throw Exception('Supabase no devolvió el resultado del inicio.');
      }
      return data;
    } on PostgrestException catch (error) {
      if (!_esFuncionNoDisponible(error, 'iniciar_sesion_tienda_segura')) {
        rethrow;
      }
      return _iniciarSesionTiendaLegacy(
        correo: correo,
        contrasena: contrasena,
        sessionId: sessionId,
        dispositivo: dispositivo,
        latitud: latitud,
        longitud: longitud,
        precisionMetros: precisionMetros,
      );
    }
  }

  Future<Map<String, dynamic>?> _rpcMaybeSingle(
    String functionName, {
    required Map<String, dynamic> params,
  }) async {
    final response = await _client.rpc(functionName, params: params);

    if (response == null) return null;
    if (response is List) {
      if (response.isEmpty) return null;
      final first = response.first;
      if (first is! Map) {
        throw FormatException('Respuesta inválida de $functionName.');
      }
      return Map<String, dynamic>.from(first);
    }
    if (response is! Map) {
      throw FormatException('Respuesta inválida de $functionName.');
    }
    return Map<String, dynamic>.from(response);
  }

  bool _esFuncionNoDisponible(PostgrestException error, String _) {
    return error.code == 'PGRST202' || error.code == '42883';
  }

  Future<InformacionAplicacion> _obtenerInformacionSegura(
    String dispositivo,
  ) async {
    try {
      return await _informacionAplicacionService.obtener();
    } catch (_) {
      return InformacionAplicacion(
        version: '',
        build: 0,
        plataforma: dispositivo.trim().toLowerCase(),
      );
    }
  }

  Map<String, dynamic> _mapearTienda(Map<String, dynamic> data) {
    return {
      'id_tienda': (data['id_tienda'] ?? '').toString(),
      'nombre': (data['nombre'] ?? '').toString().trim(),
      'correo': (data['correo'] ?? '').toString().trim(),
      'telefono': (data['telefono'] ?? '').toString().trim(),
      'direccion': (data['direccion'] ?? '').toString().trim(),
      'fecha_apertura': data['fecha_apertura']?.toString() ?? '',
      'estado': data['estado'] == true,
    };
  }
}
