import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

class UbicacionException implements Exception {
  const UbicacionException(this.mensaje);

  final String mensaje;

  @override
  String toString() => mensaje;
}

class UbicacionService {
  UbicacionService._();

  static final UbicacionService instance = UbicacionService._();

  String get dispositivo {
    if (kIsWeb) return 'web';

    return switch (defaultTargetPlatform) {
      TargetPlatform.android => 'android',
      TargetPlatform.iOS => 'ios',
      TargetPlatform.windows => 'windows',
      TargetPlatform.macOS => 'macos',
      TargetPlatform.linux => 'linux',
      TargetPlatform.fuchsia => 'fuchsia',
    };
  }

  Future<Position> obtenerActual({bool solicitarPermiso = true}) async {
    try {
      final servicioActivo = await Geolocator.isLocationServiceEnabled();
      if (!servicioActivo) {
        throw const UbicacionException(
          'Activa la ubicación del dispositivo antes de continuar.',
        );
      }

      var permiso = await Geolocator.checkPermission();
      if (permiso == LocationPermission.denied && solicitarPermiso) {
        permiso = await Geolocator.requestPermission();
      }

      if (permiso == LocationPermission.denied) {
        throw const UbicacionException(
          'Debes permitir el acceso a la ubicación para mostrar el QR.',
        );
      }

      if (permiso == LocationPermission.deniedForever) {
        throw const UbicacionException(
          'El permiso de ubicación está bloqueado. Actívalo en la configuración '
          'del sistema.',
        );
      }

      final posicion = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 12),
        ),
      );
      _validar(posicion);
      return posicion;
    } on UbicacionException {
      rethrow;
    } on TimeoutException {
      throw const UbicacionException(
        'No se pudo obtener una ubicación reciente. Revisa la señal e inténtalo '
        'otra vez.',
      );
    } on LocationServiceDisabledException {
      throw const UbicacionException(
        'La ubicación del dispositivo está desactivada.',
      );
    } catch (error) {
      throw UbicacionException(
        'No se pudo validar la ubicación: ${_mensajeLimpio(error)}',
      );
    }
  }

  void _validar(Position posicion) {
    if (!posicion.latitude.isFinite ||
        posicion.latitude < -90 ||
        posicion.latitude > 90 ||
        !posicion.longitude.isFinite ||
        posicion.longitude < -180 ||
        posicion.longitude > 180) {
      throw const UbicacionException(
        'El dispositivo devolvió coordenadas inválidas.',
      );
    }

    if (!posicion.accuracy.isFinite || posicion.accuracy < 0) {
      throw const UbicacionException(
        'El dispositivo no pudo determinar la precisión de la ubicación.',
      );
    }
  }

  String _mensajeLimpio(Object error) {
    return error
        .toString()
        .replaceFirst('Exception: ', '')
        .replaceFirst('UbicacionException: ', '');
  }
}
