BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

CREATE SCHEMA IF NOT EXISTS private;
REVOKE ALL ON SCHEMA private FROM PUBLIC, anon, authenticated;
REVOKE CREATE ON SCHEMA public FROM PUBLIC, anon, authenticated;

-- Las contraseñas se almacenan con bcrypt. La condición evita volver a cifrar
-- hashes existentes si este instalador se ejecuta más de una vez.
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

CREATE OR REPLACE FUNCTION public.generar_token_qr_tienda(
    p_id_tienda UUID
) RETURNS TEXT
LANGUAGE sql
VOLATILE
SET search_path = public
AS $$
    SELECT md5(p_id_tienda::TEXT || ':' || gen_random_uuid()::TEXT || ':' || clock_timestamp()::TEXT);
$$;

DROP TABLE IF EXISTS public.tienda_sesion_activa;

ALTER TABLE public.qr
ADD COLUMN IF NOT EXISTS usado BOOLEAN NOT NULL DEFAULT FALSE;

ALTER TABLE public.qr
ADD COLUMN IF NOT EXISTS session_id TEXT;

ALTER TABLE public.qr
ADD COLUMN IF NOT EXISTS usado_expira_en TIMESTAMPTZ;

ALTER TABLE public.qr
ADD COLUMN IF NOT EXISTS ubicacion JSONB NOT NULL DEFAULT '{}'::jsonb;

-- Las sesiones son persistentes: solo cerrar_sesion_tienda puede liberarlas.
UPDATE public.qr
SET usado_expira_en = NULL
WHERE usado_expira_en IS NOT NULL;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'qr'
          AND column_name = 'latitud'
    ) AND EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'qr'
          AND column_name = 'longitud'
    ) THEN
        EXECUTE $sql$
            UPDATE public.qr
            SET ubicacion = jsonb_set(
                COALESCE(ubicacion, '{}'::jsonb),
                '{horario_salida}',
                jsonb_build_object('latitud', latitud, 'longitud', longitud),
                true
            )
            WHERE (latitud IS NOT NULL OR longitud IS NOT NULL)
              AND NOT (COALESCE(ubicacion, '{}'::jsonb) ? 'horario_salida')
        $sql$;
    END IF;
END;
$$;

ALTER TABLE public.qr
DROP COLUMN IF EXISTS latitud;

ALTER TABLE public.qr
DROP COLUMN IF EXISTS longitud;

CREATE OR REPLACE FUNCTION public.generar_payload_qr_tienda(
    p_token TEXT,
    p_slot BIGINT DEFAULT NULL
) RETURNS TEXT
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $$
DECLARE
    v_slot BIGINT := COALESCE(p_slot, floor(extract(epoch FROM NOW()) / 30)::BIGINT);
    v_firma TEXT;
BEGIN
    v_firma := md5(trim(p_token) || ':' || v_slot::TEXT || ':qr_dinamico:v2');
    RETURN 'app-qr-dinamico://' || v_slot::TEXT || '/' || v_firma;
END;
$$;

CREATE OR REPLACE FUNCTION public.payload_qr_valido_tienda(
    p_payload TEXT,
    p_id_tienda UUID
) RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $$
DECLARE
    v_payload TEXT := trim(COALESCE(p_payload, ''));
    v_slot_actual BIGINT := floor(extract(epoch FROM NOW()) / 30)::BIGINT;
    v_slot BIGINT;
BEGIN
    FOR v_slot IN (v_slot_actual - 2)..(v_slot_actual + 2) LOOP
        IF EXISTS (
            SELECT 1
            FROM public.qr q
            INNER JOIN public.tienda t ON t.id_tienda = q.id_tienda
            WHERE q.id_tienda = p_id_tienda
              AND t.estado = TRUE
              AND q.usado = TRUE
              AND v_payload = public.generar_payload_qr_tienda(q.token, v_slot)
        ) THEN
            RETURN TRUE;
        END IF;
    END LOOP;

    RETURN FALSE;
END;
$$;

