# Auditoría interna — QR Sucursal 1.1.0

Fecha: 10 de septiembre de 2026.

## Alcance

Se revisaron el cliente Flutter, el flujo de sesión y ubicación, los RPC de
Supabase, el almacenamiento local y la configuración de Android, iOS, macOS,
Windows, Linux y Codemagic.

## Problemas corregidos

### Críticos

- El cliente obtenía y conservaba el token QR estático. Ahora solo solicita a
  Supabase un payload temporal asociado a la sesión activa.
- El inicio de sesión y la reserva de tienda eran dos operaciones separadas, y
  el RPC de reserva aceptaba un `id_tienda` sin autenticar. El nuevo RPC
  `iniciar_sesion_tienda_segura` autentica y reserva de forma atómica.
- Las contraseñas se comparaban como texto legible. La migración las convierte
  a bcrypt y mantiene el inicio heredado fuera del acceso público.
- Funciones y tablas sensibles tenían permisos públicos demasiado amplios. Se
  habilitó RLS, se retiró acceso directo a `tienda` y `qr`, y se concedieron
  únicamente los RPC necesarios.

### Altos y medios

- Se añadió un límite de cinco intentos fallidos por correo/IP durante una
  ventana de 15 minutos.
- El `session_id` dejó de almacenarse en preferencias legibles y usa el almacén
  seguro de cada plataforma. Las sesiones antiguas se migran automáticamente.
- El QR ya no depende del reloj local; el servidor genera la ventana temporal.
- La restauración comprueba que `usado=true` y que `session_id` todavía
  coincide. Un cierre manual en la base se refleja en la app en hasta 15
  segundos.
- Se actualizaron dependencias compatibles y se fijaron versiones exactas para
  builds reproducibles.
- Se normalizaron el namespace Android, los identificadores de las plataformas
  Apple y los metadatos de escritorio. El `applicationId` Android publicado se
  conserva para que la actualización mantenga datos y sesión de instalaciones
  existentes.
- Se configuró Keychain para que la sesión segura persista en iOS y macOS.
- Se añadió el Podfile iOS y el flujo Codemagic de análisis, pruebas y build sin
  firma.
- Se eliminó `lib.zip`, una copia obsoleta que contenía código de una versión
  anterior y podía confundirse con la fuente vigente del proyecto.

## Controles funcionales

- La ubicación se valida antes del acceso y se actualiza cada 15 segundos.
- Una pérdida temporal de red o ubicación oculta el QR, pero no libera la
  tienda ni borra la sesión.
- La sesión solo se libera mediante **Cerrar sesión** o al cambiarla
  explícitamente en Supabase.
- Otra computadora o celular no puede tomar una tienda mientras la fila siga
  marcada como usada por una sesión distinta.

## Verificación y límite del entorno

Se ejecutan `flutter analyze`, pruebas automatizadas y builds release de
Windows y Android antes de publicar. El build iOS debe ejecutarse en Codemagic,
porque Xcode solo está disponible en macOS.

La migración está versionada, pero debe aplicarse al proyecto Supabase antes de
considerar desplegadas las correcciones del servidor. El CLI de este equipo no
tiene una sesión de Supabase iniciada, por lo que no se modifica la base remota
desde este repositorio.
