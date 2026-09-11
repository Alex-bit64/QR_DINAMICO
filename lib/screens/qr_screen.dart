import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../app_visuals.dart';
import '../services/sesion_local_service.dart';
import '../services/supabase_service.dart';
import '../services/ubicacion_service.dart';
import 'login_tienda_screen.dart';

class QRScreen extends StatefulWidget {
  final String idTienda;
  final String nombreTienda;
  final String direccion;
  final String correo;
  final String sessionId;

  const QRScreen({
    super.key,
    required this.idTienda,
    required this.nombreTienda,
    required this.direccion,
    required this.correo,
    required this.sessionId,
  });

  @override
  State<QRScreen> createState() => _QRScreenState();
}

class _QRScreenState extends State<QRScreen> with WidgetsBindingObserver {
  final _supabaseService = SupabaseService.instance;
  final _ubicacionService = UbicacionService.instance;
  final _sesionLocalService = SesionLocalService.instance;

  String _qrData = '';
  bool _cargando = true;
  bool _generandoQr = false;
  bool _renovandoSesion = false;
  bool _sesionValida = true;
  String? _errorQr;
  DateTime? _ultimaUbicacionEn;
  int _segundosRestantes = 30;
  Timer? _timerQr;
  Timer? _timerSesion;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_prepararQr());
    _iniciarTimers();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timerQr?.cancel();
    _timerSesion?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_reanudar());
    }
  }

  Future<void> _reanudar() async {
    await _renovarSesion();
    if (mounted && _sesionValida) {
      await _prepararQr(mostrarCarga: false);
    }
  }

  void _iniciarTimers() {
    _timerQr?.cancel();
    _timerSesion?.cancel();

    _timerQr = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _cargando || _errorQr != null) return;
      if (_segundosRestantes <= 1) {
        unawaited(_prepararQr(mostrarCarga: false));
      } else {
        setState(() => _segundosRestantes--);
      }
    });

    _timerSesion = Timer.periodic(const Duration(seconds: 15), (_) {
      unawaited(_renovarSesion());
    });
  }

  Future<void> _renovarSesion() async {
    if (_renovandoSesion || !mounted) return;
    _renovandoSesion = true;

    try {
      final validacion = await _supabaseService.validarSesionTienda(
        idTienda: widget.idTienda,
        sessionId: widget.sessionId,
      );
      if (validacion['permitido'] != true && mounted) {
        await _cerrarPorCambioRemoto(validacion);
        return;
      }

      final ubicacion = await _ubicacionService.obtenerActual(
        solicitarPermiso: false,
      );
      final sesion = await _supabaseService.renovarSesionTienda(
        idTienda: widget.idTienda,
        sessionId: widget.sessionId,
        dispositivo: _ubicacionService.dispositivo,
        latitud: ubicacion.latitude,
        longitud: ubicacion.longitude,
        precisionMetros: ubicacion.accuracy,
      );

      if (sesion['permitido'] != true && mounted) {
        await _cerrarPorCambioRemoto(sesion);
        return;
      }

      if (!mounted) return;
      final debeRegenerarQr = !_sesionValida || _qrData.isEmpty;
      setState(() {
        _sesionValida = true;
        _ultimaUbicacionEn = DateTime.now();
        _errorQr = null;
      });
      if (debeRegenerarQr) {
        await _prepararQr(mostrarCarga: false);
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _sesionValida = false;
        _qrData = '';
        _errorQr =
            'QR pausado: ${_mensajeError(error)} La aplicación volverá a '
            'comprobarlo automáticamente.';
        _cargando = false;
      });
    } finally {
      _renovandoSesion = false;
    }
  }

  Future<void> _cerrarPorCambioRemoto(Map<String, dynamic> sesion) async {
    _timerQr?.cancel();
    _timerSesion?.cancel();
    final mensaje =
        (sesion['mensaje'] ??
                'La sesión fue cerrada desde Supabase o desde otro lugar.')
            .toString();
    await _volverAlLogin(mensaje: mensaje);
  }

  Future<void> _prepararQr({bool mostrarCarga = true}) async {
    if (!_sesionValida || _generandoQr || !mounted) return;
    _generandoQr = true;
    setState(() {
      _cargando = mostrarCarga;
      _errorQr = null;
    });

    try {
      final qr = await _supabaseService.obtenerPayloadQrTienda(
        idTienda: widget.idTienda,
        sessionId: widget.sessionId,
      );
      final payload = qr['payload']?.toString().trim() ?? '';
      if (payload.isEmpty) throw Exception('El QR temporal llegó vacío.');

      if (!mounted) return;
      setState(() {
        _qrData = payload;
        _segundosRestantes = 30;
        _cargando = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _qrData = '';
        _errorQr =
            'No se pudo obtener un QR actualizado. Revisa la conexión; la '
            'aplicación volverá a intentarlo.';
        _cargando = false;
      });
    } finally {
      _generandoQr = false;
    }
  }

  Future<void> _reintentarTodo() async {
    await _renovarSesion();
    if (_sesionValida && _qrData.isEmpty) {
      await _prepararQr();
    }
  }

  Future<void> _volverAlLogin({String? mensaje}) async {
    await _sesionLocalService.limpiar();
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => LoginTiendaScreen(mensajeInicial: mensaje),
      ),
    );
  }

  String _mensajeError(Object error) {
    if (error is UbicacionException) return error.mensaje;
    return 'No se pudo comunicar con el servidor.';
  }

  Future<void> _cerrarSesion() async {
    final brightness = Theme.of(context).brightness;
    final confirmar = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppPalette.panelColor(brightness),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Text(
          'Cerrar sesion',
          style: GoogleFonts.bebasNeue(
            color: AppPalette.textColor(brightness),
            fontSize: 22,
            letterSpacing: 1,
          ),
        ),
        content: Text(
          'Seguro que quieres cerrar sesion en esta tienda?',
          style: GoogleFonts.robotoCondensed(
            color: AppPalette.mutedTextColor(brightness),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar', style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Cerrar sesion',
              style: TextStyle(color: AppPalette.teal),
            ),
          ),
        ],
      ),
    );

    if (confirmar != true) return;

    try {
      await _supabaseService.cerrarSesionTienda(
        idTienda: widget.idTienda,
        sessionId: widget.sessionId,
      );
      await _volverAlLogin();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'No se pudo cerrar la sesión. Comprueba la conexión y vuelve a '
            'intentarlo. La sesión continúa abierta. ${_mensajeError(error)}',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final textColor = AppPalette.textColor(brightness);
    final mutedColor = AppPalette.mutedTextColor(brightness);

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        titleSpacing: 20,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'QR TIENDA',
              style: GoogleFonts.bebasNeue(
                fontSize: 20,
                letterSpacing: 2.4,
                color: textColor,
              ),
            ),
            Text(
              widget.nombreTienda,
              style: GoogleFonts.robotoCondensed(
                fontSize: 12,
                color: mutedColor,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.logout, color: textColor),
            onPressed: _cerrarSesion,
            tooltip: 'Cerrar sesion',
          ),
        ],
      ),
      body: AppBackground(
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final horizontalPadding = constraints.maxWidth < 380
                  ? 18.0
                  : 24.0;
              const topPadding = 76.0;
              const bottomPadding = 12.0;
              final panelWidth = math.min(
                420.0,
                constraints.maxWidth - (horizontalPadding * 2),
              );
              final availablePanelHeight = math.max(
                0.0,
                constraints.maxHeight - topPadding - bottomPadding,
              );
              final compact = availablePanelHeight < 650 || panelWidth < 340;
              final qrSizeByWidth = panelWidth - (compact ? 106.0 : 116.0);
              final qrSizeByHeight =
                  availablePanelHeight * (compact ? 0.32 : 0.36);
              final qrSize = math
                  .min(qrSizeByWidth, qrSizeByHeight)
                  .clamp(190.0, 260.0)
                  .toDouble();

              return Padding(
                padding: EdgeInsets.fromLTRB(
                  horizontalPadding,
                  topPadding,
                  horizontalPadding,
                  bottomPadding,
                ),
                child: Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: 420,
                      maxHeight: availablePanelHeight,
                    ),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.topCenter,
                      child: SizedBox(
                        width: panelWidth,
                        child: FrostedPanel(
                          padding: EdgeInsets.fromLTRB(
                            compact ? 18 : 22,
                            compact ? 18 : 22,
                            compact ? 18 : 22,
                            compact ? 18 : 20,
                          ),
                          child: _buildContent(
                            qrSize: qrSize,
                            compact: compact,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildContent({required double qrSize, required bool compact}) {
    final brightness = Theme.of(context).brightness;
    final textColor = AppPalette.textColor(brightness);
    final mutedColor = AppPalette.mutedTextColor(brightness);

    if (_cargando) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 56),
        child: Center(
          child: CircularProgressIndicator(color: AppPalette.turquoise),
        ),
      );
    }

    if (_errorQr != null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.qr_code_2_rounded,
            size: 54,
            color: textColor.withValues(alpha: 0.88),
          ),
          const SizedBox(height: 16),
          Text(
            _errorQr!,
            textAlign: TextAlign.center,
            style: GoogleFonts.robotoCondensed(
              fontSize: 16,
              height: 1.35,
              color: textColor,
            ),
          ),
          const SizedBox(height: 22),
          ElevatedButton(
            onPressed: _renovandoSesion ? null : _reintentarTodo,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppPalette.primaryDark,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            child: Text(
              'Reintentar',
              style: GoogleFonts.robotoCondensed(
                fontSize: 15,
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      );
    }

    final qrCardPadding = compact ? 12.0 : 14.0;
    final qrWhitePadding = compact ? 22.0 : 28.0;
    final qrWhiteSize = qrSize + (qrWhitePadding * 2);
    final gapLarge = compact ? 16.0 : 22.0;
    final titleSize = compact ? 26.0 : 30.0;

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: double.infinity,
          padding: EdgeInsets.all(qrCardPadding),
          decoration: BoxDecoration(
            color: AppPalette.panelColor(brightness).withValues(alpha: 0.82),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AppPalette.borderColor(brightness)),
          ),
          child: Column(
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [AppPalette.teal, AppPalette.turquoise],
                    ),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    'Activo',
                    style: GoogleFonts.robotoCondensed(
                      fontSize: 12,
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1,
                    ),
                  ),
                ),
              ),
              SizedBox(height: compact ? 10 : 12),
              Container(
                width: qrWhiteSize,
                height: qrWhiteSize,
                alignment: Alignment.center,
                padding: EdgeInsets.all(qrWhitePadding),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(28),
                  boxShadow: [
                    BoxShadow(
                      color: AppPalette.teal.withValues(alpha: 0.18),
                      blurRadius: 26,
                      offset: const Offset(0, 12),
                    ),
                  ],
                ),
                child: SizedBox.square(
                  dimension: qrSize,
                  child: QrImageView(
                    data: _qrData,
                    size: qrSize,
                    padding: EdgeInsets.zero,
                    backgroundColor: Colors.white,
                    errorCorrectionLevel: QrErrorCorrectLevel.H,
                  ),
                ),
              ),
            ],
          ),
        ),
        SizedBox(height: gapLarge),
        Text(
          widget.nombreTienda.toUpperCase(),
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: GoogleFonts.bebasNeue(
            fontSize: titleSize,
            color: textColor,
            letterSpacing: 2.2,
          ),
        ),
        SizedBox(height: compact ? 4 : 6),
        Text(
          widget.correo,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: GoogleFonts.robotoCondensed(
            fontSize: compact ? 14 : 15,
            color: mutedColor,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          widget.direccion,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: GoogleFonts.robotoCondensed(
            fontSize: compact ? 12 : 13,
            height: 1.35,
            color: mutedColor.withValues(alpha: 0.82),
            letterSpacing: 0.4,
          ),
        ),
        SizedBox(height: gapLarge),
        Container(
          width: double.infinity,
          padding: EdgeInsets.symmetric(
            horizontal: 18,
            vertical: compact ? 12 : 14,
          ),
          decoration: BoxDecoration(
            color: AppPalette.success.withValues(alpha: 0.12),
            border: Border.all(
              color: AppPalette.success.withValues(alpha: 0.42),
            ),
            borderRadius: BorderRadius.circular(22),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.lock_clock_outlined,
                color: AppPalette.success,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _ultimaUbicacionEn == null
                      ? 'Ubicación validada'
                      : 'Ubicación actualizada cada 15 segundos',
                  style: GoogleFonts.robotoCondensed(
                    fontSize: compact ? 14 : 15,
                    color: AppPalette.success,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ],
          ),
        ),
        SizedBox(height: compact ? 10 : 14),
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            value: _segundosRestantes / 30,
            minHeight: 8,
            backgroundColor: AppPalette.borderColor(brightness),
            valueColor: const AlwaysStoppedAnimation<Color>(AppPalette.success),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Actualiza en $_segundosRestantes segundos',
          textAlign: TextAlign.center,
          style: GoogleFonts.robotoCondensed(
            fontSize: 13,
            color: mutedColor,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
