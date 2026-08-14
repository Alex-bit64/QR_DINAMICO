import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppPalette {
  static const Color primaryDark = Color(0xFF1E3A8A);
  static const Color sky = Color(0xFF60A5FA);
  static const Color turquoise = Color(0xFF3EE0C2);
  static const Color teal = Color(0xFF1CA7A1);
  static const Color night = Color(0xFF06111F);
  static const Color lightSurface = Color(0xFFEAF7FF);
  static const Color darkCard = Color(0xD9091729);
  static const Color lightCard = Color(0xEFFFFFFF);
  static const Color darkBorder = Color(0x553EE0C2);
  static const Color lightBorder = Color(0x662F80ED);
  static const Color darkTextMuted = Color(0xB3FFFFFF);
  static const Color lightTextMuted = Color(0xCC1E3A8A);
  static const Color success = Color(0xFF3EE0C2);

  static Color panelColor(Brightness brightness) =>
      brightness == Brightness.dark ? darkCard : lightCard;

  static Color borderColor(Brightness brightness) =>
      brightness == Brightness.dark ? darkBorder : lightBorder;

  static Color textColor(Brightness brightness) =>
      brightness == Brightness.dark ? Colors.white : primaryDark;

  static Color mutedTextColor(Brightness brightness) =>
      brightness == Brightness.dark ? darkTextMuted : lightTextMuted;
}

class AppThemeController {
  static final ValueNotifier<ThemeMode> mode = ValueNotifier(ThemeMode.dark);

  static void toggle() {
    mode.value = mode.value == ThemeMode.dark
        ? ThemeMode.light
        : ThemeMode.dark;
  }
}

class AppTheme {
  static String backgroundFor(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return brightness == Brightness.dark
        ? 'lib/assets/fondo2.png'
        : 'lib/assets/fondo1.png';
  }

  static Color glassBorder(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return brightness == Brightness.dark
        ? Colors.white.withValues(alpha: 0.1)
        : Colors.black.withValues(alpha: 0.1);
  }
}

class AppBackgroundImage extends StatelessWidget {
  const AppBackgroundImage({super.key});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth > constraints.maxHeight;

        return Image.asset(
          AppTheme.backgroundFor(context),
          width: constraints.maxWidth,
          height: constraints.maxHeight,
          // Los fondos originales son verticales. En escritorio, cover recorta
          // las decoraciones de las esquinas y deja visible solo el centro.
          fit: isWide ? BoxFit.fill : BoxFit.cover,
          filterQuality: FilterQuality.high,
        );
      },
    );
  }
}

class AppBackground extends StatelessWidget {
  const AppBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final isDark = brightness == Brightness.dark;

    return Stack(
      fit: StackFit.expand,
      children: [
        const AppBackgroundImage(),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: isDark
                  ? [
                      Colors.black.withValues(alpha: 0.14),
                      AppPalette.night.withValues(alpha: 0.42),
                      AppPalette.night.withValues(alpha: 0.74),
                    ]
                  : [
                      Colors.white.withValues(alpha: 0.10),
                      AppPalette.lightSurface.withValues(alpha: 0.34),
                      Colors.white.withValues(alpha: 0.66),
                    ],
            ),
          ),
        ),
        child,
      ],
    );
  }
}

class FrostedPanel extends StatelessWidget {
  const FrostedPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(24),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;

    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: AppPalette.panelColor(brightness),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppPalette.borderColor(brightness)),
        boxShadow: [
          BoxShadow(
            color: AppPalette.primaryDark.withValues(
              alpha: brightness == Brightness.dark ? 0.34 : 0.14,
            ),
            blurRadius: 28,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: child,
    );
  }
}

InputDecoration appInputDecoration({
  required BuildContext context,
  required String hintText,
  Widget? suffixIcon,
}) {
  final brightness = Theme.of(context).brightness;
  final isDark = brightness == Brightness.dark;

  return InputDecoration(
    filled: true,
    fillColor: isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.white.withValues(alpha: 0.78),
    hintText: hintText,
    hintStyle: GoogleFonts.robotoCondensed(
      color: AppPalette.mutedTextColor(brightness).withValues(alpha: 0.7),
      fontSize: 15,
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(18),
      borderSide: BorderSide(color: AppPalette.borderColor(brightness)),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(18),
      borderSide: const BorderSide(color: AppPalette.turquoise, width: 1.5),
    ),
    contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
    suffixIcon: suffixIcon,
  );
}
