# Distribución de QR Sucursal para Windows

No se debe copiar solamente el archivo `qr_sucursal.exe`.

Para usar la aplicación en otra computadora:

1. Copia el archivo `QR_Sucursal_Windows_Portable.zip`.
2. En la computadora de destino, extrae todo el ZIP en una carpeta.
3. Ejecuta `qr_sucursal.exe` dentro de esa carpeta.
4. No muevas el ejecutable fuera de la carpeta ni elimines `data` o las DLL.

El paquete incluye:

- `qr_sucursal.exe`
- `flutter_windows.dll`
- Las DLL de los plugins usados por la aplicación.
- La carpeta `data` con los recursos Flutter.
- Las bibliotecas de ejecución de Microsoft Visual C++ requeridas.

No es necesario instalar Flutter ni volver a compilar en la computadora de
destino. El paquete generado es para equipos Windows x64.
