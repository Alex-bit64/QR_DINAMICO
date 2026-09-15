import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../app_visuals.dart';
import '../services/actualizacion_service.dart';
import '../services/sesion_local_service.dart';
import '../services/supabase_service.dart';
import '../services/ubicacion_service.dart';
import 'qr_screen.dart';

class LoginTiendaScreen extends StatefulWidget {
  const LoginTiendaScreen({super.key, this.mensajeInicial});

  final String? mensajeInicial;

  @override
  State<LoginTiendaScreen> createState() => _LoginTiendaScreenState();
}

class _LoginTiendaScreenState extends State<LoginTiendaScreen> {
  final _correoController = TextEditingController();
  final _passwordController = TextEditingController();
  final _supabaseService = SupabaseService.instance;
  final _ubicacionService = UbicacionService.instance;
  final _sesionLocalService = SesionLocalService.instance;
  final _actualizacionService = ActualizacionService.instance;

  bool _cargando = true;
  bool _procesando = false;
  bool _passwordVisible = false;
  String? _mensajeValidacion;

  @override
  void initState() {
    super.initState();
    _mensajeValidacion = widget.mensajeInicial;
    _verificarSesionGuardada();
  }

  String _normalizarCorreo(String valor) {
    return valor.trim().toLowerCase();
  }

