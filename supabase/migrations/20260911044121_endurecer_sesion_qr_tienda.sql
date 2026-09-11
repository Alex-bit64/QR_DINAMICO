BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

CREATE SCHEMA IF NOT EXISTS private;
REVOKE ALL ON SCHEMA private FROM PUBLIC, anon, authenticated;
REVOKE CREATE ON SCHEMA public FROM PUBLIC, anon, authenticated;

-- No conservar credenciales de tiendas como texto legible. La condición hace
-- que esta migración pueda ejecutarse una sola vez sin volver a cifrar hashes.
ALTER TABLE public.tienda
ALTER COLUMN contrasena TYPE TEXT USING contrasena::TEXT;

UPDATE public.tienda
SET contrasena = extensions.crypt(
    contrasena,
    extensions.gen_salt('bf', 10)
)
WHERE contrasena IS NOT NULL
  AND contrasena <> ''
  AND contrasena !~ '^\$2[aby]\$';

CREATE TABLE IF NOT EXISTS private.tienda_login_intento (
    clave TEXT PRIMARY KEY,
    ventana_inicio TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    intentos SMALLINT NOT NULL DEFAULT 0 CHECK (intentos BETWEEN 0 AND 100),
    bloqueado_hasta TIMESTAMPTZ
);

ALTER TABLE private.tienda_login_intento ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE private.tienda_login_intento
FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.iniciar_sesion_tienda_segura(
    p_correo TEXT,
    p_contrasena TEXT,
    p_session_id TEXT,
    p_dispositivo TEXT,
    p_latitud DOUBLE PRECISION,
    p_longitud DOUBLE PRECISION,
    p_precision_metros DOUBLE PRECISION
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
    v_tienda public.tienda%ROWTYPE;
    v_correo TEXT := lower(btrim(COALESCE(p_correo, '')));
    v_headers JSONB := '{}'::JSONB;
    v_ip TEXT := 'sin-ip';
    v_clave TEXT;
    v_ventana_inicio TIMESTAMPTZ;
    v_intentos SMALLINT;
    v_bloqueado_hasta TIMESTAMPTZ;
    v_permitido BOOLEAN;
    v_mensaje TEXT;
BEGIN
    IF v_correo = ''
       OR p_contrasena IS NULL
       OR p_contrasena = ''
       OR octet_length(p_contrasena) > 72
       OR p_session_id IS NULL
       OR p_session_id !~ '^[0-9a-f]{32}$' THEN
        RETURN QUERY SELECT
            FALSE,
            'Correo o contraseña incorrectos.'::TEXT,
            NULL::UUID,
            NULL::VARCHAR(150),
            NULL::VARCHAR(150),
            NULL::VARCHAR(20),
            NULL::VARCHAR(255),
            NULL::DATE,
            NULL::BOOLEAN;
        RETURN;
    END IF;

    BEGIN
        v_headers := COALESCE(
            NULLIF(pg_catalog.current_setting('request.headers', TRUE), ''),
            '{}'
        )::JSONB;
    EXCEPTION WHEN OTHERS THEN
        v_headers := '{}'::JSONB;
    END;

    v_ip := COALESCE(
        NULLIF(btrim(split_part(v_headers ->> 'x-forwarded-for', ',', 1)), ''),
        NULLIF(btrim(v_headers ->> 'cf-connecting-ip'), ''),
        'sin-ip'
    );
    v_clave := pg_catalog.encode(
        extensions.digest(v_correo || '|' || v_ip, 'sha256'),
        'hex'
    );

    -- Serializa los intentos para la misma combinación correo/IP.
    PERFORM pg_catalog.pg_advisory_xact_lock(
        pg_catalog.hashtextextended(v_clave, 0)
    );

    DELETE FROM private.tienda_login_intento
    WHERE clave IN (
        SELECT i.clave
        FROM private.tienda_login_intento i
        WHERE i.ventana_inicio < NOW() - INTERVAL '1 day'
        ORDER BY i.ventana_inicio
        LIMIT 50
    );

    SELECT i.ventana_inicio, i.intentos, i.bloqueado_hasta
    INTO v_ventana_inicio, v_intentos, v_bloqueado_hasta
    FROM private.tienda_login_intento i
    WHERE i.clave = v_clave
    FOR UPDATE;

    IF v_bloqueado_hasta IS NOT NULL AND v_bloqueado_hasta > NOW() THEN
        RETURN QUERY SELECT
            FALSE,
            'Demasiados intentos. Espera unos minutos e inténtalo otra vez.'::TEXT,
            NULL::UUID,
            NULL::VARCHAR(150),
            NULL::VARCHAR(150),
            NULL::VARCHAR(20),
            NULL::VARCHAR(255),
            NULL::DATE,
            NULL::BOOLEAN;
        RETURN;
    END IF;

    SELECT t.*
    INTO v_tienda
    FROM public.tienda t
    WHERE lower(btrim(t.correo)) = v_correo
      AND t.estado = TRUE
      AND t.contrasena = extensions.crypt(p_contrasena, t.contrasena)
    LIMIT 1;

    IF v_tienda.id_tienda IS NULL THEN
        IF v_ventana_inicio IS NULL
           OR v_ventana_inicio < NOW() - INTERVAL '15 minutes' THEN
            INSERT INTO private.tienda_login_intento (
                clave,
                ventana_inicio,
                intentos,
                bloqueado_hasta
            ) VALUES (v_clave, NOW(), 1, NULL)
            ON CONFLICT (clave) DO UPDATE
            SET ventana_inicio = EXCLUDED.ventana_inicio,
                intentos = EXCLUDED.intentos,
                bloqueado_hasta = NULL;
            v_intentos := 1;
        ELSE
            v_intentos := LEAST(COALESCE(v_intentos, 0) + 1, 100);
            UPDATE private.tienda_login_intento i
            SET intentos = v_intentos,
                bloqueado_hasta = CASE
                    WHEN v_intentos >= 5 THEN NOW() + INTERVAL '15 minutes'
                    ELSE NULL
                END
            WHERE i.clave = v_clave;
        END IF;

        RETURN QUERY SELECT
            FALSE,
            CASE
                WHEN v_intentos >= 5 THEN
                    'Demasiados intentos. Espera 15 minutos e inténtalo otra vez.'
                ELSE 'Correo o contraseña incorrectos.'
            END::TEXT,
            NULL::UUID,
            NULL::VARCHAR(150),
            NULL::VARCHAR(150),
            NULL::VARCHAR(20),
            NULL::VARCHAR(255),
            NULL::DATE,
            NULL::BOOLEAN;
        RETURN;
    END IF;

    DELETE FROM private.tienda_login_intento i WHERE i.clave = v_clave;

    SELECT s.permitido, s.mensaje
    INTO v_permitido, v_mensaje
    FROM public.iniciar_sesion_tienda(
        v_tienda.id_tienda,
        p_session_id,
        p_dispositivo,
        p_latitud,
        p_longitud,
        p_precision_metros
    ) s;

    RETURN QUERY SELECT
        v_permitido,
        v_mensaje,
        v_tienda.id_tienda,
        v_tienda.nombre,
        v_tienda.correo,
        v_tienda.telefono,
        v_tienda.direccion,
        v_tienda.fecha_apertura,
        v_tienda.estado;
END;
$$;

CREATE OR REPLACE FUNCTION public.obtener_sesion_tienda(
    p_id_tienda UUID,
    p_session_id TEXT
) RETURNS TABLE (
    id_tienda UUID,
    nombre VARCHAR(150),
    correo VARCHAR(150),
    telefono VARCHAR(20),
    direccion VARCHAR(255),
    fecha_apertura DATE,
    estado BOOLEAN
) LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT
        t.id_tienda,
        t.nombre,
        t.correo,
        t.telefono,
        t.direccion,
        t.fecha_apertura,
        t.estado
    FROM public.tienda t
    INNER JOIN public.qr q ON q.id_tienda = t.id_tienda
    WHERE t.id_tienda = p_id_tienda
      AND t.estado = TRUE
      AND q.usado = TRUE
      AND q.session_id = btrim(p_session_id)
    ORDER BY q.fecha_creada DESC
    LIMIT 1;
$$;

-- Mantiene la función heredada correcta para tareas administrativas, pero ya
-- no queda disponible para clientes públicos.
CREATE OR REPLACE FUNCTION public.login_tienda(
    p_correo TEXT,
    p_contrasena TEXT
) RETURNS TABLE (
    id_tienda UUID,
    nombre VARCHAR(150),
    correo VARCHAR(150),
    telefono VARCHAR(20),
    direccion VARCHAR(255),
    fecha_apertura DATE,
    estado BOOLEAN
) LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT
        t.id_tienda,
        t.nombre,
        t.correo,
        t.telefono,
        t.direccion,
        t.fecha_apertura,
        t.estado
    FROM public.tienda t
    WHERE lower(btrim(t.correo)) = lower(btrim(p_correo))
      AND t.estado = TRUE
      AND t.contrasena = extensions.crypt(p_contrasena, t.contrasena)
    LIMIT 1;
$$;

ALTER TABLE public.tienda ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.qr ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.tienda, public.qr FROM anon, authenticated;

REVOKE ALL ON FUNCTION public.iniciar_sesion_tienda_segura(
    TEXT, TEXT, TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.obtener_sesion_tienda(UUID, TEXT)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.iniciar_sesion_tienda_segura(
    TEXT, TEXT, TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION
) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.obtener_sesion_tienda(UUID, TEXT)
TO anon, authenticated;

-- Superficie heredada insegura: un cliente no debe poder iniciar una sesión
-- por id_tienda ni leer/generar el secreto QR estático.
REVOKE ALL ON FUNCTION public.generar_token_qr_tienda(UUID)
FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.obtener_tienda_por_correo(TEXT)
FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.obtener_tienda_por_id(UUID)
FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.login_tienda(TEXT, TEXT)
FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.iniciar_sesion_tienda(
    UUID, TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.iniciar_sesion_tienda(
    UUID, TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.obtener_qr_tienda(UUID)
FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.obtener_o_crear_qr_tienda(UUID)
FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.registrar_marcacion_asistencia(
    TEXT, TIMESTAMPTZ, TEXT
) FROM PUBLIC, anon, authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
