import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class SupabaseService {
  SupabaseService._();

  static final SupabaseService instance = SupabaseService._();

  SupabaseClient get _client => Supabase.instance.client;

  Future<Map<String, dynamic>?> buscarTiendaPorCorreo(String correo) async {
    final correoNormalizado = correo.trim().toLowerCase();
    final data = await _rpcMaybeSingle(
      'obtener_tienda_por_correo',
      params: {'p_correo': correoNormalizado},
    );

    if (data == null) {
      return null;
    }

    return _mapearTienda(data);
  }

  Future<Map<String, dynamic>?> buscarTiendaPorId(String idTienda) async {
    final data = await _rpcMaybeSingle(
      'obtener_tienda_por_id',
      params: {'p_id_tienda': idTienda},
    );

    if (data == null) {
      return null;
    }

    return _mapearTienda(data);
  }

  Future<Map<String, dynamic>?> loginTienda({
    required String correo,
    required String contrasena,
  }) async {
    final data = await _rpcMaybeSingle(
      'login_tienda',
      params: {
        'p_correo': correo.trim().toLowerCase(),
        'p_contrasena': contrasena.trim(),
      },
    );
    if (data == null) {
      return null;
    }

    return _mapearTienda(data);
  }

  Future<Map<String, dynamic>> asegurarQrEstatico({
    required String idTienda,
  }) async {
    final data = await _rpcMaybeSingle(
      'obtener_o_crear_qr_tienda',
      params: {'p_id_tienda': idTienda},
    );

    if (data == null) {
      throw Exception('No se encontro un QR para esta tienda.');
    }

    return data;
  }

  Future<Map<String, dynamic>> obtenerPayloadQrTienda({
    required String idTienda,
    required String sessionId,
  }) async {
    final data = await _rpcMaybeSingle(
      'obtener_payload_qr_tienda',
      params: {'p_id_tienda': idTienda, 'p_session_id': sessionId},
    );

    if (data == null || data['payload'] == null) {
      throw Exception('No se pudo generar el QR temporal.');
    }

    return data;
  }

  String generarPayloadQrDinamico({
    required String token,
    DateTime? fechaHora,
  }) {
    final timestamp = (fechaHora ?? DateTime.now()).millisecondsSinceEpoch;
    final slot = timestamp ~/ const Duration(seconds: 30).inMilliseconds;
    final firma = md5
        .convert(utf8.encode('${token.trim()}:$slot:qr_dinamico:v2'))
        .toString();

    return 'app-qr-dinamico://$slot/$firma';
  }

  Future<Map<String, dynamic>> iniciarSesionTienda({
    required String idTienda,
    required String sessionId,
    required String dispositivo,
    required double latitud,
    required double longitud,
    required double precisionMetros,
  }) async {
    final data = await _rpcMaybeSingle(
      'iniciar_sesion_tienda',
      params: {
        'p_id_tienda': idTienda,
        'p_session_id': sessionId,
        'p_dispositivo': dispositivo,
        'p_latitud': latitud,
        'p_longitud': longitud,
        'p_precision_metros': precisionMetros,
      },
    );

    if (data == null) {
      throw Exception('No se pudo iniciar la sesion de tienda.');
    }

    return data;
  }

  Future<Map<String, dynamic>> renovarSesionTienda({
    required String idTienda,
    required String sessionId,
    required String dispositivo,
    required double latitud,
    required double longitud,
    required double precisionMetros,
  }) async {
    final data = await _rpcMaybeSingle(
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

  Future<void> cerrarSesionTienda({
    required String idTienda,
    required String sessionId,
  }) async {
    await _client.rpc(
      'cerrar_sesion_tienda',
      params: {'p_id_tienda': idTienda, 'p_session_id': sessionId},
    );
  }

  Future<bool> validarQrTienda(String idTienda) async {
    final data = await _rpcMaybeSingle(
      'obtener_qr_tienda',
      params: {'p_id_tienda': idTienda},
    );

    return data != null;
  }

  Future<String> registrarMarcacionAsistencia({
    required String dniTrabajador,
    DateTime? fechaHora,
    String? qrPayload,
  }) async {
    final data = await _rpcMaybeSingle(
      'registrar_marcacion_asistencia',
      params: {
        'p_dni': dniTrabajador.trim(),
        'p_fecha_hora': (fechaHora ?? DateTime.now()).toIso8601String(),
        'p_token': qrPayload,
      },
    );

    if (data == null || data['campo_marcado'] == null) {
      throw Exception('No se pudo registrar la marcacion.');
    }

    return data['campo_marcado'].toString();
  }

  Future<Map<String, dynamic>?> _rpcMaybeSingle(
    String functionName, {
    required Map<String, dynamic> params,
  }) async {
    final response = await _client.rpc(functionName, params: params);

    if (response == null) {
      return null;
    }

    if (response is List) {
      if (response.isEmpty) return null;
      return Map<String, dynamic>.from(response.first as Map);
    }

    return Map<String, dynamic>.from(response as Map);
  }

  Map<String, dynamic> _mapearTienda(Map<String, dynamic> data) {
    final nombre = (data['nombre'] ?? '').toString();
    return {
      'id_tienda': (data['id_tienda'] ?? '').toString(),
      'nombre': nombre,
      'correo': (data['correo'] ?? '').toString().trim(),
      'contrasena': (data['contrasena'] ?? '').toString(),
      'telefono': (data['telefono'] ?? '').toString(),
      'direccion': (data['direccion'] ?? '').toString(),
      'fecha_apertura': data['fecha_apertura']?.toString() ?? '',
      'estado': data['estado']?.toString() ?? '',
    };
  }
}