  Future<void> _verificarSesionGuardada() async {
    try {
      await _comprobarActualizacion();
      if (!mounted) return;

      final sesionLocal = await _sesionLocalService.cargar();
      if (sesionLocal != null) {
        final tiendaActual = await _supabaseService.obtenerTiendaSesion(
          idTienda: sesionLocal.idTienda,
          sessionId: sesionLocal.sessionId,
        );
        if (tiendaActual == null) {
          await _limpiarSesionLocal();
          if (mounted) {
            setState(() {
              _cargando = false;
              _mensajeValidacion = 'La sesión fue cerrada desde Supabase.';
            });
          }
          return;
        }

        final ubicacion = await _ubicacionService.obtenerActual();
        final sesion = await _supabaseService.renovarSesionTienda(
          idTienda: sesionLocal.idTienda,
          sessionId: sesionLocal.sessionId,
          dispositivo: _ubicacionService.dispositivo,
          latitud: ubicacion.latitude,
          longitud: ubicacion.longitude,
          precisionMetros: ubicacion.accuracy,
        );
        if (sesion['permitido'] != true) {
          await _limpiarSesionLocal();
          if (mounted) {
            setState(() {
              _cargando = false;
              _mensajeValidacion =
                  (sesion['mensaje'] ?? 'La sesión guardada ya no está activa.')
                      .toString();
            });
          }
          return;
        }

        _validarDatosTienda(tiendaActual);
        await _guardarSesionLocal(
          tiendaActual,
          sessionId: sesionLocal.sessionId,
        );
        if (!mounted) return;
        _abrirQr(tiendaActual, sesionLocal.sessionId);
        return;
      }

      if (mounted) setState(() => _cargando = false);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _cargando = false;
        _mensajeValidacion = error is UbicacionException
            ? error.mensaje
            : 'No se pudo comprobar la sesión guardada. Revisa tu conexión.';
      });
    }
  }

  Future<void> _comprobarActualizacion() async {
    try {
      final actualizacion = await _actualizacionService.comprobar();
      if (actualizacion == null || !mounted) return;

      final descargar = await showDialog<bool>(
        context: context,
        barrierDismissible: true,
        builder: (dialogContext) {
          final brightness = Theme.of(dialogContext).brightness;
          final textColor = AppPalette.textColor(brightness);
          final mutedColor = AppPalette.mutedTextColor(brightness);
          return AlertDialog(
            backgroundColor: AppPalette.panelColor(brightness),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
            ),
            titlePadding: const EdgeInsets.fromLTRB(24, 20, 12, 0),
            title: Row(
              children: [
                const Icon(
                  Icons.system_update_alt_rounded,
                  color: AppPalette.turquoise,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Actualización disponible',
                    style: GoogleFonts.bebasNeue(
                      color: textColor,
                      fontSize: 24,
                      letterSpacing: 1,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Cerrar',
                  onPressed: () => Navigator.pop(dialogContext, false),
                  icon: Icon(Icons.close_rounded, color: mutedColor),
                ),
              ],
            ),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    actualizacion.mensaje,
                    style: GoogleFonts.robotoCondensed(
                      color: textColor,
                      fontSize: 16,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'Instalada: ${actualizacion.versionActual} '
                    '(${actualizacion.buildActual})\n'
                    'Disponible: ${actualizacion.versionPublicada} '
                    '(${actualizacion.buildPublicado})',
                    style: GoogleFonts.robotoCondensed(
                      color: mutedColor,
                      fontSize: 14,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Puedes continuar ahora. El aviso volverá a aparecer la '
                    'próxima vez que abras la aplicación.',
                    style: GoogleFonts.robotoCondensed(
                      color: mutedColor,
                      fontSize: 13,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Ahora no'),
              ),
              FilledButton.icon(
                onPressed: () => Navigator.pop(dialogContext, true),
                icon: const Icon(Icons.download_rounded),
                label: const Text('Actualizar'),
              ),
            ],
          );
        },
      );

      if (descargar != true) return;
      final abierto = await _actualizacionService.abrirDescarga(actualizacion);
      if (!abierto) {
        _mostrarMensaje('No se pudo abrir el enlace de actualización.');
      }
    } catch (_) {
      // La comprobación es opcional: una caída de red o un RPC aún no aplicado
      // nunca debe impedir restaurar o iniciar la sesión de la tienda.
    }
  }

  Future<void> _limpiarSesionLocal() async {
    await _sesionLocalService.limpiar();
  }

  Future<void> _guardarSesionLocal(
    Map<String, dynamic> tienda, {
    required String sessionId,
  }) async {
    await _sesionLocalService.guardar(
      idTienda: tienda['id_tienda'] as String,
      sessionId: sessionId,
    );
  }

  Future<void> _ingresar() async {
    final correoIngresado = _normalizarCorreo(_correoController.text);
    final passwordIngresado = _passwordController.text;
    final errorCredenciales = _validarCredenciales(
      correoIngresado,
      passwordIngresado,
    );

    if (errorCredenciales != null) {
      _mostrarMensaje(errorCredenciales);
      return;
    }

    setState(() {
      _procesando = true;
      _mensajeValidacion = null;
    });

    try {
      final ubicacion = await _ubicacionService.obtenerActual();
      final sessionId = _crearSessionId();
      final resultado = await _supabaseService.iniciarSesionTiendaSegura(
        correo: correoIngresado,
        contrasena: passwordIngresado,
        sessionId: sessionId,
        dispositivo: _ubicacionService.dispositivo,
        latitud: ubicacion.latitude,
        longitud: ubicacion.longitude,
        precisionMetros: ubicacion.accuracy,
      );

      if (resultado['permitido'] != true) {
        _mostrarMensaje(
          (resultado['mensaje'] ?? 'No se pudo iniciar la sesión.').toString(),
        );
        return;
      }

      _validarDatosTienda(resultado);
      await _guardarSesionLocal(resultado, sessionId: sessionId);

      if (!mounted) return;
      _abrirQr(resultado, sessionId);
    } catch (e) {
      _mostrarMensaje(
        e is UbicacionException
            ? e.mensaje
            : 'No se pudo iniciar sesión. Revisa la conexión e inténtalo otra vez.',
      );
    } finally {
      if (mounted) {
        setState(() => _procesando = false);
      }
    }
  }

  String? _validarCredenciales(String correo, String contrasena) {
    if (correo.isEmpty || contrasena.isEmpty) {
      return 'Ingresa tu correo y contraseña.';
    }
    final correoValido = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(correo);
    if (!correoValido || correo.length > 150) {
      return 'Ingresa un correo válido.';
    }
    if (utf8.encode(contrasena).length > 72) {
      return 'La contraseña no puede superar 72 bytes.';
    }
    return null;
  }

  void _validarDatosTienda(Map<String, dynamic> tienda) {
    final id = (tienda['id_tienda'] ?? '').toString().trim();
    final nombre = (tienda['nombre'] ?? '').toString().trim();
    final correo = (tienda['correo'] ?? '').toString().trim();
    final direccion = (tienda['direccion'] ?? '').toString().trim();
    final uuidValido = RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-'
      r'[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
    ).hasMatch(id);

    if (!uuidValido || nombre.isEmpty || correo.isEmpty || direccion.isEmpty) {
      throw Exception(
        'Los datos de la tienda están incompletos. Revisa nombre, correo y '
        'dirección en Supabase.',
      );
    }
  }

  String _crearSessionId() {
    const chars = 'abcdef0123456789';
    final random = Random.secure();
    return List.generate(32, (_) => chars[random.nextInt(chars.length)]).join();
  }

  void _abrirQr(Map<String, dynamic> tienda, String sessionId) {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => QRScreen(
          idTienda: tienda['id_tienda'] as String,
          nombreTienda: tienda['nombre'] as String,
          direccion: tienda['direccion'] as String,
          correo: tienda['correo'] as String,
          sessionId: sessionId,
        ),
      ),
    );
  }

  void _mostrarMensaje(String mensaje) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(mensaje)));
  }

  @override
  void dispose() {
    _correoController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final isDark = brightness == Brightness.dark;

    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: _cargando
          ? Stack(
              children: [
                const Positioned.fill(child: AppBackgroundImage()),
                const Center(
                  child: CircularProgressIndicator(color: AppPalette.turquoise),
                ),
              ],
            )
          : Stack(
              children: [
                const Positioned.fill(child: AppBackgroundImage()),
                Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: isDark
                          ? [
                              Colors.black.withValues(alpha: 0.40),
                              Colors.black.withValues(alpha: 0.62),
                            ]
                          : [
                              Colors.white.withValues(alpha: 0.10),
                              Colors.white.withValues(alpha: 0.18),
                            ],
                    ),
                  ),
                ),
                SafeArea(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final availableHeight =
                          constraints.maxHeight -
                          MediaQuery.of(context).viewInsets.bottom;

                      return SingleChildScrollView(
                        physics: const BouncingScrollPhysics(),
                        padding: EdgeInsets.fromLTRB(
                          28,
                          18,
                          28,
                          MediaQuery.of(context).viewInsets.bottom + 24,
                        ),
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            minHeight: availableHeight,
                          ),
                          child: Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 420),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Align(
                                    alignment: Alignment.centerRight,
                                    child: IconButton(
                                      tooltip: isDark
                                          ? 'Modo claro'
                                          : 'Modo oscuro',
                                      onPressed: AppThemeController.toggle,
                                      icon: Icon(
                                        isDark
                                            ? Icons.light_mode
                                            : Icons.dark_mode,
                                      ),
                                      style: IconButton.styleFrom(
                                        foregroundColor: isDark
                                            ? AppPalette.turquoise
                                            : AppPalette.primaryDark,
                                        backgroundColor: isDark
                                            ? Colors.white.withValues(
                                                alpha: 0.12,
                                              )
                                            : Colors.white.withValues(
                                                alpha: 0.9,
                                              ),
                                        side: BorderSide(
                                          color: isDark
                                              ? AppPalette.turquoise.withValues(
                                                  alpha: 0.4,
                                                )
                                              : AppPalette.primaryDark
                                                    .withValues(alpha: 0.3),
                                          width: 2,
                                        ),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 18),
                                  Container(
                                    padding: const EdgeInsets.all(28),
                                    decoration: BoxDecoration(
                                      color: isDark
                                          ? Colors.black.withValues(alpha: 0.42)
                                          : const Color(
                                              0xFFFAF3E9,
                                            ).withValues(alpha: 0.96),
                                      borderRadius: BorderRadius.circular(24),
                                      border: Border.all(
                                        color: isDark
                                            ? AppPalette.turquoise.withValues(
                                                alpha: 0.22,
                                              )
                                            : Colors.black12,
                                      ),
                                      boxShadow: [
                                        BoxShadow(
                                          color: isDark
                                              ? Colors.black.withValues(
                                                  alpha: 0.35,
                                                )
                                              : Colors.black.withValues(
                                                  alpha: 0.12,
                                                ),
                                          blurRadius: 28,
                                          offset: const Offset(0, 14),
                                        ),
                                      ],
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        Text(
                                          'TIENDA QR',
                                          textAlign: TextAlign.center,
                                          style: GoogleFonts.bebasNeue(
                                            fontSize: 38,
                                            color: isDark
                                                ? Colors.white
                                                : AppPalette.primaryDark,
                                            letterSpacing: 3.5,
                                            height: 1.0,
                                          ),
                                        ),
                                        if (_mensajeValidacion != null) ...[
                                          const SizedBox(height: 18),
                                          Container(
                                            padding: const EdgeInsets.all(12),
                                            decoration: BoxDecoration(
                                              color: Colors.orange.withValues(
                                                alpha: 0.12,
                                              ),
                                              border: Border.all(
                                                color: Colors.orange.withValues(
                                                  alpha: 0.5,
                                                ),
                                              ),
                                              borderRadius:
                                                  BorderRadius.circular(14),
                                            ),
                                            child: Row(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                const Icon(
                                                  Icons.info_outline,
                                                  color: Colors.orange,
                                                  size: 20,
                                                ),
                                                const SizedBox(width: 10),
                                                Expanded(
                                                  child: Text(
                                                    _mensajeValidacion!,
                                                    style:
                                                        GoogleFonts.robotoCondensed(
                                                          color: isDark
                                                              ? Colors.white
                                                              : AppPalette
                                                                    .primaryDark,
                                                          height: 1.3,
                                                        ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ],
                                        const SizedBox(height: 24),
                                        const _EtiquetaCampo(texto: 'Correo'),
                                        const SizedBox(height: 8),
                                        TextField(
                                          controller: _correoController,
                                          keyboardType:
                                              TextInputType.emailAddress,
                                          textInputAction: TextInputAction.next,
                                          autocorrect: false,
                                          cursorColor: AppPalette.turquoise,
                                          style: TextStyle(
                                            color: isDark
                                                ? Colors.white.withValues(
                                                    alpha: 0.95,
                                                  )
                                                : Colors.black87,
                                            fontSize: 16,
                                          ),
                                          decoration: _inputDecoration(
                                            context,
                                            '',
                                          ),
                                        ),
                                        const SizedBox(height: 16),
                                        const _EtiquetaCampo(
                                          texto: 'Contraseña',
                                        ),
                                        const SizedBox(height: 8),
                                        TextField(
                                          controller: _passwordController,
                                          obscureText: !_passwordVisible,
                                          textInputAction: TextInputAction.done,
                                          autocorrect: false,
                                          onSubmitted: (_) =>
                                              _procesando ? null : _ingresar(),
                                          cursorColor: AppPalette.turquoise,
                                          style: TextStyle(
                                            color: isDark
                                                ? Colors.white.withValues(
                                                    alpha: 0.95,
                                                  )
                                                : Colors.black87,
                                            fontSize: 16,
                                          ),
                                          decoration:
                                              _inputDecoration(
                                                context,
                                                '',
                                              ).copyWith(
                                                suffixIcon: IconButton(
                                                  icon: Icon(
                                                    _passwordVisible
                                                        ? Icons.visibility_off
                                                        : Icons.visibility,
                                                    color: isDark
                                                        ? AppPalette.turquoise
                                                        : AppPalette
                                                              .primaryDark,
                                                  ),
                                                  onPressed: () {
                                                    setState(
                                                      () => _passwordVisible =
                                                          !_passwordVisible,
                                                    );
                                                  },
                                                ),
                                              ),
                                        ),
                                        const SizedBox(height: 26),
                                        ElevatedButton(
                                          onPressed: _procesando
                                              ? null
                                              : _ingresar,
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor:
                                                AppPalette.turquoise,
                                            foregroundColor: Colors.white,
                                            minimumSize: const Size.fromHeight(
                                              54,
                                            ),
                                            shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(14),
                                            ),
                                            elevation: 0,
                                          ),
                                          child: _procesando
                                              ? const SizedBox(
                                                  width: 20,
                                                  height: 20,
                                                  child:
                                                      CircularProgressIndicator(
                                                        color: Colors.white,
                                                        strokeWidth: 2,
                                                      ),
                                                )
                                              : Text(
                                                  'ENTRAR',
                                                  style: GoogleFonts.bebasNeue(
                                                    fontSize: 18,
                                                    color: Colors.white,
                                                    letterSpacing: 1.5,
                                                  ),
                                                ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 24),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }

  InputDecoration _inputDecoration(BuildContext context, String hint) {
    final brightness = Theme.of(context).brightness;
    final isDark = brightness == Brightness.dark;

    return InputDecoration(
      filled: true,
      fillColor: isDark
          ? Colors.black.withValues(alpha: 0.28)
          : const Color(0xFFFAF3E9).withValues(alpha: 0.96),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(
          color: isDark
              ? AppPalette.turquoise.withValues(alpha: 0.22)
              : Colors.black12,
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: AppPalette.turquoise, width: 2),
      ),
      hintText: hint,
      hintStyle: TextStyle(color: isDark ? Colors.white70 : Colors.black45),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    );
  }
}

class _EtiquetaCampo extends StatelessWidget {
  final String texto;

  const _EtiquetaCampo({required this.texto});

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final isDark = brightness == Brightness.dark;

    return Text(
      texto,
      style: GoogleFonts.robotoCondensed(
        fontSize: 14,
        color: isDark ? Colors.white70 : Colors.black87,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.5,
      ),
    );
  }
}
