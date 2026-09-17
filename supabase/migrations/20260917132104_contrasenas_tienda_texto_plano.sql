BEGIN;

-- Cambio solicitado: contrasenas de tiendas en texto plano.
-- Solo modifica la autenticacion de tienda; conserva los permisos de los RPC,
-- el limite de intentos y la reserva exclusiva de la sesion QR.

CREATE OR REPLACE FUNCTION public.iniciar_sesion_tienda_segura(p_correo text, p_contrasena text, p_session_id text, p_dispositivo text, p_latitud double precision, p_longitud double precision, p_precision_metros double precision)
 RETURNS TABLE(permitido boolean, mensaje text, id_tienda uuid, nombre character varying, correo character varying, telefono character varying, direccion character varying, fecha_apertura date, estado boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
      AND t.contrasena = p_contrasena
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
$function$;


CREATE OR REPLACE FUNCTION public.login_tienda(p_correo text, p_contrasena text)
 RETURNS TABLE(id_tienda uuid, nombre character varying, correo character varying, telefono character varying, direccion character varying, fecha_apertura date, estado boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
      AND t.contrasena = p_contrasena
    LIMIT 1;
$function$;


-- Reemplaza las contrasenas anteriores de todas las tiendas, incluidas las
-- inactivas. No cambia el estado de las sucursales ni sus sesiones actuales.
UPDATE public.tienda
SET contrasena = '123';

NOTIFY pgrst, 'reload schema';

COMMIT;
