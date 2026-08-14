import 'dart:math';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_visuals.dart';
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
    final prefs = await SharedPreferences.getInstance();
    final idTienda = prefs.getString('id_tienda');
    final sessionId = prefs.getString('tienda_session_id');

    if (idTienda != null &&
        idTienda.isNotEmpty &&
        sessionId != null &&
        sessionId.isNotEmpty) {
      try {
        final validacion = await _supabaseService.validarSesionTienda(
          idTienda: idTienda,
          sessionId: sessionId,
        );
        if (validacion['permitido'] != true) {
          await _limpiarSesionLocal();
          if (mounted) {
            setState(() {
              _cargando = false;
              _mensajeValidacion =
                  (validacion['mensaje'] ??
                          'La sesión fue cerrada desde Supabase.')
                      .toString();
            });
          }
          return;
        }

        final ubicacion = await _ubicacionService.obtenerActual();
        final sesion = await _supabaseService.renovarSesionTienda(
          idTienda: idTienda,
          sessionId: sessionId,
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

        final tiendaActual = await _supabaseService.buscarTiendaPorId(idTienda);
        if (tiendaActual == null) {
          throw Exception('No se encontraron los datos de la tienda.');
        }
        _validarDatosTienda(tiendaActual);

        final qr = await _supabaseService.asegurarQrEstatico(
          idTienda: idTienda,
        );
        final qrToken = _validarQr(qr);
        await _guardarSesionLocal(tiendaActual, qrToken: qrToken);
        if (!mounted) return;
        _abrirQr(tiendaActual, sessionId, qrToken: qrToken);
        return;
      } catch (error) {
        if (mounted) {
          setState(() {
            _cargando = false;
            _mensajeValidacion =
                'No se restauró la sesión: ${_mensajeError(error)}';
          });
        }
        return;
      }
    }

    if (mounted) {
      setState(() => _cargando = false);
    }
  }

  Future<void> _limpiarSesionLocal() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('id_tienda');
    await prefs.remove('nombre');
    await prefs.remove('direccion');
    await prefs.remove('correo');
    await prefs.remove('tienda_session_id');
    await prefs.remove('qr_token');
  }

  Future<void> _guardarSesionLocal(
    Map<String, dynamic> tienda, {
    String? sessionId,
    String? qrToken,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('id_tienda', tienda['id_tienda'] as String);
    await prefs.setString('nombre', tienda['nombre'] as String);
    await prefs.setString('direccion', tienda['direccion'] as String);
    await prefs.setString('correo', tienda['correo'] as String);
    if (sessionId != null) {
      await prefs.setString('tienda_session_id', sessionId);
    }
    if (qrToken != null && qrToken.isNotEmpty) {
      await prefs.setString('qr_token', qrToken);
    }
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
      final tienda = await _supabaseService.loginTienda(
        correo: correoIngresado,
        contrasena: passwordIngresado,
      );

      if (tienda == null) {
        _mostrarMensaje('Correo o contraseña incorrectos.');
        return;
      }
      _validarDatosTienda(tienda);

      final qr = await _supabaseService.asegurarQrEstatico(
        idTienda: tienda['id_tienda'] as String,
      );
      final qrToken = _validarQr(qr);
      final ubicacion = await _ubicacionService.obtenerActual();

      final sessionId = _crearSessionId();
      final sesion = await _supabaseService.iniciarSesionTienda(
        idTienda: tienda['id_tienda'] as String,
        sessionId: sessionId,
        dispositivo: _ubicacionService.dispositivo,
        latitud: ubicacion.latitude,
        longitud: ubicacion.longitude,
        precisionMetros: ubicacion.accuracy,
      );

      if (sesion['permitido'] != true) {
        _mostrarMensaje(
          (sesion['mensaje'] ?? 'Esta tienda ya esta abierta.').toString(),
        );
        return;
      }

      await _guardarSesionLocal(tienda, sessionId: sessionId, qrToken: qrToken);

      if (!mounted) return;
      _abrirQr(tienda, sessionId, qrToken: qrToken);
    } catch (e) {
      _mostrarMensaje('Error iniciando sesion: ${_mensajeError(e)}');
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
    if (contrasena.length > 256) {
      return 'La contraseña ingresada no es válida.';
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

  String _validarQr(Map<String, dynamic> qr) {
    final token = (qr['token'] ?? '').toString().trim();
    if (token.isEmpty) {
      throw Exception('La tienda no tiene un token QR válido.');
    }
    return token;
  }

  String _mensajeError(Object error) {
    return error.toString().replaceFirst('Exception: ', '');
  }

  String _crearSessionId() {
    const chars = 'abcdef0123456789';
    final random = Random.secure();
    return List.generate(32, (_) => chars[random.nextInt(chars.length)]).join();
  }

  void _abrirQr(
    Map<String, dynamic> tienda,
    String sessionId, {
    String? qrToken,
  }) {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => QRScreen(
          idTienda: tienda['id_tienda'] as String,
          nombreTienda: tienda['nombre'] as String,
          direccion: tienda['direccion'] as String,
          correo: tienda['correo'] as String,
          sessionId: sessionId,
          qrToken: qrToken,
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
