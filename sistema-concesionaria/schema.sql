-- =====================================================================
--  Sistema de órdenes de instalación — Concesionaria
--  Esquema PostgreSQL 16+ : modelo de datos + reglas de negocio
-- =====================================================================
--  La base de datos garantiza estas reglas AUNQUE la aplicación tenga un bug:
--
--   1. Una orden sólo avanza por transiciones válidas (máquina de estados).
--   2. Una orden confirmada siempre tiene cliente y vehículo (patente o VIN)
--      y al menos un ítem a instalar.
--   3. Un operario no puede tener dos turnos superpuestos; un puesto tampoco.
--   4. El calendario maneja el estado: asignar turno => AGENDADA,
--      quitar el último turno => vuelve a CONFIRMADA, cancelar orden => libera turnos.
--   5. ENTREGADA exige un acta firmada; el acta es inmutable y su hash
--      se verifica contra el contenido exacto que vio el cliente.
--   6. Cada cambio de estado queda en un historial que no se puede editar ni borrar.
--   7. Una operación enviada por una tablet se aplica UNA sola vez (idempotencia),
--      aunque la tablet la reintente 20 veces por mala conexión.
--
--  Contexto de auditoría: dentro de cada transacción la API ejecuta
--      SET LOCAL app.usuario_id     = '<uuid>';
--      SET LOCAL app.dispositivo_id = '<uuid>';   -- si viene de una tablet
--  y los triggers lo registran en el historial.
-- =====================================================================

BEGIN;

CREATE EXTENSION IF NOT EXISTS btree_gist;   -- para EXCLUDE (operario =, rango &&)

-- ---------------------------------------------------------------------
-- Utilidades
-- ---------------------------------------------------------------------
CREATE FUNCTION ctx_uuid(clave text) RETURNS uuid
LANGUAGE sql STABLE AS $$
    SELECT NULLIF(current_setting(clave, true), '')::uuid
$$;