CREATE OR REPLACE FUNCTION public.obtener_tienda_por_correo(
    p_correo TEXT
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
    WHERE lower(t.correo) = lower(trim(p_correo))
      AND t.estado = TRUE
    LIMIT 1;
END;
$$;

CREATE OR REPLACE FUNCTION public.obtener_tienda_por_id(
    p_id_tienda UUID
) RETURNS TABLE (
    id_tienda UUID,
    nombre VARCHAR(150),
    correo VARCHAR(150),
    telefono VARCHAR(20),
    direccion VARCHAR(255),
    fecha_apertura DATE,
    estado BOOLEAN
) LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    RETURN QUERY
    SELECT
        t.id_tienda,
        t.nombre,
        t.correo,
        t.telefono,
        t.direccion,
        t.fecha_apertura,
        t.estado
    FROM public.tienda t
    WHERE t.id_tienda = p_id_tienda
      AND t.estado = TRUE
    LIMIT 1;
END;
$$;

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
) LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    RETURN QUERY
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
      AND t.contrasena = extensions.crypt(p_contrasena, t.contrasena)
      AND t.estado = TRUE
    LIMIT 1;
$$;

DROP FUNCTION IF EXISTS public.iniciar_sesion_tienda(UUID, TEXT, TEXT);
DROP FUNCTION IF EXISTS public.iniciar_sesion_tienda(
    UUID,
    TEXT,
    TEXT,
    DOUBLE PRECISION,
    DOUBLE PRECISION
);

CREATE OR REPLACE FUNCTION public.iniciar_sesion_tienda(
    p_id_tienda UUID,
    p_session_id TEXT,
    p_dispositivo TEXT,
    p_latitud DOUBLE PRECISION,
    p_longitud DOUBLE PRECISION,
    p_precision_metros DOUBLE PRECISION
) RETURNS TABLE (
    permitido BOOLEAN,
    mensaje TEXT,
    expira_en TIMESTAMPTZ
) LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_qr public.qr%ROWTYPE;
    v_session_id TEXT := trim(p_session_id);
BEGIN
    IF v_session_id IS NULL OR v_session_id = '' THEN
        RAISE EXCEPTION 'Session id requerido.';
    END IF;

    IF p_latitud IS NULL OR p_latitud < -90 OR p_latitud > 90 THEN
        RAISE EXCEPTION 'Latitud fuera de rango.';
    END IF;

    IF p_longitud IS NULL OR p_longitud < -180 OR p_longitud > 180 THEN
        RAISE EXCEPTION 'Longitud fuera de rango.';
    END IF;

    IF p_precision_metros IS NULL
       OR p_precision_metros < 0
       OR p_precision_metros > 100000 THEN
        RAISE EXCEPTION 'Precision de ubicacion fuera de rango.';
    END IF;

    IF p_dispositivo IS NULL OR trim(p_dispositivo) = '' THEN
        RAISE EXCEPTION 'Dispositivo requerido.';
    END IF;

    PERFORM public.obtener_o_crear_qr_tienda(p_id_tienda);

    UPDATE public.qr q
    SET usado = TRUE,
        session_id = v_session_id,
        usado_expira_en = NULL,
        ubicacion = jsonb_build_object(
            'inicio_sesion',
            jsonb_build_object(
                'latitud', p_latitud,
                'longitud', p_longitud,
                'precision_metros', p_precision_metros,
                'dispositivo', trim(p_dispositivo),
                'actualizada_en', NOW()
            ),
            'actual',
            jsonb_build_object(
                'latitud', p_latitud,
                'longitud', p_longitud,
                'precision_metros', p_precision_metros,
                'dispositivo', trim(p_dispositivo),
                'actualizada_en', NOW()
            )
        )
    WHERE q.id_tienda = p_id_tienda
      AND (
          q.usado = FALSE
          OR q.usado IS NULL
          OR q.session_id = v_session_id
      )
    RETURNING * INTO v_qr;

    IF v_qr.id IS NULL THEN
        SELECT q.*
        INTO v_qr
        FROM public.qr q
        WHERE q.id_tienda = p_id_tienda
        ORDER BY q.fecha_creada DESC
        LIMIT 1;

        RETURN QUERY
        SELECT FALSE, 'Esta tienda ya esta abierta en otro dispositivo.', v_qr.usado_expira_en;
        RETURN;
    END IF;

    RETURN QUERY
    SELECT TRUE, 'Sesion activa.', v_qr.usado_expira_en;
