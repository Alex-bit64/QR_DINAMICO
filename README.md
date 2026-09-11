# QR Dinámico

Aplicación Flutter para mostrar el QR dinámico de una tienda. Funciona en
Android, iOS, Windows, macOS y Linux con una única base de código responsiva.

## Flujo de sesión

Antes de abrir el QR, la aplicación valida:

1. formato de correo y contraseña;
2. ubicación activa, permiso concedido y coordenadas válidas;
3. credenciales y datos completos de la tienda en Supabase;
4. disponibilidad de la sesión de la tienda.

El inicio seguro autentica y reserva la tienda en una única operación del
servidor. El cliente nunca recibe ni almacena el token QR estático. Supabase
genera el contenido temporal del QR con su propio reloj, evitando errores por
la hora desconfigurada del dispositivo.

Con el QR abierto se ejecuta un pulso cada 15 segundos. Cada pulso obtiene una
ubicación nueva y envía conjuntamente `id_tienda`, `session_id`, plataforma,
latitud, longitud y precisión a Supabase. El servidor solo actualiza la fila si
la sesión sigue siendo la propietaria de la tienda.

La sesión persiste aunque la aplicación se cierre o el dispositivo se apague.
Solo el botón **Cerrar sesión** libera la tienda en Supabase. Al volver a abrir
la aplicación en el mismo dispositivo, se reutiliza el `session_id` almacenado
en el almacén seguro del sistema (Keychain, Keystore o protección nativa de
Windows). Cuando la ubicación no puede comprobarse, el QR se oculta hasta que
la validación vuelva a ser correcta, pero la sesión continúa reservada.

Si se cambia manualmente `qr.usado` a `false` o `qr.session_id` a `NULL`, la
aplicación lo detecta en el siguiente pulso (máximo 15 segundos), borra la
sesión local y vuelve al inicio de sesión.

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

## Actualizar Supabase

En una base que ya tiene la versión anterior, aplica esta migración desde el SQL
Editor o con Supabase CLI:

- [`20260911044121_endurecer_sesion_qr_tienda.sql`](supabase/migrations/20260911044121_endurecer_sesion_qr_tienda.sql)

Para una instalación nueva se puede ejecutar completo
[`supabase_rpc.sql`](supabase_rpc.sql); ya contiene las mismas protecciones. La
migración convierte de forma transparente las contraseñas existentes a bcrypt,
limita intentos de acceso, activa RLS y retira del rol público los RPC que
exponían datos o permitían reservar una tienda conociendo solo su identificador.

El cliente usa una clave publicable. Nunca coloques una clave `service_role` o
secreta dentro de Flutter.

## iOS con Codemagic

[`codemagic.yaml`](codemagic.yaml) replica el flujo de `trabajador_app` con
Flutter 3.41.9: instala CocoaPods, analiza, ejecuta pruebas y genera
`build/ios/iphoneos/Runner.app` sin firma. Para instalar en iPhone o publicar en
App Store se debe configurar la firma de Apple en Codemagic; el build sin firma
sirve para validar que el proyecto compila correctamente en macOS.

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
flutter build apk --release
```

El resultado de la auditoría interna y sus controles se encuentra en
[`AUDITORIA_INTERNA.md`](AUDITORIA_INTERNA.md).
