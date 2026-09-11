import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_visuals.dart';
import 'screens/login_tienda_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS)) {
    await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  }
  await Supabase.initialize(
    url: SupabaseOptions.supabaseUrl,
    publishableKey: SupabaseOptions.supabaseKey,
  );
  runApp(const QRApp());
}

class SupabaseOptions {
  static const String supabaseUrl = 'https://tlmsnenvqqblmmtimung.supabase.co';
  static const String supabaseKey =
      'sb_publishable_wnlnQ6sVmbsvHjklJx1uOw_sxhxC2aw';
}

class QRApp extends StatelessWidget {
  const QRApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: AppThemeController.mode,
      builder: (context, themeMode, _) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'QR Sucursal',
          themeMode: themeMode,
          theme: ThemeData(
            brightness: Brightness.light,
            scaffoldBackgroundColor: AppPalette.lightSurface,
            colorScheme: const ColorScheme.light(
              primary: AppPalette.primaryDark,
              secondary: AppPalette.teal,
              tertiary: AppPalette.turquoise,
              surface: AppPalette.lightSurface,
            ),
            textTheme: GoogleFonts.robotoCondensedTextTheme(
              ThemeData.light().textTheme,
            ),
            snackBarTheme: SnackBarThemeData(
              backgroundColor: AppPalette.primaryDark,
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
          darkTheme: ThemeData(
            brightness: Brightness.dark,
            scaffoldBackgroundColor: AppPalette.night,
            colorScheme: const ColorScheme.dark(
              primary: AppPalette.sky,
              secondary: AppPalette.turquoise,
              tertiary: AppPalette.teal,
              surface: AppPalette.night,
            ),
            textTheme: GoogleFonts.robotoCondensedTextTheme(
              ThemeData.dark().textTheme,
            ),
            snackBarTheme: SnackBarThemeData(
              backgroundColor: AppPalette.primaryDark,
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
          home: const LoginTiendaScreen(),
        );
      },
    );
  }
}
