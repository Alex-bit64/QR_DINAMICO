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
- [`20260915071642_sistema_actualizacion_multiplataforma.sql`](supabase/migrations/20260915071642_sistema_actualizacion_multiplataforma.sql)

Para una instalación nueva se ejecuta primero
[`supabase_rpc.sql`](supabase_rpc.sql) y después la migración del sistema de
actualizaciones. El instalador base ya contiene las protecciones de la primera
migración: convierte de forma transparente las contraseñas existentes a bcrypt,
limita intentos de acceso, activa RLS y retira del rol público los RPC que
exponían datos o permitían reservar una tienda conociendo solo su identificador.

La segunda migración crea el catálogo de versiones, el bucket público de solo
descarga y los RPC compatibles que registran la versión del dispositivo activo.
Si la primera migración ya fue ejecutada, solo se debe ejecutar la segunda.

El cliente usa una clave publicable. Nunca coloques una clave `service_role` o
secreta dentro de Flutter.

## Actualizaciones desde Supabase

Al abrir la aplicación, Android, iOS, Windows, macOS y Linux consultan el RPC
`obtener_actualizacion_aplicacion`. Si el `build_publicado` de su plataforma es
mayor que el build instalado, aparece un aviso con **Actualizar**, **Ahora no**
y un botón de cierre. Cancelarlo no bloquea el QR ni se guarda como una decisión
permanente: el aviso vuelve a mostrarse al abrir de nuevo la aplicación.

La fila activa de `qr` registra `version_aplicacion`, `build_aplicacion`,
`plataforma_aplicacion` y `version_actualizada_en`. Esos datos se escriben al
iniciar sesión y se refrescan junto con la ubicación cada 15 segundos. Las
versiones publicadas viven en `version_aplicacion`; RLS permite a la app leer
solo filas activas y no le permite modificarlas.

La migración deja Android y Windows en `activa=false` para que nunca se muestre
un enlace roto. Para publicar `1.2.0+3`:

1. Cargar el APK en el bucket `actualizaciones` con la ruta
   `qr-sucursal/android/qr-sucursal.apk`.
2. Cargar el ZIP completo de Windows con la ruta
   `qr-sucursal/windows/QR_Sucursal_Windows_x64_COMPLETO.zip`.
3. Comprobar ambas descargas y cambiar a `true` la columna `activa` de Android y
   Windows en la tabla `version_aplicacion`.

El APK de distribución se genera para `android-arm` y `android-arm64`, las dos
arquitecturas de celulares físicos antiguos y modernos. Pesa menos de 50 MB y
puede cargarse en Supabase Free. Los emuladores Android x86 no están incluidos
en ese APK de distribución.

Para cada actualización futura se incrementan siempre la versión y el build de
`pubspec.yaml`, se reemplaza el archivo de la plataforma y después se actualizan
`version_publicada`, `build_publicado`, `mensaje`, `sha256` y
`actualizada_en=now()` en Supabase. En iOS se crea una fila `ios` cuya
`url_descarga` sea el enlace de TestFlight o App Store; iOS no instala APK.

La versión `1.2.0+3` debe instalarse una vez por el método actual, porque las
versiones anteriores no contienen el comprobador. A partir de esta versión los
avisos se administran desde Supabase. Android seguirá mostrando su confirmación
normal de instalación y el APK nuevo debe conservar el mismo `applicationId` y
el mismo certificado de firma que la aplicación instalada.

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
flutter build apk --release --target-platform android-arm,android-arm64
```

El resultado de la auditoría interna y sus controles se encuentra en
[`AUDITORIA_INTERNA.md`](AUDITORIA_INTERNA.md).