END;
$$;

-- Inicio seguro y atómico: autentica, limita intentos y reserva la sesión sin
-- exponer el id de la tienda ni el token estático al cliente.
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

-- Compatibilidad temporal con clientes instalados que todavía no envían la
-- precisión. Los clientes nuevos usan la firma de seis argumentos.
CREATE OR REPLACE FUNCTION public.iniciar_sesion_tienda(
    p_id_tienda UUID,
    p_session_id TEXT,
    p_dispositivo TEXT,
    p_latitud DOUBLE PRECISION,
    p_longitud DOUBLE PRECISION
) RETURNS TABLE (
    permitido BOOLEAN,
    mensaje TEXT,
    expira_en TIMESTAMPTZ
) LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT *
    FROM public.iniciar_sesion_tienda(
        p_id_tienda,
        p_session_id,
        p_dispositivo,
        p_latitud,
        p_longitud,
        0::DOUBLE PRECISION
    );
$$;

DROP FUNCTION IF EXISTS public.renovar_sesion_tienda(UUID, TEXT);

CREATE OR REPLACE FUNCTION public.renovar_sesion_tienda(
    p_id_tienda UUID,
    p_session_id TEXT,
    p_dispositivo TEXT,
    p_latitud DOUBLE PRECISION,
    p_longitud DOUBLE PRECISION,
    p_precision_metros DOUBLE PRECISION
) RETURNS TABLE (
    permitido BOOLEAN,
    mensaje TEXT,
    expira_en TIMESTAMPTZ
) LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_session_id TEXT := trim(p_session_id);
    v_expira_en TIMESTAMPTZ;
BEGIN
    IF v_session_id IS NULL OR v_session_id = '' THEN
        RAISE EXCEPTION 'Session id requerido.';
    END IF;

    IF p_latitud IS NULL OR p_latitud < -90 OR p_latitud > 90 THEN
        RAISE EXCEPTION 'Latitud fuera de rango.';
    END IF;

    IF p_longitud IS NULL OR p_longitud < -180 OR p_longitud > 180 THEN
        RAISE EXCEPTION 'Longitud fuera de rango.';
    END IF;

    IF p_precision_metros IS NULL
       OR p_precision_metros < 0
       OR p_precision_metros > 100000 THEN
        RAISE EXCEPTION 'Precision de ubicacion fuera de rango.';
    END IF;

    IF p_dispositivo IS NULL OR trim(p_dispositivo) = '' THEN
        RAISE EXCEPTION 'Dispositivo requerido.';
    END IF;

    UPDATE public.qr q
    SET usado = TRUE,
        usado_expira_en = NULL,
        ubicacion = jsonb_set(
            jsonb_set(
                COALESCE(q.ubicacion, '{}'::jsonb) - 'horario_salida',
                '{inicio_sesion}',
                COALESCE(
                    q.ubicacion -> 'inicio_sesion',
                    jsonb_build_object(
                        'latitud', p_latitud,
                        'longitud', p_longitud,
                        'precision_metros', p_precision_metros,
                        'dispositivo', trim(p_dispositivo),
                        'actualizada_en', NOW()
                    )
                ),
                TRUE
            ),
            '{actual}',
            jsonb_build_object(
                'latitud', p_latitud,
                'longitud', p_longitud,
                'precision_metros', p_precision_metros,
                'dispositivo', trim(p_dispositivo),
                'actualizada_en', NOW()
            ),
            TRUE
        )
    WHERE q.id_tienda = p_id_tienda
      AND q.session_id = v_session_id
      AND q.usado = TRUE
    RETURNING q.usado_expira_en INTO v_expira_en;

    IF FOUND THEN
        RETURN QUERY
        SELECT TRUE, 'Sesion renovada.', v_expira_en;
        RETURN;
    END IF;

    RETURN QUERY
    SELECT FALSE, 'La sesion de esta tienda ya no esta activa.', NULL::TIMESTAMPTZ;
END;
$$;

