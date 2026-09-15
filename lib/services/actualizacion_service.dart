import 'package:url_launcher/url_launcher.dart';

import 'informacion_aplicacion_service.dart';
import 'supabase_service.dart';

class ActualizacionDisponible {
  const ActualizacionDisponible({
    required this.versionActual,
    required this.buildActual,
    required this.versionPublicada,
    required this.buildPublicado,
    required this.urlDescarga,
    required this.mensaje,
    this.sha256,
  });

  final String versionActual;
  final int buildActual;
  final String versionPublicada;
  final int buildPublicado;
  final Uri urlDescarga;
  final String mensaje;
  final String? sha256;

  static ActualizacionDisponible? desdeRespuesta(Map<String, dynamic>? data) {
    if (data == null || data['disponible'] != true) return null;

    final versionActual = (data['version_actual'] ?? '').toString().trim();
    final versionPublicada = (data['version_publicada'] ?? '')
        .toString()
        .trim();
    final buildActual = _entero(data['build_actual']);
    final buildPublicado = _entero(data['build_publicado']);
    final uri = Uri.tryParse((data['url_descarga'] ?? '').toString().trim());
    final mensaje = (data['mensaje'] ?? '').toString().trim();
    final sha256 = (data['sha256'] ?? '').toString().trim().toLowerCase();

    if (versionPublicada.isEmpty ||
        buildPublicado <= buildActual ||
        uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty) {
      return null;
    }

    return ActualizacionDisponible(
      versionActual: versionActual,
      buildActual: buildActual,
      versionPublicada: versionPublicada,
      buildPublicado: buildPublicado,
      urlDescarga: uri,
      mensaje: mensaje.isEmpty ? 'Hay una nueva versión disponible.' : mensaje,
      sha256: RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256) ? sha256 : null,
    );
  }

  static int _entero(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}

class ActualizacionService {
  ActualizacionService._();

  static final ActualizacionService instance = ActualizacionService._();

  final _informacionService = InformacionAplicacionService.instance;
  final _supabaseService = SupabaseService.instance;

  Future<ActualizacionDisponible?> comprobar() async {
    final informacion = await _informacionService.obtener();
    if (!const {
      'android',
      'ios',
      'windows',
      'macos',
      'linux',
    }.contains(informacion.plataforma)) {
      return null;
    }

    final data = await _supabaseService.obtenerActualizacionAplicacion(
      plataforma: informacion.plataforma,
      versionActual: informacion.version,
      buildActual: informacion.build,
    );
    return ActualizacionDisponible.desdeRespuesta(data);
  }

  Future<bool> abrirDescarga(ActualizacionDisponible actualizacion) {
    return launchUrl(
      actualizacion.urlDescarga,
      mode: LaunchMode.externalApplication,
    );
  }
}
