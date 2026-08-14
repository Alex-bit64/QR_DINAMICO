BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;

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
    WHERE lower(t.correo) = lower(trim(p_correo))
      AND t.contrasena = trim(p_contrasena)
      AND t.estado = TRUE
    LIMIT 1;
END;
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

GRANT EXECUTE ON FUNCTION public.generar_token_qr_tienda(UUID) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.obtener_tienda_por_correo(TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.obtener_tienda_por_id(UUID) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.login_tienda(TEXT, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.iniciar_sesion_tienda(UUID, TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.iniciar_sesion_tienda(UUID, TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.renovar_sesion_tienda(UUID, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.renovar_sesion_tienda(UUID, TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerrar_sesion_tienda(UUID, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.obtener_qr_tienda(UUID) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.obtener_payload_qr_tienda(UUID, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.obtener_o_crear_qr_tienda(UUID) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.obtener_horario_trabajador(TEXT, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.registrar_marcacion_asistencia(TEXT, TIMESTAMPTZ, TEXT) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
