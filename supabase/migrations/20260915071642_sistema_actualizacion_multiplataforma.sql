BEGIN;

-- Catálogo público de la última versión disponible por plataforma. Solo el
-- Dashboard o una clave de servicio pueden modificarlo; la aplicación puede
-- leer exclusivamente las filas que estén activas.
CREATE TABLE IF NOT EXISTS public.version_aplicacion (
    plataforma TEXT PRIMARY KEY,
    version_publicada TEXT NOT NULL,
    build_publicado INTEGER NOT NULL,
    url_descarga TEXT NOT NULL,
    sha256 TEXT,
    mensaje TEXT NOT NULL DEFAULT 'Hay una nueva versión disponible.',
    activa BOOLEAN NOT NULL DEFAULT FALSE,
    actualizada_en TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT version_aplicacion_plataforma_valida CHECK (
        plataforma IN ('android', 'ios', 'windows', 'macos', 'linux')
    ),
    CONSTRAINT version_aplicacion_version_no_vacia CHECK (
        char_length(btrim(version_publicada)) BETWEEN 1 AND 32
    ),
    CONSTRAINT version_aplicacion_build_valido CHECK (build_publicado >= 1),
    CONSTRAINT version_aplicacion_url_https CHECK (
        url_descarga ~ '^https://[^[:space:]]+$'
    ),
    CONSTRAINT version_aplicacion_sha256_valido CHECK (
        sha256 IS NULL OR sha256 ~ '^[0-9a-fA-F]{64}$'
    )
);

ALTER TABLE public.version_aplicacion ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.version_aplicacion
FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.version_aplicacion TO anon, authenticated;

DROP POLICY IF EXISTS version_aplicacion_lectura_activa
ON public.version_aplicacion;
CREATE POLICY version_aplicacion_lectura_activa
ON public.version_aplicacion
FOR SELECT
TO anon, authenticated
USING (activa = TRUE);

-- Registra qué versión posee el dispositivo que actualmente conserva la
-- sesión. No identifica a una persona ni mantiene un historial de ubicación.
ALTER TABLE public.qr
ADD COLUMN IF NOT EXISTS version_aplicacion TEXT,
ADD COLUMN IF NOT EXISTS build_aplicacion INTEGER,
ADD COLUMN IF NOT EXISTS plataforma_aplicacion TEXT,
ADD COLUMN IF NOT EXISTS version_actualizada_en TIMESTAMPTZ;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_catalog.pg_constraint
        WHERE conname = 'qr_version_aplicacion_valida'
          AND conrelid = 'public.qr'::regclass
    ) THEN
        ALTER TABLE public.qr
        ADD CONSTRAINT qr_version_aplicacion_valida CHECK (
            version_aplicacion IS NULL
            OR char_length(btrim(version_aplicacion)) BETWEEN 1 AND 32
        );
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_catalog.pg_constraint
        WHERE conname = 'qr_build_aplicacion_valido'
          AND conrelid = 'public.qr'::regclass
    ) THEN
        ALTER TABLE public.qr
        ADD CONSTRAINT qr_build_aplicacion_valido CHECK (
            build_aplicacion IS NULL OR build_aplicacion >= 0
        );
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_catalog.pg_constraint
        WHERE conname = 'qr_plataforma_aplicacion_valida'
          AND conrelid = 'public.qr'::regclass
    ) THEN
        ALTER TABLE public.qr
        ADD CONSTRAINT qr_plataforma_aplicacion_valida CHECK (
            plataforma_aplicacion IS NULL
            OR plataforma_aplicacion IN (
                'android', 'ios', 'windows', 'macos', 'linux'
            )
        );
    END IF;
END;
$$;

-- El cliente compara por build, que es un entero monotónico y evita errores al
-- ordenar versiones semánticas como 1.10.0 y 1.9.0.
CREATE OR REPLACE FUNCTION public.obtener_actualizacion_aplicacion(
    p_plataforma TEXT,
    p_version_actual TEXT,
    p_build_actual INTEGER
) RETURNS TABLE (
    disponible BOOLEAN,
    plataforma TEXT,
    version_actual TEXT,
    build_actual INTEGER,
    version_publicada TEXT,
    build_publicado INTEGER,
    url_descarga TEXT,
    sha256 TEXT,
    mensaje TEXT
) LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
    SELECT
        v.build_publicado > GREATEST(COALESCE(p_build_actual, 0), 0),
        v.plataforma,
        left(btrim(COALESCE(p_version_actual, '')), 32),
        GREATEST(COALESCE(p_build_actual, 0), 0),
        v.version_publicada,
        v.build_publicado,
        v.url_descarga,
        lower(v.sha256),
        v.mensaje
    FROM public.version_aplicacion v
    WHERE v.plataforma = lower(btrim(COALESCE(p_plataforma, '')))
      AND v.activa = TRUE
    LIMIT 1;
