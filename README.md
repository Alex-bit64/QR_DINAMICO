# QR Dinámico

Aplicación Flutter para mostrar el QR dinámico de una tienda. Funciona en
Android, iOS, Windows, macOS y Linux con una única base de código responsiva.

## Flujo de sesión

Antes de abrir el QR, la aplicación valida:

1. formato de correo y contraseña;
2. credenciales y datos completos de la tienda en Supabase;
3. existencia del token QR;
4. servicio y permiso de ubicación;
5. coordenadas válidas;
6. disponibilidad de la sesión de la tienda.

Con el QR abierto se ejecuta un pulso cada 15 segundos. Cada pulso obtiene una
ubicación nueva y envía conjuntamente `id_tienda`, `session_id`, plataforma,
latitud, longitud y precisión a Supabase. El servidor solo actualiza la fila si
la sesión sigue siendo la propietaria de la tienda.

La sesión persiste aunque la aplicación se cierre o el dispositivo se apague.
Solo el botón **Cerrar sesión** libera la tienda en Supabase. Al volver a abrir
la aplicación en el mismo dispositivo, se reutiliza el `session_id` almacenado
localmente. Cuando la ubicación no puede comprobarse, el QR se oculta hasta que
la validación vuelva a ser correcta, pero la sesión continúa reservada.

La columna `qr.ubicacion` usa esta estructura:

```json
{
  "inicio_sesion": {
    "latitud": -12.0,
    "longitud": -77.0,
    "precision_metros": 10.0,
    "dispositivo": "windows",
    "actualizada_en": "2026-07-22T12:00:00-05:00"
  },
  "actual": {
    "latitud": -12.0,
    "longitud": -77.0,
    "precision_metros": 10.0,
    "dispositivo": "windows",
    "actualizada_en": "2026-07-22T12:00:15-05:00"
  }
}
```

`inicio_sesion` se fija al ingresar y `actual` se reemplaza en cada pulso. La
clave antigua `horario_salida` se elimina de la fila cuando la sesión se
renueva.

## Configurar Supabase

Antes de ejecutar esta versión, abre el SQL Editor del proyecto Supabase y
ejecuta el contenido completo de [`supabase_rpc.sql`](supabase_rpc.sql). La app
y las funciones RPC deben actualizarse juntas porque cambian las firmas de:

- `iniciar_sesion_tienda`
- `renovar_sesion_tienda`

El cliente usa una clave publicable. Nunca coloques una clave `service_role` o
secreta dentro de Flutter.

## Ejecutar

```bash
flutter pub get
flutter run -d windows
```

También puedes usar `-d android`, `-d ios`, `-d macos` o `-d linux` en el
sistema operativo correspondiente.

Builds de escritorio:

```bash
flutter build windows
flutter build macos
flutter build linux
```

La ubicación del sistema debe estar activada. En Windows se controla desde
Privacidad y seguridad > Ubicación; en macOS desde Privacidad y seguridad >
Localización. Linux requiere que el servicio GeoClue esté disponible.

## Verificación

```bash
flutter analyze
flutter test
flutter build windows
```