-- Compatibilidad temporal con la app anterior. Mantiene la sesión, pero
-- solo la firma nueva puede actualizar la ubicación en cada pulso.
CREATE OR REPLACE FUNCTION public.renovar_sesion_tienda(
    p_id_tienda UUID,
    p_session_id TEXT
) RETURNS TABLE (
    permitido BOOLEAN,
    mensaje TEXT,
    expira_en TIMESTAMPTZ
) LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_expira_en TIMESTAMPTZ;
BEGIN
    UPDATE public.qr q
    SET usado = TRUE,
        usado_expira_en = NULL
    WHERE q.id_tienda = p_id_tienda
      AND q.session_id = trim(p_session_id)
      AND q.usado = TRUE
    RETURNING q.usado_expira_en INTO v_expira_en;

    IF FOUND THEN
        RETURN QUERY
        SELECT TRUE, 'Sesion renovada.', v_expira_en;
        RETURN;
    END IF;

    RETURN QUERY
    SELECT FALSE, 'La sesion de esta tienda ya no esta activa.', NULL::TIMESTAMPTZ;
END;
$$;

CREATE OR REPLACE FUNCTION public.cerrar_sesion_tienda(
    p_id_tienda UUID,
    p_session_id TEXT
) RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    UPDATE public.qr q
    SET usado = FALSE,
        session_id = NULL,
        usado_expira_en = NULL
    WHERE q.id_tienda = p_id_tienda
      AND q.session_id = trim(p_session_id);

    RETURN TRUE;
END;
$$;

-- Devuelve datos de la tienda únicamente al dispositivo que conserva la
-- sesión activa. Permite restaurarla tras cerrar y volver a abrir la app.
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

CREATE OR REPLACE FUNCTION public.obtener_qr_tienda(
    p_id_tienda UUID
) RETURNS TABLE (
    id UUID,
    id_tienda UUID,
    token VARCHAR(512),
    fecha_creada TIMESTAMPTZ
) LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    RETURN QUERY
    SELECT
        q.id,
        q.id_tienda,
        q.token,
        q.fecha_creada
    FROM public.qr q
    INNER JOIN public.tienda t ON t.id_tienda = q.id_tienda
    WHERE q.id_tienda = p_id_tienda
      AND t.estado = TRUE
    ORDER BY q.fecha_creada DESC
    LIMIT 1;
END;
$$;

CREATE OR REPLACE FUNCTION public.obtener_payload_qr_tienda(
    p_id_tienda UUID,
    p_session_id TEXT
) RETURNS TABLE (
    payload TEXT,
    expira_en TIMESTAMPTZ
) LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_qr public.qr%ROWTYPE;
    v_session_id TEXT := trim(p_session_id);
BEGIN
    SELECT q.*
    INTO v_qr
    FROM public.qr q
    INNER JOIN public.tienda t ON t.id_tienda = q.id_tienda
    WHERE q.id_tienda = p_id_tienda
      AND q.session_id = v_session_id
      AND q.usado = TRUE
      AND t.estado = TRUE
    ORDER BY q.fecha_creada DESC
    LIMIT 1;

    IF v_qr.id IS NULL THEN
        RAISE EXCEPTION 'La sesion de esta tienda ya no esta activa.';
    END IF;

    RETURN QUERY
    SELECT
        public.generar_payload_qr_tienda(v_qr.token),
        to_timestamp((floor(extract(epoch FROM NOW()) / 30)::BIGINT + 1) * 30);
END;
$$;

CREATE OR REPLACE FUNCTION public.obtener_o_crear_qr_tienda(
    p_id_tienda UUID
) RETURNS TABLE (
    id UUID,
    id_tienda UUID,
    token VARCHAR(512),
    fecha_creada TIMESTAMPTZ
) LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_qr public.qr%ROWTYPE;
    v_token TEXT := public.generar_token_qr_tienda(p_id_tienda);
BEGIN
    SELECT q.*
    INTO v_qr
    FROM public.qr q
    INNER JOIN public.tienda t ON t.id_tienda = q.id_tienda
    WHERE q.id_tienda = p_id_tienda
      AND t.estado = TRUE
    ORDER BY q.fecha_creada DESC
    LIMIT 1;

    IF v_qr.id IS NULL THEN
        INSERT INTO public.qr (id_tienda, token)
        VALUES (p_id_tienda, v_token)
        RETURNING * INTO v_qr;
    END IF;

    RETURN QUERY
    SELECT v_qr.id, v_qr.id_tienda, v_qr.token, v_qr.fecha_creada;
