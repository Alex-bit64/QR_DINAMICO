import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

class InformacionAplicacion {
  const InformacionAplicacion({
    required this.version,
    required this.build,
    required this.plataforma,
  });

  final String version;
  final int build;
  final String plataforma;
}

class InformacionAplicacionService {
  InformacionAplicacionService._();

  static final InformacionAplicacionService instance =
      InformacionAplicacionService._();

  Future<InformacionAplicacion>? _informacion;

  Future<InformacionAplicacion> obtener() {
    return _informacion ??= _cargar();
  }

  Future<InformacionAplicacion> _cargar() async {
    final packageInfo = await PackageInfo.fromPlatform();
    return InformacionAplicacion(
      version: packageInfo.version.trim(),
      build: int.tryParse(packageInfo.buildNumber.trim()) ?? 0,
      plataforma: _plataforma,
    );
  }

  String get _plataforma {
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
}
