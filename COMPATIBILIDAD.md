# Compatibilidad de QR Sucursal

## Windows

- Arquitectura distribuida: x64.
- Sistemas soportados: Windows 10 y Windows 11 de 64 bits.
- Pantallas: la ventana inicial se adapta al área útil, incluidas resoluciones
  antiguas como 1024x600 y 1366x768.
- El paquete portátil incluye las DLL de Flutter, los plugins, los recursos y
  las bibliotecas de Microsoft Visual C++.

Una laptop fabricada desde 2015 normalmente es compatible si ejecuta Windows 10
o Windows 11 de 64 bits. Windows 7, Windows 8 y Windows de 32 bits no están
soportados por la versión actual de Flutter.

## Android

- Versión mínima: Android 7.0, API 24.
- Arquitecturas incluidas en el APK universal:
  - ARM de 32 bits (`armeabi-v7a`).
  - ARM de 64 bits (`arm64-v8a`).
  - x64 (`x86_64`).
- Requiere conexión a internet, ubicación activa y permiso de ubicación.

Android 6 y versiones anteriores no están soportados por la versión actual de
Flutter ni por las versiones actuales de varios plugins del proyecto.

## iPhone

- Versión mínima configurada: iOS 13.
- Por ejemplo, un iPhone 6s de 2015 puede ejecutar versiones de iOS superiores
  a ese mínimo.
- El proyecto se compila en macOS mediante el flujo `ios-test-build` de
  Codemagic. El artefacto sin firma valida compilación; instalarlo exige firma
  y un perfil de aprovisionamiento de Apple.

La antigüedad del dispositivo no garantiza por sí sola la compatibilidad. La
versión del sistema operativo, la arquitectura y la disponibilidad de ubicación
son los criterios determinantes.