END;
$$;

CREATE OR REPLACE FUNCTION public.obtener_horario_trabajador(
    p_dni TEXT,
    p_dia_semana TEXT DEFAULT NULL
) RETURNS TABLE (
    id_horario UUID,
    dni_trabajador VARCHAR(20),
    dia_semana TEXT,
    horario_entrada TIME,
    horario_inicio_receso TIME,
    horario_fin_receso TIME,
    horario_salida TIME
) LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    RETURN QUERY
    SELECT
        h.id_horario,
        h.dni_trabajador,
        h.dia_semana::TEXT,
        h.horario_entrada,
        h.horario_inicio_receso,
        h.horario_fin_receso,
        h.horario_salida
    FROM public.horario_trabajador h
    WHERE h.dni_trabajador = trim(p_dni)
      AND (
          p_dia_semana IS NULL
          OR h.dia_semana::TEXT = lower(trim(p_dia_semana))
      )
    ORDER BY
      CASE h.dia_semana::TEXT
        WHEN 'lunes' THEN 1
        WHEN 'martes' THEN 2
        WHEN 'miercoles' THEN 3
        WHEN 'jueves' THEN 4
        WHEN 'viernes' THEN 5
        WHEN 'sabado' THEN 6
        WHEN 'domingo' THEN 7
        ELSE 8
      END;
END;
$$;

CREATE OR REPLACE FUNCTION public.registrar_marcacion_asistencia(
    p_dni TEXT,
    p_fecha_hora TIMESTAMPTZ DEFAULT NOW(),
    p_token TEXT DEFAULT NULL
) RETURNS TABLE (
    id_asistencia UUID,
    dni_trabajador VARCHAR(20),
    id_tienda UUID,
    fecha DATE,
    dia_semana TEXT,
    campo_marcado TEXT,
    fecha_hora_marcada TIMESTAMPTZ
) LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_dni VARCHAR(20) := trim(p_dni);
    v_id_tienda UUID;
    v_fecha DATE := (p_fecha_hora AT TIME ZONE 'America/Lima')::DATE;
    v_dia TEXT;
    v_id_asistencia UUID;
    v_campo TEXT;
BEGIN
    v_dia := CASE EXTRACT(ISODOW FROM v_fecha)
        WHEN 1 THEN 'lunes'
        WHEN 2 THEN 'martes'
        WHEN 3 THEN 'miercoles'
        WHEN 4 THEN 'jueves'
        WHEN 5 THEN 'viernes'
        WHEN 6 THEN 'sabado'
        WHEN 7 THEN 'domingo'
    END;

    SELECT t.id_tienda
    INTO v_id_tienda
    FROM public.trabajador t
    WHERE t.dni = v_dni
      AND t.estado = TRUE;

    IF v_id_tienda IS NULL THEN
        RAISE EXCEPTION 'Trabajador no encontrado o inactivo.';
    END IF;

    IF p_token IS NOT NULL AND NOT (
        public.payload_qr_valido_tienda(p_token, v_id_tienda)
        OR EXISTS (
        SELECT 1
        FROM public.qr q
        INNER JOIN public.tienda ti ON ti.id_tienda = q.id_tienda
        WHERE q.token = trim(p_token)
          AND q.id_tienda = v_id_tienda
          AND q.usado = TRUE
          AND ti.estado = TRUE
        )
    ) THEN
        RAISE EXCEPTION 'QR invalido para este trabajador.';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.horario_trabajador h
        WHERE h.dni_trabajador = v_dni
          AND h.dia_semana::TEXT = v_dia
    ) THEN
        RAISE EXCEPTION 'El trabajador no tiene horario para %.', v_dia;
    END IF;

    INSERT INTO public.asistencia (dni_trabajador, fecha)
    VALUES (v_dni, v_fecha)
    ON CONFLICT (dni_trabajador, fecha) DO NOTHING;

    SELECT a.id_asistencia
    INTO v_id_asistencia
    FROM public.asistencia a
    WHERE a.dni_trabajador = v_dni
      AND a.fecha = v_fecha;

    UPDATE public.asistencia a
    SET horario_entrada = p_fecha_hora
    WHERE a.id_asistencia = v_id_asistencia
      AND a.horario_entrada IS NULL
    RETURNING 'horario_entrada' INTO v_campo;

    IF v_campo IS NULL THEN
        UPDATE public.asistencia a
        SET horario_inicio_receso = p_fecha_hora
        WHERE a.id_asistencia = v_id_asistencia
          AND a.horario_inicio_receso IS NULL
        RETURNING 'horario_inicio_receso' INTO v_campo;
    END IF;

    IF v_campo IS NULL THEN
        UPDATE public.asistencia a
        SET horario_fin_receso = p_fecha_hora
        WHERE a.id_asistencia = v_id_asistencia
          AND a.horario_fin_receso IS NULL
        RETURNING 'horario_fin_receso' INTO v_campo;
    END IF;

    IF v_campo IS NULL THEN
        UPDATE public.asistencia a
        SET horario_salida = p_fecha_hora
        WHERE a.id_asistencia = v_id_asistencia
          AND a.horario_salida IS NULL
        RETURNING 'horario_salida' INTO v_campo;
    END IF;

    IF v_campo IS NULL THEN
        RAISE EXCEPTION 'Ya se registraron las cuatro marcaciones de hoy.';
    END IF;

    RETURN QUERY
    SELECT
        v_id_asistencia,
        v_dni,
        v_id_tienda,
        v_fecha,
        v_dia,
        v_campo,
        p_fecha_hora;
