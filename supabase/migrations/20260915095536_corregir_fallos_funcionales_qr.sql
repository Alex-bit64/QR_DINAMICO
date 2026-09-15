BEGIN;

-- Mantiene una sola fila QR por tienda. Sin esta restriccion, dos inicios
-- simultaneos podian crear filas duplicadas y romper los RPC que esperan una
-- unica sesion.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_catalog.pg_constraint
        WHERE conname = 'qr_id_tienda_key'
          AND conrelid = 'public.qr'::regclass
    ) THEN
        ALTER TABLE public.qr
        ADD CONSTRAINT qr_id_tienda_key UNIQUE (id_tienda);
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.normalizar_estado_sesion_qr()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
    -- NULL en session_id significa cierre remoto. Tambien evita que una fila
    -- marcada como inactiva conserve un identificador que ya no es valido.
    IF NEW.usado IS NOT TRUE
       OR NEW.session_id IS NULL
       OR btrim(NEW.session_id) = '' THEN
        NEW.usado := FALSE;
        NEW.session_id := NULL;
        NEW.usado_expira_en := NULL;
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS normalizar_estado_sesion_qr_trigger ON public.qr;
CREATE TRIGGER normalizar_estado_sesion_qr_trigger
BEFORE INSERT OR UPDATE OF usado, session_id, usado_expira_en
ON public.qr
FOR EACH ROW
EXECUTE FUNCTION public.normalizar_estado_sesion_qr();

-- Corrige cualquier inconsistencia anterior antes de continuar.
UPDATE public.qr
SET usado = FALSE,
    session_id = NULL,
    usado_expira_en = NULL
WHERE usado IS NOT TRUE
   OR session_id IS NULL
   OR btrim(session_id) = '';

CREATE OR REPLACE FUNCTION public.obtener_o_crear_qr_tienda(
    p_id_tienda UUID
) RETURNS TABLE (
    id UUID,
    id_tienda UUID,
    token VARCHAR,
    fecha_creada TIMESTAMPTZ
) LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_qr public.qr%ROWTYPE;
BEGIN
    SELECT q.*
    INTO v_qr
    FROM public.qr q
    INNER JOIN public.tienda t ON t.id_tienda = q.id_tienda
    WHERE q.id_tienda = p_id_tienda
      AND t.estado = TRUE
    LIMIT 1;

    IF v_qr.id IS NULL THEN
        IF NOT EXISTS (
            SELECT 1
            FROM public.tienda t
            WHERE t.id_tienda = p_id_tienda
              AND t.estado = TRUE
        ) THEN
            RAISE EXCEPTION 'La tienda no existe o esta inactiva.';
        END IF;

        INSERT INTO public.qr (id_tienda, token)
        VALUES (p_id_tienda, public.generar_token_qr_tienda(p_id_tienda))
        ON CONFLICT (id_tienda) DO NOTHING
        RETURNING * INTO v_qr;

        -- Otra transaccion pudo crear la fila entre el SELECT y el INSERT.
        IF v_qr.id IS NULL THEN
            SELECT q.*
            INTO v_qr
            FROM public.qr q
            WHERE q.id_tienda = p_id_tienda
            LIMIT 1;
        END IF;
    END IF;

    RETURN QUERY
    SELECT v_qr.id, v_qr.id_tienda, v_qr.token, v_qr.fecha_creada;
END;
$$;

CREATE OR REPLACE FUNCTION public.cerrar_sesion_tienda(
    p_id_tienda UUID,
    p_session_id TEXT
) RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    IF p_session_id IS NULL OR btrim(p_session_id) = '' THEN
        RETURN FALSE;
    END IF;

    UPDATE public.qr q
    SET usado = FALSE,
        session_id = NULL,
        usado_expira_en = NULL
    WHERE q.id_tienda = p_id_tienda
      AND q.session_id = btrim(p_session_id)
      AND q.usado = TRUE;

    RETURN FOUND;
END;
$$;

-- Algunas tiendas pueden haberse creado despues de la migracion inicial. Se
-- conserva la misma contrasena, pero se transforma al formato esperado por el
-- RPC seguro para que puedan iniciar sesion.
UPDATE public.tienda
SET contrasena = extensions.crypt(
    contrasena,
    extensions.gen_salt('bf', 10)
)
WHERE contrasena IS NOT NULL
  AND contrasena <> ''
  AND contrasena !~ '^\$2[aby]\$';

-- Los binarios ya existen en Storage; habilita el aviso para instalaciones
-- cuyo build sea anterior al publicado.
UPDATE public.version_aplicacion v
SET activa = TRUE,
    actualizada_en = NOW()
WHERE (
        v.plataforma = 'android'
        AND EXISTS (
            SELECT 1
            FROM storage.objects o
            WHERE o.bucket_id = 'actualizaciones'
              AND o.name = 'qr-sucursal/android/1.2.0/qr-sucursal.apk'
        )
    )
   OR (
        v.plataforma = 'windows'
        AND EXISTS (
            SELECT 1
            FROM storage.objects o
            WHERE o.bucket_id = 'actualizaciones'
              AND o.name = 'qr-sucursal/windows/1.2.0/QR_Sucursal_Windows_x64_COMPLETO.zip'
        )
    );

NOTIFY pgrst, 'reload schema';

COMMIT;