$$;

REVOKE ALL ON FUNCTION public.obtener_actualizacion_aplicacion(
    TEXT, TEXT, INTEGER
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.obtener_actualizacion_aplicacion(
    TEXT, TEXT, INTEGER
) TO anon, authenticated;

-- Sobrecarga compatible del inicio seguro. Reutiliza toda la autenticación y
-- reserva atómica ya auditada, y solo anota la versión si la sesión fue tomada.
CREATE OR REPLACE FUNCTION public.iniciar_sesion_tienda_segura(
    p_correo TEXT,
    p_contrasena TEXT,
    p_session_id TEXT,
    p_dispositivo TEXT,
    p_latitud DOUBLE PRECISION,
    p_longitud DOUBLE PRECISION,
    p_precision_metros DOUBLE PRECISION,
    p_version_aplicacion TEXT,
    p_build_aplicacion INTEGER
) RETURNS TABLE (
    permitido BOOLEAN,
    mensaje TEXT,
    id_tienda UUID,
    nombre VARCHAR(150),
    correo VARCHAR(150),
    telefono VARCHAR(20),
    direccion VARCHAR(255),
    fecha_apertura DATE,
    estado BOOLEAN
) LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_resultado RECORD;
    v_plataforma TEXT := lower(btrim(COALESCE(p_dispositivo, '')));
    v_version TEXT := left(btrim(COALESCE(p_version_aplicacion, '')), 32);
    v_build INTEGER := GREATEST(COALESCE(p_build_aplicacion, 0), 0);
BEGIN
    SELECT s.*
    INTO v_resultado
    FROM public.iniciar_sesion_tienda_segura(
        p_correo,
        p_contrasena,
        p_session_id,
        p_dispositivo,
        p_latitud,
        p_longitud,
        p_precision_metros
    ) s;

    IF NOT FOUND THEN
        RETURN;
    END IF;

    IF v_resultado.permitido = TRUE THEN
        UPDATE public.qr q
        SET version_aplicacion = NULLIF(v_version, ''),
            build_aplicacion = v_build,
            plataforma_aplicacion = CASE
                WHEN v_plataforma IN (
                    'android', 'ios', 'windows', 'macos', 'linux'
                ) THEN v_plataforma
                ELSE NULL
            END,
            version_actualizada_en = NOW()
        WHERE q.id_tienda = v_resultado.id_tienda
          AND q.session_id = btrim(p_session_id)
          AND q.usado = TRUE;
    END IF;

    RETURN QUERY SELECT
        v_resultado.permitido::BOOLEAN,
        v_resultado.mensaje::TEXT,
        v_resultado.id_tienda::UUID,
        v_resultado.nombre::VARCHAR(150),
        v_resultado.correo::VARCHAR(150),
        v_resultado.telefono::VARCHAR(20),
        v_resultado.direccion::VARCHAR(255),
        v_resultado.fecha_apertura::DATE,
        v_resultado.estado::BOOLEAN;
END;
$$;

REVOKE ALL ON FUNCTION public.iniciar_sesion_tienda_segura(
    TEXT, TEXT, TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION,
    DOUBLE PRECISION, TEXT, INTEGER
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.iniciar_sesion_tienda_segura(
    TEXT, TEXT, TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION,
    DOUBLE PRECISION, TEXT, INTEGER
) TO anon, authenticated;

-- Sobrecarga compatible del pulso de 15 segundos. La ubicación y la propiedad
-- de la sesión siguen siendo validadas por el RPC existente.
CREATE OR REPLACE FUNCTION public.renovar_sesion_tienda(
    p_id_tienda UUID,
    p_session_id TEXT,
    p_dispositivo TEXT,
    p_latitud DOUBLE PRECISION,
    p_longitud DOUBLE PRECISION,
    p_precision_metros DOUBLE PRECISION,
    p_version_aplicacion TEXT,
    p_build_aplicacion INTEGER
) RETURNS TABLE (
    permitido BOOLEAN,
    mensaje TEXT,
    expira_en TIMESTAMPTZ
) LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_resultado RECORD;
    v_plataforma TEXT := lower(btrim(COALESCE(p_dispositivo, '')));
    v_version TEXT := left(btrim(COALESCE(p_version_aplicacion, '')), 32);
    v_build INTEGER := GREATEST(COALESCE(p_build_aplicacion, 0), 0);
BEGIN
    SELECT s.*
    INTO v_resultado
    FROM public.renovar_sesion_tienda(
        p_id_tienda,
        p_session_id,
        p_dispositivo,
        p_latitud,
        p_longitud,
        p_precision_metros
    ) s;

    IF NOT FOUND THEN
        RETURN;
    END IF;

    IF v_resultado.permitido = TRUE THEN
        UPDATE public.qr q
        SET version_aplicacion = NULLIF(v_version, ''),
            build_aplicacion = v_build,
            plataforma_aplicacion = CASE
                WHEN v_plataforma IN (
                    'android', 'ios', 'windows', 'macos', 'linux'
                ) THEN v_plataforma
                ELSE NULL
            END,
            version_actualizada_en = NOW()
        WHERE q.id_tienda = p_id_tienda
          AND q.session_id = btrim(p_session_id)
          AND q.usado = TRUE;
    END IF;

    RETURN QUERY SELECT
        v_resultado.permitido::BOOLEAN,
        v_resultado.mensaje::TEXT,
        v_resultado.expira_en::TIMESTAMPTZ;
END;
$$;

REVOKE ALL ON FUNCTION public.renovar_sesion_tienda(
    UUID, TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION,
    TEXT, INTEGER
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.renovar_sesion_tienda(
    UUID, TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION,
    TEXT, INTEGER
) TO anon, authenticated;

-- Bucket público de solo descarga para instaladores. No se crean políticas de
-- escritura para anon/authenticated: las cargas se realizan desde Dashboard o
-- mediante service_role.
INSERT INTO storage.buckets (
    id,
    name,
    public,
    file_size_limit,
    allowed_mime_types
) VALUES (
    'actualizaciones',
    'actualizaciones',
    TRUE,
    50000000,
    ARRAY[
        'application/vnd.android.package-archive',
        'application/zip',
        'application/octet-stream'
    ]::TEXT[]
)
ON CONFLICT (id) DO UPDATE
SET public = EXCLUDED.public,
    file_size_limit = EXCLUDED.file_size_limit,
    allowed_mime_types = EXCLUDED.allowed_mime_types;

-- Se dejan inactivas hasta que los binarios hayan sido cargados. Al activarlas,
-- el aviso aparecerá al abrir la app y seguirá siendo siempre cancelable.
INSERT INTO public.version_aplicacion (
    plataforma,
    version_publicada,
    build_publicado,
    url_descarga,
    sha256,
    mensaje,
    activa
) VALUES
    (
        'android',
        '1.2.0',
        3,
        'https://tlmsnenvqqblmmtimung.supabase.co/storage/v1/object/public/actualizaciones/qr-sucursal/android/qr-sucursal.apk?download=QR_Sucursal.apk',
        '8abc5e72a96228d2b61a4a87d03c489026821362ee8082da7aa9c1d84c7bf353',
        'Hay una nueva versión de QR Sucursal para Android.',
        FALSE
    ),
    (
        'windows',
        '1.2.0',
        3,
        'https://tlmsnenvqqblmmtimung.supabase.co/storage/v1/object/public/actualizaciones/qr-sucursal/windows/QR_Sucursal_Windows_x64_COMPLETO.zip?download=QR_Sucursal_Windows_x64_COMPLETO.zip',
        'd2f24bb58cf986aaedef612660835a0f459b2a49ba77a041b1b43b760fd4e920',
        'Hay una nueva versión de QR Sucursal para Windows.',
        FALSE
    )
ON CONFLICT (plataforma) DO NOTHING;

NOTIFY pgrst, 'reload schema';

COMMIT;