END;
$$;

REVOKE ALL ON FUNCTION public.generar_token_qr_tienda(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.generar_payload_qr_tienda(TEXT, BIGINT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.payload_qr_valido_tienda(TEXT, UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.obtener_tienda_por_correo(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.obtener_tienda_por_id(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.login_tienda(TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.iniciar_sesion_tienda(UUID, TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.iniciar_sesion_tienda(UUID, TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.renovar_sesion_tienda(UUID, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.renovar_sesion_tienda(UUID, TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.cerrar_sesion_tienda(UUID, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.obtener_qr_tienda(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.obtener_payload_qr_tienda(UUID, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.obtener_o_crear_qr_tienda(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.obtener_horario_trabajador(TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.registrar_marcacion_asistencia(TEXT, TIMESTAMPTZ, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.iniciar_sesion_tienda_segura(TEXT, TEXT, TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.obtener_sesion_tienda(UUID, TEXT) FROM PUBLIC;

REVOKE ALL ON FUNCTION public.generar_token_qr_tienda(UUID) FROM anon, authenticated;
REVOKE ALL ON FUNCTION public.obtener_tienda_por_correo(TEXT) FROM anon, authenticated;
REVOKE ALL ON FUNCTION public.obtener_tienda_por_id(UUID) FROM anon, authenticated;
REVOKE ALL ON FUNCTION public.login_tienda(TEXT, TEXT) FROM anon, authenticated;
REVOKE ALL ON FUNCTION public.iniciar_sesion_tienda(UUID, TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION) FROM anon, authenticated;
REVOKE ALL ON FUNCTION public.iniciar_sesion_tienda(UUID, TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION) FROM anon, authenticated;
REVOKE ALL ON FUNCTION public.obtener_qr_tienda(UUID) FROM anon, authenticated;
REVOKE ALL ON FUNCTION public.obtener_o_crear_qr_tienda(UUID) FROM anon, authenticated;
REVOKE ALL ON FUNCTION public.registrar_marcacion_asistencia(TEXT, TIMESTAMPTZ, TEXT) FROM anon, authenticated;

GRANT EXECUTE ON FUNCTION public.iniciar_sesion_tienda_segura(TEXT, TEXT, TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.obtener_sesion_tienda(UUID, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.renovar_sesion_tienda(UUID, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.renovar_sesion_tienda(UUID, TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerrar_sesion_tienda(UUID, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.obtener_payload_qr_tienda(UUID, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.obtener_horario_trabajador(TEXT, TEXT) TO anon, authenticated;

ALTER TABLE public.tienda ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.qr ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.tienda, public.qr FROM anon, authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