-- "ab 123 cd" / "AB-123-CD" -> "AB123CD"
CREATE FUNCTION normalizar_identificador(p text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT NULLIF(upper(regexp_replace(p, '[^A-Za-z0-9]', '', 'g')), '')
$$;

-- Para tablas append-only / registros inmutables
CREATE FUNCTION prohibir_cambios() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION '% en % no está permitido (registro inmutable)', TG_OP, TG_TABLE_NAME
        USING ERRCODE = 'restrict_violation';
END
$$;

-- ---------------------------------------------------------------------
-- Tipos
-- ---------------------------------------------------------------------
CREATE TYPE rol_usuario      AS ENUM ('ADMIN', 'COORDINADOR', 'VENDEDOR', 'OPERARIO', 'ENTREGA');
CREATE TYPE estado_orden     AS ENUM ('BORRADOR', 'CONFIRMADA', 'AGENDADA', 'EN_CURSO',
                                      'PAUSADA', 'TERMINADA', 'ENTREGADA', 'CANCELADA');
CREATE TYPE origen_orden     AS ENUM ('WHATSAPP', 'MOSTRADOR', 'TELEFONO', 'CONTINGENCIA_PAPEL');
CREATE TYPE estado_turno     AS ENUM ('VIGENTE', 'CANCELADO');
CREATE TYPE tipo_dispositivo AS ENUM ('TABLET_OPERARIO', 'TABLET_FIRMA');
CREATE TYPE tipo_adjunto     AS ENUM ('FOTO_ANTES', 'FOTO_DESPUES', 'FOTO_OTRA',
                                      'FIRMA_TRAZOS', 'ACTA_PDF', 'PAPEL_ESCANEADO');
CREATE TYPE resultado_op     AS ENUM ('APLICADA', 'CONFLICTO', 'RECHAZADA');

-- ---------------------------------------------------------------------
-- Personas y equipos
-- ---------------------------------------------------------------------
CREATE TABLE usuario (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    nombre         text NOT NULL,
    email          text,
    rol            rol_usuario NOT NULL,
    password_hash  text,                 -- back-office (argon2id)
    pin_hash       text,                 -- operarios: PIN corto, válido SOLO en una tablet enrolada
    mfa_activo     boolean NOT NULL DEFAULT false,
    activo         boolean NOT NULL DEFAULT true,
    creado_en      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT usuario_email_backoffice CHECK (rol = 'OPERARIO' OR email IS NOT NULL)
);
CREATE UNIQUE INDEX usuario_email_uq ON usuario (lower(email));

-- Tablets enroladas. Una tablet que no está acá (o está revocada) no puede hablar con la API.
CREATE TABLE dispositivo (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    nombre          text NOT NULL UNIQUE,          -- "Tablet Box 2", "Tablet Firma Entregas"
    tipo            tipo_dispositivo NOT NULL,
    clave_publica   text NOT NULL,                 -- par de claves generado en la tablet al enrolarla
    activa          boolean NOT NULL DEFAULT true, -- false = revocada (pérdida/robo): se rechaza todo
    -- telemetría que la tablet reporta en cada sync (tablero "estado de tablets")
    app_version     text,
    ultima_sync_en  timestamptz,
    ops_pendientes  integer CHECK (ops_pendientes >= 0),
    bateria_pct     smallint CHECK (bateria_pct BETWEEN 0 AND 100),
    enrolada_en     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE puesto (              -- box / elevador / lugar físico de instalación
    id      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    nombre  text NOT NULL UNIQUE,
    activo  boolean NOT NULL DEFAULT true
);

-- ---------------------------------------------------------------------
-- Clientes y vehículos
-- ---------------------------------------------------------------------
CREATE TABLE cliente (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    nombre          text NOT NULL,                 -- nombre y apellido o razón social
    doc_tipo        text CHECK (doc_tipo IN ('DNI', 'CUIT', 'CUIL', 'PASAPORTE')),
    doc_numero      text,
    telefono_e164   text CHECK (telefono_e164 ~ '^\+[1-9][0-9]{7,14}$'),  -- ej. +5491155551234
    email           text,
    creado_en       timestamptz NOT NULL DEFAULT now(),
    actualizado_en  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT cliente_doc_completo CHECK ((doc_tipo IS NULL) = (doc_numero IS NULL)),
    CONSTRAINT cliente_doc_uq UNIQUE (doc_tipo, doc_numero)
);
-- Al entrar un WhatsApp se busca el cliente por teléfono (no es único: familia, empresa).
CREATE INDEX cliente_telefono_idx ON cliente (telefono_e164);

CREATE TABLE vehiculo (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    -- Formatos AR: auto viejo ABC123, auto Mercosur AB123CD, moto Mercosur A123BCD, moto vieja 123ABC.
    -- Ajustar si trabajan con otros formatos.
    patente         text UNIQUE CHECK (patente ~ '^([A-Z]{3}[0-9]{3}|[A-Z]{2}[0-9]{3}[A-Z]{2}|[A-Z][0-9]{3}[A-Z]{3}|[0-9]{3}[A-Z]{3})$'),
    vin             text UNIQUE CHECK (vin ~ '^[A-HJ-NPR-Z0-9]{17}$'),   -- nro. de chasis (sin I, O, Q)
    marca           text,
    modelo          text,
    anio            smallint CHECK (anio BETWEEN 1950 AND 2100),
    color           text,
    cliente_id      uuid REFERENCES cliente (id),  -- titular / cliente actual
    creado_en       timestamptz NOT NULL DEFAULT now(),
    actualizado_en  timestamptz NOT NULL DEFAULT now(),
    -- Un 0km puede no tener patente todavía: se identifica por VIN y la patente se agrega después.
    CONSTRAINT vehiculo_identificable CHECK (patente IS NOT NULL OR vin IS NOT NULL)
);
CREATE INDEX vehiculo_cliente_idx ON vehiculo (cliente_id);

CREATE FUNCTION vehiculo_normalizar() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    NEW.patente := normalizar_identificador(NEW.patente);
    NEW.vin     := normalizar_identificador(NEW.vin);
    NEW.actualizado_en := now();
    RETURN NEW;
END
$$;
CREATE TRIGGER vehiculo_normalizar BEFORE INSERT OR UPDATE ON vehiculo
    FOR EACH ROW EXECUTE FUNCTION vehiculo_normalizar();

-- ---------------------------------------------------------------------
-- Órdenes
-- ---------------------------------------------------------------------
CREATE TABLE catalogo_trabajo (    -- qué se instala y cuánto tarda (alimenta el calendario)
    id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    codigo                text NOT NULL UNIQUE,
    descripcion           text NOT NULL,
    duracion_estimada_min integer NOT NULL CHECK (duracion_estimada_min > 0),
    activo                boolean NOT NULL DEFAULT true
);

CREATE SEQUENCE orden_numero_seq START 1000;

CREATE TABLE orden (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    numero          bigint NOT NULL UNIQUE DEFAULT nextval('orden_numero_seq'),  -- visible: "OT-1000"
    estado          estado_orden NOT NULL DEFAULT 'BORRADOR',
    cliente_id      uuid REFERENCES cliente (id),
    vehiculo_id     uuid REFERENCES vehiculo (id),
    origen          origen_orden NOT NULL,
    numero_papel    text UNIQUE,                   -- talonario de contingencia, ej. "C-0042"
    whatsapp_chat   text,                          -- conversación que originó la orden
    descripcion     text,
    creada_por      uuid NOT NULL REFERENCES usuario (id),
    version         integer NOT NULL DEFAULT 1,    -- concurrencia optimista: UPDATE ... WHERE version = $leida
    creada_en       timestamptz NOT NULL DEFAULT now(),
    actualizada_en  timestamptz NOT NULL DEFAULT now(),
    -- Un borrador puede nacer de un WhatsApp sin datos completos; a partir de CONFIRMADA no.
    CONSTRAINT orden_datos_minimos CHECK (
        estado IN ('BORRADOR', 'CANCELADA') OR (cliente_id IS NOT NULL AND vehiculo_id IS NOT NULL)),
    CONSTRAINT orden_papel CHECK ((origen = 'CONTINGENCIA_PAPEL') = (numero_papel IS NOT NULL))
);
CREATE INDEX orden_cliente_idx  ON orden (cliente_id);
CREATE INDEX orden_vehiculo_idx ON orden (vehiculo_id);
CREATE INDEX orden_abiertas_idx ON orden (estado) WHERE estado NOT IN ('ENTREGADA', 'CANCELADA');

CREATE TABLE orden_item (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    orden_id       uuid NOT NULL REFERENCES orden (id),
    trabajo_id     uuid REFERENCES catalogo_trabajo (id),
    descripcion    text NOT NULL,
    cantidad       numeric(10, 2) NOT NULL DEFAULT 1 CHECK (cantidad > 0),
    observaciones  text,
    hecho_en       timestamptz,                    -- lo marca el operario desde la tablet
    hecho_por      uuid REFERENCES usuario (id),
    CONSTRAINT item_hecho_completo CHECK ((hecho_en IS NULL) = (hecho_por IS NULL))
);
CREATE INDEX orden_item_orden_idx ON orden_item (orden_id);

-- Máquina de estados: única fuente de verdad de qué transición es válida.
CREATE TABLE transicion_orden (
    desde        estado_orden NOT NULL,
    hacia        estado_orden NOT NULL,
    descripcion  text NOT NULL,
    PRIMARY KEY (desde, hacia)
);
INSERT INTO transicion_orden (desde, hacia, descripcion) VALUES
    ('BORRADOR',   'CONFIRMADA', 'Datos completos: cliente, vehículo e ítems'),
    ('BORRADOR',   'CANCELADA',  'Consulta que no prosperó'),
    ('CONFIRMADA', 'AGENDADA',   'Se asignó turno en el calendario (automático)'),
    ('CONFIRMADA', 'CANCELADA',  'El cliente desiste'),
    ('AGENDADA',   'CONFIRMADA', 'Se quitó el último turno: queda para reprogramar (automático)'),
    ('AGENDADA',   'EN_CURSO',   'El operario inicia en la tablet'),
    ('AGENDADA',   'CANCELADA',  'El cliente desiste'),
    ('EN_CURSO',   'PAUSADA',    'Falta repuesto, falta el cliente, etc.'),
    ('EN_CURSO',   'TERMINADA',  'El operario cierra checklist y fotos'),
    ('PAUSADA',    'EN_CURSO',   'Se retoma'),
    ('PAUSADA',    'AGENDADA',   'Se retoma en otro turno'),
    ('PAUSADA',    'CANCELADA',  'Se abandona el trabajo'),
    ('TERMINADA',  'EN_CURSO',   'Control de calidad rechaza: se reabre'),
    ('TERMINADA',  'ENTREGADA',  'El cliente firmó el acta de entrega');

-- ---------------------------------------------------------------------
-- Calendario
-- ---------------------------------------------------------------------
CREATE TABLE turno (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    orden_id      uuid NOT NULL REFERENCES orden (id),
    operario_id   uuid NOT NULL REFERENCES usuario (id),
    puesto_id     uuid REFERENCES puesto (id),
    rango         tstzrange NOT NULL,              -- [inicio, fin)  -> 9:00-10:00 y 10:00-11:00 no chocan
    estado        estado_turno NOT NULL DEFAULT 'VIGENTE',
    asignado_por  uuid NOT NULL REFERENCES usuario (id),
    creado_en     timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT turno_rango_valido CHECK (NOT isempty(rango) AND NOT lower_inf(rango) AND NOT upper_inf(rango)),
    -- Un operario no puede estar en dos lugares a la vez; un puesto no puede tener dos autos.
    CONSTRAINT turno_sin_superposicion_operario
        EXCLUDE USING gist (operario_id WITH =, rango WITH &&) WHERE (estado = 'VIGENTE'),
    CONSTRAINT turno_sin_superposicion_puesto
        EXCLUDE USING gist (puesto_id WITH =, rango WITH &&) WHERE (estado = 'VIGENTE')
);
-- Varias filas vigentes por orden son válidas: dos operarios juntos o un trabajo de varios días.
CREATE INDEX turno_orden_idx  ON turno (orden_id);
CREATE INDEX turno_agenda_idx ON turno USING gist (rango) WHERE estado = 'VIGENTE';

-- ---------------------------------------------------------------------
-- Evidencia: fotos, firmas, PDFs (el binario vive en object storage)
-- ---------------------------------------------------------------------
CREATE TABLE adjunto (
    id              uuid PRIMARY KEY,              -- lo genera la tablet (UUIDv7) => reintentos idempotentes
    orden_id        uuid NOT NULL REFERENCES orden (id),
    tipo            tipo_adjunto NOT NULL,
    storage_key     text NOT NULL UNIQUE,
    sha256          text NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    bytes           integer CHECK (bytes > 0),
    mime            text NOT NULL,
    capturado_en    timestamptz NOT NULL,          -- reloj de la tablet
    dispositivo_id  uuid REFERENCES dispositivo (id),
    usuario_id      uuid REFERENCES usuario (id),
    subido_en       timestamptz                    -- NULL = llegó la metadata, el binario se sigue subiendo
);
CREATE INDEX adjunto_orden_idx ON adjunto (orden_id);

CREATE TABLE acta_entrega (
    id                  uuid PRIMARY KEY,          -- lo genera la tablet de firma
    orden_id            uuid NOT NULL UNIQUE REFERENCES orden (id),
    -- JSON canónico EXACTO que se le mostró al cliente y que la tablet hasheó:
    -- cliente, vehículo, trabajos, fotos (por hash), texto de conformidad, versión del texto legal.
    contenido_canonico  text NOT NULL,
    contenido_sha256    text NOT NULL,
    firmante_nombre     text NOT NULL,
    firmante_doc        text NOT NULL,
    conformidad         text NOT NULL CHECK (conformidad IN ('CONFORME', 'CON_OBSERVACIONES')),
    observaciones       text,
    firma_trazos_id     uuid NOT NULL REFERENCES adjunto (id),  -- trazos x,y,t,presión (no sólo una imagen)
    pdf_id              uuid REFERENCES adjunto (id),           -- lo genera el servidor después
    entregado_por       uuid NOT NULL REFERENCES usuario (id),
    dispositivo_id      uuid NOT NULL REFERENCES dispositivo (id),
    firmado_en          timestamptz NOT NULL,      -- reloj de la tablet
    recibido_en         timestamptz NOT NULL DEFAULT now(),  -- reloj del servidor
    CONSTRAINT acta_contenido_es_json CHECK (contenido_canonico::jsonb IS NOT NULL),
    CONSTRAINT acta_hash_valido CHECK (
        contenido_sha256 = encode(sha256(convert_to(contenido_canonico, 'UTF8')), 'hex')),
    CONSTRAINT acta_observaciones CHECK (conformidad = 'CONFORME' OR observaciones IS NOT NULL)
);

-- El acta no se toca. Única excepción: adjuntar el PDF una vez, cuando el servidor lo genera.
CREATE FUNCTION acta_inmutable() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.pdf_id IS NULL
       AND (to_jsonb(NEW) - 'pdf_id') = (to_jsonb(OLD) - 'pdf_id') THEN
        RETURN NEW;
    END IF;
    RAISE EXCEPTION 'El acta de entrega % es inmutable', OLD.id USING ERRCODE = 'restrict_violation';
END
$$;
CREATE TRIGGER acta_inmutable BEFORE UPDATE ON acta_entrega
    FOR EACH ROW EXECUTE FUNCTION acta_inmutable();
CREATE TRIGGER acta_sin_borrado BEFORE DELETE ON acta_entrega
    FOR EACH ROW EXECUTE FUNCTION prohibir_cambios();

-- ---------------------------------------------------------------------
-- Historial (append-only) y sincronización de tablets
-- ---------------------------------------------------------------------
CREATE TABLE evento_orden (
    id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    orden_id         uuid NOT NULL REFERENCES orden (id),
    tipo             text NOT NULL,                -- CREADA, CAMBIO_ESTADO, ...
    estado_anterior  estado_orden,
    estado_nuevo     estado_orden,
    usuario_id       uuid,
    dispositivo_id   uuid,
    datos            jsonb,
    ocurrido_en      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX evento_orden_orden_idx ON evento_orden (orden_id, id);
CREATE TRIGGER evento_orden_append_only BEFORE UPDATE OR DELETE ON evento_orden
    FOR EACH ROW EXECUTE FUNCTION prohibir_cambios();

-- Cada acción de una tablet llega como "operación" con id generado en la tablet.
-- Si llega dos veces (reintento), el INSERT choca con la PK y la API responde el resultado original.
CREATE TABLE operacion_sync (
    id              uuid PRIMARY KEY,              -- UUIDv7 generado en la tablet
    dispositivo_id  uuid NOT NULL REFERENCES dispositivo (id),
    usuario_id      uuid REFERENCES usuario (id),
    orden_id        uuid REFERENCES orden (id),
    tipo            text NOT NULL,                 -- INICIAR, MARCAR_ITEM, PAUSAR, TERMINAR, FIRMAR_ENTREGA...
    payload         jsonb NOT NULL,
    ocurrida_en     timestamptz NOT NULL,          -- reloj de la tablet
    recibida_en     timestamptz NOT NULL DEFAULT now(),
    resultado       resultado_op NOT NULL,
    detalle         text,
    resuelto_por    uuid REFERENCES usuario (id),  -- para CONFLICTO: quién lo resolvió en el back-office
    resuelto_en     timestamptz
);
CREATE INDEX operacion_sync_conflictos_idx ON operacion_sync (recibida_en)
    WHERE resultado = 'CONFLICTO' AND resuelto_en IS NULL;

-- ---------------------------------------------------------------------
-- Triggers de la orden: máquina de estados + historial
-- ---------------------------------------------------------------------
CREATE FUNCTION orden_validar_cambio() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.id <> OLD.id OR NEW.numero <> OLD.numero OR NEW.origen <> OLD.origen THEN
        RAISE EXCEPTION 'id, número y origen de la orden no se pueden modificar'
            USING ERRCODE = 'restrict_violation';
    END IF;

    IF NEW.estado IS DISTINCT FROM OLD.estado THEN
        IF NOT EXISTS (SELECT 1 FROM transicion_orden WHERE desde = OLD.estado AND hacia = NEW.estado) THEN
            RAISE EXCEPTION 'Transición inválida en OT-%: % -> %', OLD.numero, OLD.estado, NEW.estado
                USING ERRCODE = 'check_violation';
        END IF;
        IF NEW.estado = 'CONFIRMADA' AND NOT EXISTS (SELECT 1 FROM orden_item WHERE orden_id = NEW.id) THEN
            RAISE EXCEPTION 'OT-% no tiene ítems a instalar', NEW.numero USING ERRCODE = 'check_violation';
        END IF;
        IF NEW.estado = 'AGENDADA'
           AND NOT EXISTS (SELECT 1 FROM turno WHERE orden_id = NEW.id AND estado = 'VIGENTE') THEN
            RAISE EXCEPTION 'OT-% no tiene turno asignado', NEW.numero USING ERRCODE = 'check_violation';
        END IF;
        IF NEW.estado = 'ENTREGADA' AND NOT EXISTS (SELECT 1 FROM acta_entrega WHERE orden_id = NEW.id) THEN
            RAISE EXCEPTION 'OT-% no tiene acta de entrega firmada', NEW.numero USING ERRCODE = 'check_violation';
        END IF;
    END IF;

    NEW.version        := OLD.version + 1;
    NEW.actualizada_en := now();
    RETURN NEW;
END
$$;
CREATE TRIGGER orden_validar_cambio BEFORE UPDATE ON orden
    FOR EACH ROW EXECUTE FUNCTION orden_validar_cambio();
CREATE TRIGGER orden_sin_borrado BEFORE DELETE ON orden
    FOR EACH ROW EXECUTE FUNCTION prohibir_cambios();   -- las órdenes se cancelan, no se borran

CREATE FUNCTION orden_registrar_evento() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO evento_orden (orden_id, tipo, estado_nuevo, usuario_id, dispositivo_id, datos)
        VALUES (NEW.id, 'CREADA', NEW.estado,
                COALESCE(ctx_uuid('app.usuario_id'), NEW.creada_por), ctx_uuid('app.dispositivo_id'),
                jsonb_build_object('origen', NEW.origen));
    ELSIF NEW.estado IS DISTINCT FROM OLD.estado THEN
        INSERT INTO evento_orden (orden_id, tipo, estado_anterior, estado_nuevo, usuario_id, dispositivo_id)
        VALUES (NEW.id, 'CAMBIO_ESTADO', OLD.estado, NEW.estado,
                ctx_uuid('app.usuario_id'), ctx_uuid('app.dispositivo_id'));

        IF NEW.estado = 'CANCELADA' THEN      -- liberar el calendario
            UPDATE turno SET estado = 'CANCELADO' WHERE orden_id = NEW.id AND estado = 'VIGENTE';
        END IF;
    END IF;
    RETURN NULL;
END
$$;
CREATE TRIGGER orden_registrar_evento AFTER INSERT OR UPDATE ON orden
    FOR EACH ROW EXECUTE FUNCTION orden_registrar_evento();

-- ---------------------------------------------------------------------
-- Triggers del turno: el calendario maneja el estado de la orden
-- ---------------------------------------------------------------------
CREATE FUNCTION turno_validar() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_estado_orden estado_orden;
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF OLD.estado = 'CANCELADO' THEN
            RAISE EXCEPTION 'Un turno cancelado no se reactiva: crear uno nuevo'
                USING ERRCODE = 'restrict_violation';
        END IF;
        IF NEW.orden_id <> OLD.orden_id THEN
            RAISE EXCEPTION 'Un turno no se puede mover a otra orden' USING ERRCODE = 'restrict_violation';
        END IF;
    END IF;

    IF NEW.estado = 'VIGENTE' THEN
        IF NOT EXISTS (SELECT 1 FROM usuario WHERE id = NEW.operario_id AND rol = 'OPERARIO' AND activo) THEN
            RAISE EXCEPTION 'El usuario % no es un operario activo', NEW.operario_id
                USING ERRCODE = 'check_violation';
        END IF;
        SELECT estado INTO v_estado_orden FROM orden WHERE id = NEW.orden_id;
        IF v_estado_orden NOT IN ('CONFIRMADA', 'AGENDADA', 'EN_CURSO', 'PAUSADA') THEN
            RAISE EXCEPTION 'No se puede agendar una orden en estado %', v_estado_orden
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    RETURN NEW;
END
$$;
CREATE TRIGGER turno_validar BEFORE INSERT OR UPDATE ON turno
    FOR EACH ROW EXECUTE FUNCTION turno_validar();
CREATE TRIGGER turno_sin_borrado BEFORE DELETE ON turno
    FOR EACH ROW EXECUTE FUNCTION prohibir_cambios();   -- se cancelan, no se borran (queda la historia)

CREATE FUNCTION turno_sincronizar_orden() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.estado = 'VIGENTE' THEN
        -- asignar turno => la orden queda agendada
        UPDATE orden SET estado = 'AGENDADA'
         WHERE id = NEW.orden_id AND estado IN ('CONFIRMADA', 'PAUSADA');
    ELSIF TG_OP = 'UPDATE' AND OLD.estado = 'VIGENTE' THEN
        -- se quitó el último turno de una orden agendada => vuelve a "para reprogramar"
        UPDATE orden SET estado = 'CONFIRMADA'
         WHERE id = NEW.orden_id AND estado = 'AGENDADA'
           AND NOT EXISTS (SELECT 1 FROM turno WHERE orden_id = NEW.orden_id AND estado = 'VIGENTE');
    END IF;
    RETURN NULL;
END
$$;
CREATE TRIGGER turno_sincronizar_orden AFTER INSERT OR UPDATE ON turno
    FOR EACH ROW EXECUTE FUNCTION turno_sincronizar_orden();

-- ---------------------------------------------------------------------
-- Vistas
-- ---------------------------------------------------------------------
-- Lo que muestra el calendario del back-office y lo que baja cada tablet de operario.
CREATE VIEW vista_agenda AS
SELECT t.id                AS turno_id,
       lower(t.rango)      AS inicio,
       upper(t.rango)      AS fin,
       t.operario_id,
       op.nombre           AS operario,
       p.nombre            AS puesto,
       o.id                AS orden_id,
       'OT-' || o.numero   AS orden,
       o.estado            AS estado_orden,
       c.nombre            AS cliente,
       c.telefono_e164     AS telefono,
       COALESCE(v.patente, v.vin) AS vehiculo,
       v.marca, v.modelo, v.color
  FROM turno t
  JOIN orden o         ON o.id  = t.orden_id
  JOIN usuario op      ON op.id = t.operario_id
  LEFT JOIN puesto p   ON p.id  = t.puesto_id
  LEFT JOIN cliente c  ON c.id  = o.cliente_id
  LEFT JOIN vehiculo v ON v.id  = o.vehiculo_id
 WHERE t.estado = 'VIGENTE';

-- Semáforo de tablets para el tablero de operaciones.
CREATE VIEW vista_estado_tablets AS
SELECT d.id, d.nombre, d.tipo, d.app_version, d.ultima_sync_en, d.ops_pendientes, d.bateria_pct,
       CASE
           WHEN NOT d.activa                                         THEN 'REVOCADA'
           WHEN d.ultima_sync_en IS NULL
             OR d.ultima_sync_en < now() - interval '30 minutes'     THEN 'ROJO'
           WHEN d.ultima_sync_en < now() - interval '5 minutes'
             OR COALESCE(d.ops_pendientes, 0) > 0
             OR COALESCE(d.bateria_pct, 100) < 20                    THEN 'AMARILLO'
           ELSE 'VERDE'
       END AS semaforo
  FROM dispositivo d;

COMMIT;
