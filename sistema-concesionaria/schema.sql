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
--   8. Plan de emergencia: lo que se carga después desde papel guarda la hora REAL
--      y la hora de carga; el acta en papel exige el escaneo; el acceso desde un
--      celular personal es temporal, lo habilita un coordinador y queda marcado.
--   9. Seguridad de acceso (SEGURIDAD.md): cada rol sólo puede entrar con los métodos
--      que le corresponden (admin y administración: sólo passkey); las sesiones tienen
--      duración máxima; dar de baja a alguien, cambiarle el rol o revocar su tablet corta
--      sus sesiones al instante; todo ingreso queda en un registro que no se puede borrar.
--      DNI/CUIT, teléfono y email se guardan CIFRADOS: la base nunca los ve en claro.
--  10. Facturación: un comprobante emitido no se modifica (se corrige con nota de crédito),
--      sus totales tienen que coincidir con los ítems, la numeración es correlativa y
--      sólo Administración puede emitir.
--  11. Agentes de IA (AGENTES.md): los agentes sólo PROPONEN. Una propuesta nace pendiente,
--      la revisa una persona con el rol que corresponde a ese tipo, vence si nadie la revisa,
--      y lo propuesto no se puede editar después.
--  12. Historia clínica del vehículo (PROCESO.md): la historia es del auto, no del dueño.
--      Hallazgos y componentes instalados (con serie y garantía) no se borran; los cambios
--      de titular quedan registrados.
--  13. Unidad de trabajo: la ORDEN es la visita; la TAREA es lo que se ejecuta. Con la orden
--      confirmada, una tarea nueva dice de dónde sale (hallazgo o pedido del cliente) y por qué,
--      un trabajo adicional con costo no se hace sin la aprobación del cliente, lo pactado no
--      se edita (se cancela con motivo y se agrega otra) y no se termina con tareas pendientes.
--  14. Stock: libro de movimientos que no se borra; un ajuste lo aprueba otra persona.
--      Listas de precios por marca: sólo el responsable de la marca las aprueba, cada variación
--      grande se confirma una por una y la base calcula la variación (no el importador).
--
--  Contexto de auditoría: dentro de cada transacción la API ejecuta
--      SET LOCAL app.usuario_id           = '<uuid>';
--      SET LOCAL app.dispositivo_id       = '<uuid>';   -- tablet o celular de la empresa
--      SET LOCAL app.acceso_emergencia_id = '<uuid>';   -- nivel 3: celular personal
--      SET LOCAL app.hora_real            = '<fecha>';  -- carga diferida desde papel
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

-- Hora en que ocurrió un hecho. Normalmente "ahora"; en una carga diferida desde papel,
-- la hora real anotada. Rechaza horas futuras y cargas de más de 7 días (casi seguro un error de tipeo).
CREATE FUNCTION hora_del_evento() RETURNS timestamptz
LANGUAGE plpgsql STABLE AS $$
DECLARE
    h timestamptz := NULLIF(current_setting('app.hora_real', true), '')::timestamptz;
BEGIN
    IF h IS NULL THEN
        RETURN now();
    END IF;
    IF h > now() + interval '5 minutes' THEN
        RAISE EXCEPTION 'La hora real (%) no puede estar en el futuro', h USING ERRCODE = 'check_violation';
    END IF;
    IF h < now() - interval '7 days' THEN
        RAISE EXCEPTION 'La hora real (%) tiene más de 7 días: revisar la fecha', h USING ERRCODE = 'check_violation';
    END IF;
    RETURN h;
END
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
CREATE TYPE rol_usuario      AS ENUM ('ADMIN', 'ADMINISTRACION', 'COORDINADOR', 'VENDEDOR', 'OPERARIO', 'ENTREGA');
CREATE TYPE nivel_autenticacion AS ENUM ('PASSKEY', 'PASSWORD_TOTP', 'PIN_DISPOSITIVO', 'CODIGO_EMERGENCIA');
CREATE TYPE tipo_comprobante AS ENUM ('FACTURA_A', 'FACTURA_B', 'FACTURA_C',
                                      'NOTA_CREDITO_A', 'NOTA_CREDITO_B', 'NOTA_CREDITO_C');
CREATE TYPE estado_comprobante AS ENUM ('BORRADOR', 'EMITIDO', 'ANULADO');
CREATE TYPE estado_orden     AS ENUM ('BORRADOR', 'CONFIRMADA', 'AGENDADA', 'EN_CURSO',
                                      'PAUSADA', 'TERMINADA', 'ENTREGADA', 'CANCELADA');
CREATE TYPE origen_orden     AS ENUM ('WHATSAPP', 'MOSTRADOR', 'TELEFONO', 'CONTINGENCIA_PAPEL');
CREATE TYPE estado_turno     AS ENUM ('VIGENTE', 'CANCELADO');
CREATE TYPE tipo_dispositivo AS ENUM ('TABLET_OPERARIO', 'TABLET_FIRMA', 'CELULAR_EMPRESA');
CREATE TYPE medio_firma      AS ENUM ('DIGITAL', 'PAPEL');
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
    password_hash  text,                 -- sólo roles que pueden usar PASSWORD_TOTP (argon2id)
    totp_secreto_cifrado bytea,          -- segundo factor; cifrado con el KMS como los datos de clientes
    pin_hash       text,                 -- PIN de 6 dígitos, válido SOLO en un equipo enrolado
    intentos_fallidos smallint NOT NULL DEFAULT 0,
    bloqueado_hasta   timestamptz,       -- bloqueo temporal por intentos fallidos
    activo         boolean NOT NULL DEFAULT true,
    creado_en      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT usuario_email_backoffice CHECK (rol = 'OPERARIO' OR email IS NOT NULL)
);
CREATE UNIQUE INDEX usuario_email_uq ON usuario (lower(email));
CREATE TRIGGER usuario_sin_borrado BEFORE DELETE ON usuario
    FOR EACH ROW EXECUTE FUNCTION prohibir_cambios();   -- se desactivan, no se borran (queda la historia)

-- Tablets y celulares de la empresa enrolados. Un equipo que no está acá (o está revocado)
-- no puede hablar con la API, salvo con un acceso de emergencia (ver abajo).
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

-- Plan de emergencia, nivel 3: entrar desde un celular personal (no enrolado).
-- Lo habilita un coordinador o admin, por persona, con un código de un solo uso que vence en <= 12 h.
-- Permisos mínimos (los aplica la API): ver la propia agenda y marcar avance. Nunca firma del cliente.
CREATE TABLE acceso_emergencia (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    usuario_id      uuid NOT NULL REFERENCES usuario (id),
    habilitado_por  uuid NOT NULL REFERENCES usuario (id),
    codigo_hash     text NOT NULL,
    motivo          text NOT NULL,
    creado_en       timestamptz NOT NULL DEFAULT now(),
    vence_en        timestamptz NOT NULL,
    usado_en        timestamptz,
    revocado_en     timestamptz,                   -- "revocar todos" al volver a la normalidad
    CONSTRAINT acceso_emergencia_vigencia
        CHECK (vence_en > creado_en AND vence_en <= creado_en + interval '12 hours'),
    CONSTRAINT acceso_emergencia_no_propio CHECK (usuario_id <> habilitado_por)
);
CREATE INDEX acceso_emergencia_abiertos_idx ON acceso_emergencia (usuario_id) WHERE revocado_en IS NULL;

CREATE FUNCTION acceso_emergencia_validar() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM usuario
                    WHERE id = NEW.habilitado_por AND rol IN ('ADMIN', 'COORDINADOR') AND activo) THEN
        RAISE EXCEPTION 'Sólo un coordinador o admin puede habilitar un acceso de emergencia'
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END
$$;
CREATE TRIGGER acceso_emergencia_validar BEFORE INSERT ON acceso_emergencia
    FOR EACH ROW EXECUTE FUNCTION acceso_emergencia_validar();

-- ---------------------------------------------------------------------
-- Seguridad de acceso (ver SEGURIDAD.md)
-- ---------------------------------------------------------------------
-- Con qué método puede entrar cada rol y cuánto dura su sesión: la política escrita como datos.
-- Si un rol no figura con un método, la base rechaza la sesión aunque la API tenga un bug.
CREATE TABLE politica_acceso (
    rol              rol_usuario NOT NULL,
    nivel            nivel_autenticacion NOT NULL,
    duracion_max     interval NOT NULL,     -- vida máxima de la sesión
    inactividad_max  interval NOT NULL,     -- sin uso por más de esto, la API pide autenticarse de nuevo
    PRIMARY KEY (rol, nivel)
);
INSERT INTO politica_acceso (rol, nivel, duracion_max, inactividad_max) VALUES
    ('ADMIN',          'PASSKEY',           '8 hours',  '15 minutes'),
    ('ADMINISTRACION', 'PASSKEY',           '8 hours',  '15 minutes'),
    ('COORDINADOR',    'PASSKEY',           '12 hours', '30 minutes'),
    ('COORDINADOR',    'PASSWORD_TOTP',     '12 hours', '30 minutes'),
    ('VENDEDOR',       'PASSKEY',           '12 hours', '30 minutes'),
    ('VENDEDOR',       'PASSWORD_TOTP',     '12 hours', '30 minutes'),
    ('ENTREGA',        'PASSKEY',           '12 hours', '30 minutes'),
    ('ENTREGA',        'PASSWORD_TOTP',     '12 hours', '30 minutes'),
    ('ENTREGA',        'PIN_DISPOSITIVO',   '12 hours', '5 minutes'),
    ('OPERARIO',       'PIN_DISPOSITIVO',   '12 hours', '5 minutes'),
    ('OPERARIO',       'CODIGO_EMERGENCIA', '12 hours', '30 minutes');

-- Passkeys / llaves físicas (FIDO2 / WebAuthn). Se registran 2 por persona: principal y respaldo.
CREATE TABLE credencial_passkey (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    usuario_id       uuid NOT NULL REFERENCES usuario (id),
    credential_id    bytea NOT NULL UNIQUE,
    clave_publica    bytea NOT NULL,               -- la clave privada nunca sale del equipo/llave
    contador_firmas  bigint NOT NULL DEFAULT 0,    -- si retrocede, la llave pudo ser clonada: se bloquea
    nombre           text NOT NULL,                -- "Llave principal", "Llave de respaldo (caja fuerte)"
    creada_en        timestamptz NOT NULL DEFAULT now(),
    ultimo_uso_en    timestamptz,
    revocada_en      timestamptz
);
CREATE INDEX credencial_passkey_usuario_idx ON credencial_passkey (usuario_id) WHERE revocada_en IS NULL;

-- Registro de seguridad: ingresos, bloqueos, cambios de permisos, datos sensibles vistos, exportaciones.
CREATE TABLE evento_seguridad (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tipo            text NOT NULL,
    usuario_id      uuid,
    sesion_id       uuid,
    dispositivo_id  uuid,
    ip              inet,
    detalle         jsonb,
    ocurrido_en     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX evento_seguridad_usuario_idx ON evento_seguridad (usuario_id, ocurrido_en);
CREATE TRIGGER evento_seguridad_append_only BEFORE UPDATE OR DELETE ON evento_seguridad
    FOR EACH ROW EXECUTE FUNCTION prohibir_cambios();

CREATE TABLE sesion (
    id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    token_hash            bytea NOT NULL UNIQUE CHECK (octet_length(token_hash) = 32),  -- SHA-256: el token nunca se guarda
    usuario_id            uuid NOT NULL REFERENCES usuario (id),
    nivel                 nivel_autenticacion NOT NULL,
    dispositivo_id        uuid REFERENCES dispositivo (id),
    acceso_emergencia_id  uuid REFERENCES acceso_emergencia (id),
    ip                    inet,
    user_agent            text,
    creada_en             timestamptz NOT NULL DEFAULT now(),
    ultima_actividad_en   timestamptz NOT NULL DEFAULT now(),
    reautenticada_en      timestamptz,          -- última confirmación con passkey para una acción crítica
    expira_en             timestamptz NOT NULL,
    revocada_en           timestamptz,
    CONSTRAINT sesion_pin_requiere_equipo CHECK (nivel <> 'PIN_DISPOSITIVO' OR dispositivo_id IS NOT NULL),
    CONSTRAINT sesion_codigo_emergencia CHECK ((nivel = 'CODIGO_EMERGENCIA') = (acceso_emergencia_id IS NOT NULL)),
    CONSTRAINT sesion_vigencia CHECK (expira_en > creada_en)
);
CREATE INDEX sesion_activas_idx ON sesion (usuario_id) WHERE revocada_en IS NULL;

CREATE FUNCTION sesion_validar() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    u  usuario%ROWTYPE;
    p  politica_acceso%ROWTYPE;
    a  acceso_emergencia%ROWTYPE;
BEGIN
    SELECT * INTO u FROM usuario WHERE id = NEW.usuario_id;
    IF NOT FOUND OR u.activo IS NOT TRUE THEN
        RAISE EXCEPTION 'Usuario dado de baja' USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF u.bloqueado_hasta > now() THEN
        RAISE EXCEPTION 'Usuario bloqueado hasta % por intentos fallidos', u.bloqueado_hasta
            USING ERRCODE = 'insufficient_privilege';
    END IF;

    SELECT * INTO p FROM politica_acceso WHERE rol = u.rol AND nivel = NEW.nivel;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El rol % no puede ingresar con %', u.rol, NEW.nivel USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF NEW.expira_en > NEW.creada_en + p.duracion_max THEN
        RAISE EXCEPTION 'La sesión supera la duración máxima de % para %', p.duracion_max, u.rol
            USING ERRCODE = 'check_violation';
    END IF;

    IF NEW.dispositivo_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM dispositivo WHERE id = NEW.dispositivo_id AND activa) THEN
        RAISE EXCEPTION 'Equipo revocado o desconocido' USING ERRCODE = 'insufficient_privilege';
    END IF;

    IF NEW.nivel = 'CODIGO_EMERGENCIA' THEN          -- un código = una sesión, y no dura más que el código
        SELECT * INTO a FROM acceso_emergencia WHERE id = NEW.acceso_emergencia_id FOR UPDATE;
        IF NOT FOUND OR a.usuario_id IS DISTINCT FROM NEW.usuario_id OR a.revocado_en IS NOT NULL
           OR a.vence_en <= now() OR a.usado_en IS NOT NULL THEN
            RAISE EXCEPTION 'Código de emergencia inválido, vencido o ya usado' USING ERRCODE = 'insufficient_privilege';
        END IF;
        NEW.expira_en := least(NEW.expira_en, a.vence_en);
        UPDATE acceso_emergencia SET usado_en = now() WHERE id = a.id;
    END IF;
    RETURN NEW;
END
$$;
CREATE TRIGGER sesion_validar BEFORE INSERT ON sesion
    FOR EACH ROW EXECUTE FUNCTION sesion_validar();

-- Una sesión sólo puede registrar actividad, reautenticarse o revocarse. No se extiende ni se "resucita".
CREATE FUNCTION sesion_proteger() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.revocada_en IS NOT NULL
       OR (to_jsonb(NEW) - 'ultima_actividad_en' - 'reautenticada_en' - 'revocada_en')
          <> (to_jsonb(OLD) - 'ultima_actividad_en' - 'reautenticada_en' - 'revocada_en') THEN
        RAISE EXCEPTION 'Una sesión no se extiende, no se modifica y no se reactiva'
            USING ERRCODE = 'restrict_violation';
    END IF;
    RETURN NEW;
END
$$;
CREATE TRIGGER sesion_proteger BEFORE UPDATE ON sesion
    FOR EACH ROW EXECUTE FUNCTION sesion_proteger();
CREATE TRIGGER sesion_sin_borrado BEFORE DELETE ON sesion
    FOR EACH ROW EXECUTE FUNCTION prohibir_cambios();

CREATE FUNCTION sesion_registrar() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO evento_seguridad (tipo, usuario_id, sesion_id, dispositivo_id, ip, detalle)
        VALUES ('SESION_INICIADA', NEW.usuario_id, NEW.id, NEW.dispositivo_id, NEW.ip,
                jsonb_build_object('nivel', NEW.nivel, 'acceso_emergencia_id', NEW.acceso_emergencia_id));
    ELSIF OLD.revocada_en IS NULL AND NEW.revocada_en IS NOT NULL THEN
        INSERT INTO evento_seguridad (tipo, usuario_id, sesion_id, dispositivo_id)
        VALUES ('SESION_REVOCADA', NEW.usuario_id, NEW.id, NEW.dispositivo_id);
    END IF;
    RETURN NULL;
END
$$;
CREATE TRIGGER sesion_registrar AFTER INSERT OR UPDATE ON sesion
    FOR EACH ROW EXECUTE FUNCTION sesion_registrar();

-- Baja, cambio de rol o de credenciales => se registra y se cortan TODAS sus sesiones al instante.
CREATE FUNCTION usuario_cambio_sensible() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    motivo text;
BEGIN
    motivo := CASE
        WHEN OLD.activo AND NOT NEW.activo                                   THEN 'USUARIO_DADO_DE_BAJA'
        WHEN NEW.rol <> OLD.rol                                              THEN 'ROL_CAMBIADO'
        WHEN NEW.password_hash IS DISTINCT FROM OLD.password_hash            THEN 'PASSWORD_CAMBIADA'
        WHEN NEW.totp_secreto_cifrado IS DISTINCT FROM OLD.totp_secreto_cifrado THEN 'TOTP_CAMBIADO'
        WHEN NEW.pin_hash IS DISTINCT FROM OLD.pin_hash                      THEN 'PIN_CAMBIADO'
    END;
    IF motivo IS NOT NULL THEN
        INSERT INTO evento_seguridad (tipo, usuario_id, detalle)
        VALUES (motivo, NEW.id, jsonb_build_object('rol_anterior', OLD.rol, 'rol_nuevo', NEW.rol,
                                                   'por', ctx_uuid('app.usuario_id')));
        UPDATE sesion SET revocada_en = now() WHERE usuario_id = NEW.id AND revocada_en IS NULL;
    END IF;
    -- Un bloqueo por intentos fallidos NO corta las sesiones abiertas: si no, un atacante
    -- podría desconectar a cualquiera escribiendo mal su contraseña a propósito.
    IF NEW.bloqueado_hasta > now() AND NEW.bloqueado_hasta IS DISTINCT FROM OLD.bloqueado_hasta THEN
        INSERT INTO evento_seguridad (tipo, usuario_id, detalle)
        VALUES ('USUARIO_BLOQUEADO', NEW.id,
                jsonb_build_object('hasta', NEW.bloqueado_hasta, 'intentos', NEW.intentos_fallidos));
    END IF;
    RETURN NULL;
END
$$;
CREATE TRIGGER usuario_cambio_sensible AFTER UPDATE ON usuario
    FOR EACH ROW EXECUTE FUNCTION usuario_cambio_sensible();

-- Revocar una tablet o celular (pérdida, robo) corta sus sesiones al instante.
CREATE FUNCTION dispositivo_revocado() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.activa AND NOT NEW.activa THEN
        INSERT INTO evento_seguridad (tipo, dispositivo_id, usuario_id)
        VALUES ('EQUIPO_REVOCADO', NEW.id, ctx_uuid('app.usuario_id'));
        UPDATE sesion SET revocada_en = now() WHERE dispositivo_id = NEW.id AND revocada_en IS NULL;
    END IF;
    RETURN NULL;
END
$$;
CREATE TRIGGER dispositivo_revocado AFTER UPDATE ON dispositivo
    FOR EACH ROW EXECUTE FUNCTION dispositivo_revocado();

CREATE TABLE puesto (              -- box / elevador / lugar físico de instalación
    id      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    nombre  text NOT NULL UNIQUE,
    activo  boolean NOT NULL DEFAULT true
);

-- ---------------------------------------------------------------------
-- Clientes y vehículos
-- ---------------------------------------------------------------------
-- Datos personales sensibles CIFRADOS por la API con una clave del KMS antes de guardarlos
-- (cifrado de sobre). La base, sus backups y cualquier copia robada sólo tienen texto cifrado.
-- *_hmac = HMAC-SHA256 con OTRA clave del KMS: permite buscar por igualdad (ej. el teléfono
-- que escribe por WhatsApp) y evitar DNIs duplicados, sin descifrar nada.
-- El formato (DNI, CUIT con dígito verificador, teléfono E.164 como +5491155551234) lo valida la API.
CREATE TABLE cliente (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    nombre            text NOT NULL,               -- nombre y apellido o razón social (en claro: se busca por nombre)
    condicion_iva     text NOT NULL DEFAULT 'CONSUMIDOR_FINAL'
                      CHECK (condicion_iva IN ('CONSUMIDOR_FINAL', 'RESPONSABLE_INSCRIPTO', 'MONOTRIBUTO', 'EXENTO')),
    doc_tipo          text CHECK (doc_tipo IN ('DNI', 'CUIT', 'CUIL', 'PASAPORTE')),
    doc_cifrado       bytea,
    doc_hmac          bytea CHECK (octet_length(doc_hmac) = 32),
    doc_ultimos       text CHECK (doc_ultimos ~ '^[0-9A-Z]{3}$'),  -- para mostrar "•••••456" sin descifrar
    telefono_cifrado  bytea,
    telefono_hmac     bytea CHECK (octet_length(telefono_hmac) = 32),
    email_cifrado     bytea,
    creado_en         timestamptz NOT NULL DEFAULT now(),
    actualizado_en    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT cliente_doc_completo CHECK (
        (doc_tipo IS NULL) = (doc_cifrado IS NULL) AND (doc_cifrado IS NULL) = (doc_hmac IS NULL)),
    CONSTRAINT cliente_telefono_completo CHECK ((telefono_cifrado IS NULL) = (telefono_hmac IS NULL)),
    CONSTRAINT cliente_doc_uq UNIQUE (doc_tipo, doc_hmac)
);
-- Al entrar un WhatsApp se busca el cliente por el HMAC del teléfono (no es único: familia, empresa).
CREATE INDEX cliente_telefono_idx ON cliente (telefono_hmac);

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

-- Historia de titulares: el auto conserva su historia cuando cambia de dueño.
CREATE TABLE vehiculo_titular (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    vehiculo_id  uuid NOT NULL REFERENCES vehiculo (id),
    cliente_id   uuid NOT NULL REFERENCES cliente (id),
    desde        timestamptz NOT NULL DEFAULT now(),
    hasta        timestamptz,
    CONSTRAINT titular_periodo CHECK (hasta IS NULL OR hasta >= desde)
);
CREATE UNIQUE INDEX vehiculo_titular_actual_uq ON vehiculo_titular (vehiculo_id) WHERE hasta IS NULL;

CREATE FUNCTION vehiculo_registrar_titular() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'UPDATE' AND NEW.cliente_id IS NOT DISTINCT FROM OLD.cliente_id THEN
        RETURN NULL;
    END IF;
    UPDATE vehiculo_titular SET hasta = now() WHERE vehiculo_id = NEW.id AND hasta IS NULL;
    IF NEW.cliente_id IS NOT NULL THEN
        INSERT INTO vehiculo_titular (vehiculo_id, cliente_id) VALUES (NEW.id, NEW.cliente_id);
    END IF;
    RETURN NULL;
END
$$;
CREATE TRIGGER vehiculo_registrar_titular AFTER INSERT OR UPDATE OF cliente_id ON vehiculo
    FOR EACH ROW EXECUTE FUNCTION vehiculo_registrar_titular();

-- ---------------------------------------------------------------------
-- Órdenes
-- ---------------------------------------------------------------------
CREATE TABLE catalogo_trabajo (    -- mano de obra: qué se hace y cuánto tarda (alimenta el calendario)
    id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    codigo                text NOT NULL UNIQUE,
    descripcion           text NOT NULL,
    duracion_estimada_min integer NOT NULL CHECK (duracion_estimada_min > 0),
    precio_lista          numeric(14, 2) CHECK (precio_lista >= 0),        -- sin IVA
    alicuota_iva          numeric(4, 2) NOT NULL DEFAULT 21 CHECK (alicuota_iva IN (0, 2.5, 5, 10.5, 21, 27)),
    activo                boolean NOT NULL DEFAULT true
);

-- Cada marca manda su lista de precios (Excel). Siempre hay UNA persona responsable de verificarla.
CREATE TABLE marca (
    id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    nombre                  text NOT NULL UNIQUE,
    responsable_precios_id  uuid NOT NULL REFERENCES usuario (id),
    umbral_variacion_pct    numeric(5, 2) NOT NULL DEFAULT 30 CHECK (umbral_variacion_pct > 0)  -- más que esto: se confirma uno por uno
);

-- Artículos que se instalan (alarma, cámara, film...). Registrar QUÉ artículo usó cada tarea
-- desde el día 1 es lo que después permite el stock inteligente y la historia del auto.
-- precio_lista: para artículos SIN lista de marca. Los de marca toman el precio de su lista vigente.
CREATE TABLE producto (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    sku           text NOT NULL UNIQUE,
    descripcion   text NOT NULL,
    precio_lista  numeric(14, 2) NOT NULL CHECK (precio_lista >= 0),       -- sin IVA
    alicuota_iva  numeric(4, 2) NOT NULL DEFAULT 21 CHECK (alicuota_iva IN (0, 2.5, 5, 10.5, 21, 27)),
    marca_id      uuid REFERENCES marca (id),
    codigo_marca  text,                                                    -- el código que usa la marca en su Excel
    activo        boolean NOT NULL DEFAULT true,
    CONSTRAINT producto_codigo_marca CHECK ((marca_id IS NULL) = (codigo_marca IS NULL)),
    CONSTRAINT producto_codigo_marca_uq UNIQUE (marca_id, codigo_marca)
);

CREATE TYPE estado_lista AS ENUM ('BORRADOR', 'APROBADA', 'RECHAZADA');

-- Una lista de precios tal como la mandó la marca. La carga puede ser automática;
-- la aprobación es SIEMPRE de una persona: el responsable de precios de esa marca.
CREATE TABLE lista_precio (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    marca_id         uuid NOT NULL REFERENCES marca (id),
    vigente_desde    date NOT NULL,
    archivo_nombre   text NOT NULL,                -- el Excel original, guardado tal cual llegó
    archivo_sha256   text NOT NULL CHECK (archivo_sha256 ~ '^[0-9a-f]{64}$'),
    moneda           text NOT NULL DEFAULT 'ARS' CHECK (moneda IN ('ARS', 'USD')),
    precios_con_iva  boolean NOT NULL,
    origen_carga     text NOT NULL CHECK (origen_carga IN ('MANUAL', 'AUTOMATICA')),
    cargada_por      uuid REFERENCES usuario (id), -- NULL si la cargó el importador automático
    cargada_en       timestamptz NOT NULL DEFAULT now(),
    estado           estado_lista NOT NULL DEFAULT 'BORRADOR',
    revisada_por     uuid REFERENCES usuario (id),
    revisada_en      timestamptz,
    observaciones    text,
    CONSTRAINT lista_carga CHECK ((origen_carga = 'MANUAL') = (cargada_por IS NOT NULL)),
    CONSTRAINT lista_revision CHECK ((estado = 'BORRADOR') = (revisada_por IS NULL)
                                     AND (estado = 'BORRADOR') = (revisada_en IS NULL)),
    CONSTRAINT lista_rechazo_con_motivo CHECK (estado <> 'RECHAZADA' OR observaciones IS NOT NULL)
);
CREATE UNIQUE INDEX lista_precio_vigencia_uq ON lista_precio (marca_id, vigente_desde) WHERE estado = 'APROBADA';

CREATE TABLE lista_precio_item (
    id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    lista_id              uuid NOT NULL REFERENCES lista_precio (id),
    codigo_marca          text NOT NULL,
    descripcion           text NOT NULL,
    precio                numeric(14, 2) NOT NULL CHECK (precio > 0),
    alicuota_iva          numeric(4, 2) NOT NULL DEFAULT 21 CHECK (alicuota_iva IN (0, 2.5, 5, 10.5, 21, 27)),
    producto_id           uuid REFERENCES producto (id),   -- NULL = código nuevo: se crea al aprobar
    precio_anterior       numeric(14, 2),                  -- lo calcula la base desde la lista anterior
    variacion_pct         numeric(9, 2) GENERATED ALWAYS AS (
                              CASE WHEN precio_anterior > 0
                                   THEN round((precio - precio_anterior) / precio_anterior * 100, 2) END) STORED,
    variacion_confirmada  boolean NOT NULL DEFAULT false,  -- el responsable miró esta variación grande
    CONSTRAINT lista_item_codigo_uq UNIQUE (lista_id, codigo_marca)
);

CREATE FUNCTION lista_item_preparar() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_marca     uuid;
    v_estado    estado_lista;
    v_desde     date;
    v_anterior  numeric;
    v_producto  uuid;
BEGIN
    IF TG_OP = 'DELETE' THEN
        SELECT estado INTO v_estado FROM lista_precio WHERE id = OLD.lista_id;
        IF v_estado <> 'BORRADOR' THEN
            RAISE EXCEPTION 'Una lista revisada no se modifica' USING ERRCODE = 'restrict_violation';
        END IF;
        RETURN OLD;
    END IF;
    SELECT marca_id, estado, vigente_desde INTO v_marca, v_estado, v_desde FROM lista_precio WHERE id = NEW.lista_id;
    IF v_estado <> 'BORRADOR' THEN
        RAISE EXCEPTION 'Una lista revisada no se modifica: si hay un error, se carga una lista nueva'
            USING ERRCODE = 'restrict_violation';
    END IF;
    NEW.codigo_marca := upper(trim(NEW.codigo_marca));
    -- El precio anterior lo calcula la base: el importador no puede maquillar la variación.
    SELECT i.precio INTO v_anterior
      FROM lista_precio_item i JOIN lista_precio l ON l.id = i.lista_id
     WHERE l.marca_id = v_marca AND l.estado = 'APROBADA' AND l.vigente_desde < v_desde
       AND i.codigo_marca = NEW.codigo_marca
     ORDER BY l.vigente_desde DESC LIMIT 1;
    NEW.precio_anterior := v_anterior;
    SELECT id INTO v_producto FROM producto WHERE marca_id = v_marca AND codigo_marca = NEW.codigo_marca;
    NEW.producto_id := v_producto;
    RETURN NEW;
END
$$;
CREATE TRIGGER lista_item_preparar BEFORE INSERT OR UPDATE OR DELETE ON lista_precio_item
    FOR EACH ROW EXECUTE FUNCTION lista_item_preparar();

CREATE FUNCTION lista_precio_revisar() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    m       marca%ROWTYPE;
    v_n     integer;
    v_pend  integer;
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF OLD.estado <> 'BORRADOR' THEN
            RAISE EXCEPTION 'Una lista revisada no se borra' USING ERRCODE = 'restrict_violation';
        END IF;
        RETURN OLD;
    END IF;
    IF OLD.estado <> 'BORRADOR' THEN
        RAISE EXCEPTION 'Una lista revisada no se modifica: si hay un error, se carga una lista nueva'
            USING ERRCODE = 'restrict_violation';
    END IF;
    IF NEW.estado = 'BORRADOR' THEN
        RETURN NEW;
    END IF;

    SELECT * INTO m FROM marca WHERE id = NEW.marca_id;
    IF NEW.revisada_por IS DISTINCT FROM m.responsable_precios_id
       OR NOT EXISTS (SELECT 1 FROM usuario WHERE id = NEW.revisada_por AND activo) THEN
        RAISE EXCEPTION 'Sólo el responsable de precios de % puede aprobar o rechazar su lista', m.nombre
            USING ERRCODE = 'insufficient_privilege';
    END IF;
    NEW.revisada_en := now();

    IF NEW.estado = 'APROBADA' THEN
        SELECT count(*), count(*) FILTER (WHERE abs(variacion_pct) > m.umbral_variacion_pct AND NOT variacion_confirmada)
          INTO v_n, v_pend
          FROM lista_precio_item WHERE lista_id = NEW.id;
        IF v_n = 0 THEN
            RAISE EXCEPTION 'La lista no tiene precios' USING ERRCODE = 'check_violation';
        END IF;
        IF v_pend > 0 THEN
            RAISE EXCEPTION '% precio(s) cambian más de % %% y el responsable no los confirmó uno por uno',
                v_pend, m.umbral_variacion_pct USING ERRCODE = 'check_violation';
        END IF;
        -- Códigos nuevos de la marca: se dan de alta en el catálogo al aprobar.
        INSERT INTO producto (sku, descripcion, precio_lista, alicuota_iva, marca_id, codigo_marca)
        SELECT upper(left(m.nombre, 3)) || '-' || i.codigo_marca, i.descripcion,
               CASE WHEN NEW.precios_con_iva THEN round(i.precio / (1 + i.alicuota_iva / 100), 2) ELSE i.precio END,
               i.alicuota_iva, m.id, i.codigo_marca
          FROM lista_precio_item i
         WHERE i.lista_id = NEW.id AND i.producto_id IS NULL;
        UPDATE lista_precio_item SET producto_id = NULL WHERE lista_id = NEW.id AND producto_id IS NULL;  -- re-vincula
    END IF;
    RETURN NEW;
END
$$;
CREATE TRIGGER lista_precio_revisar BEFORE UPDATE OR DELETE ON lista_precio
    FOR EACH ROW EXECUTE FUNCTION lista_precio_revisar();

-- Cambiar al responsable de precios de una marca queda en el registro de seguridad.
CREATE FUNCTION marca_cambio_responsable() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.responsable_precios_id IS DISTINCT FROM OLD.responsable_precios_id THEN
        INSERT INTO evento_seguridad (tipo, usuario_id, detalle)
        VALUES ('RESPONSABLE_PRECIOS_CAMBIADO', ctx_uuid('app.usuario_id'),
                jsonb_build_object('marca', NEW.nombre, 'anterior', OLD.responsable_precios_id,
                                   'nuevo', NEW.responsable_precios_id));
    END IF;
    RETURN NULL;
END
$$;
CREATE TRIGGER marca_cambio_responsable AFTER UPDATE ON marca
    FOR EACH ROW EXECUTE FUNCTION marca_cambio_responsable();

CREATE SEQUENCE orden_numero_seq START 1000;

CREATE TABLE orden (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    numero          bigint NOT NULL UNIQUE DEFAULT nextval('orden_numero_seq'),  -- visible: "OT-1000"
    estado          estado_orden NOT NULL DEFAULT 'BORRADOR',
    cliente_id      uuid REFERENCES cliente (id),
    vehiculo_id     uuid REFERENCES vehiculo (id),
    km_ingreso      integer CHECK (km_ingreso BETWEEN 0 AND 2000000),  -- se anota en la recepción
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

CREATE TYPE estado_tarea AS ENUM ('PENDIENTE', 'HECHO', 'CANCELADO');
CREATE TYPE origen_tarea AS ENUM ('ORIGINAL', 'HALLAZGO', 'PEDIDO_CLIENTE');

-- La TAREA: unidad de ejecución (qué se hace, quién, cuándo, qué consume, cuánto cuesta).
-- La ORDEN es la visita que las agrupa (cliente, vehículo, turno, entrega, factura).
CREATE TABLE orden_item (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    orden_id       uuid NOT NULL REFERENCES orden (id),
    trabajo_id     uuid REFERENCES catalogo_trabajo (id),
    producto_id    uuid REFERENCES producto (id),
    descripcion    text NOT NULL,
    cantidad       numeric(10, 2) NOT NULL DEFAULT 1 CHECK (cantidad > 0),
    precio_unitario numeric(14, 2) CHECK (precio_unitario >= 0),     -- sin IVA; se propone desde el catálogo
    alicuota_iva   numeric(4, 2) NOT NULL DEFAULT 21 CHECK (alicuota_iva IN (0, 2.5, 5, 10.5, 21, 27)),
    lista_precio_item_id uuid REFERENCES lista_precio_item (id),     -- de qué lista salió el precio
    observaciones  text,
    estado         estado_tarea NOT NULL DEFAULT 'PENDIENTE',
    origen         origen_tarea NOT NULL DEFAULT 'ORIGINAL',
    hallazgo_id    uuid,                                             -- FK más abajo (tabla hallazgo)
    motivo         text,                                             -- por qué se agregó (en curso) o se canceló
    agregado_por   uuid REFERENCES usuario (id),
    agregado_en    timestamptz,
    aprobacion_cliente_en     timestamptz,                           -- "consentimiento" para trabajos adicionales
    aprobacion_cliente_canal  text CHECK (aprobacion_cliente_canal IN ('WHATSAPP', 'PRESENCIAL', 'TELEFONO', 'EMAIL')),
    aprobacion_cliente_ref    text,                                  -- ej. id del mensaje de WhatsApp
    hecho_en       timestamptz,    -- lo marca el operario desde la tablet
    hecho_por      uuid REFERENCES usuario (id),
    cancelado_por  uuid REFERENCES usuario (id),
    cancelado_en   timestamptz,
    CONSTRAINT item_hecho_completo CHECK ((estado = 'HECHO') = (hecho_en IS NOT NULL)
                                          AND (hecho_en IS NULL) = (hecho_por IS NULL)),
    CONSTRAINT item_cancelado_con_motivo CHECK (estado <> 'CANCELADO' OR motivo IS NOT NULL),
    CONSTRAINT item_origen_hallazgo CHECK ((origen = 'HALLAZGO') = (hallazgo_id IS NOT NULL)),
    CONSTRAINT item_aprobacion_completa CHECK ((aprobacion_cliente_en IS NULL) = (aprobacion_cliente_canal IS NULL))
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
    id                  uuid PRIMARY KEY,          -- lo genera la tablet de firma (o el back-office si es papel)
    orden_id            uuid NOT NULL UNIQUE REFERENCES orden (id),
    medio               medio_firma NOT NULL DEFAULT 'DIGITAL',
    -- JSON canónico EXACTO que se le mostró al cliente y que la tablet hasheó:
    -- cliente, vehículo, trabajos, fotos (por hash), texto de conformidad, versión del texto legal.
    -- En papel: los datos transcriptos del acta (los hashea el servidor).
    contenido_canonico  text NOT NULL,
    contenido_sha256    text NOT NULL,
    firmante_nombre     text NOT NULL,
    -- En claro dentro del acta a propósito: el hash se verifica sobre el contenido exacto que se firmó.
    -- Se compensa con acceso restringido (sólo ADMIN/ENTREGA) y registro de cada lectura (SEGURIDAD.md).
    firmante_doc        text NOT NULL,
    conformidad         text NOT NULL CHECK (conformidad IN ('CONFORME', 'CON_OBSERVACIONES')),
    observaciones       text,
    firma_trazos_id     uuid REFERENCES adjunto (id),  -- DIGITAL: trazos x,y,t,presión (no sólo una imagen)
    papel_escaneado_id  uuid REFERENCES adjunto (id),  -- PAPEL: foto/escaneo del acta firmada (obligatorio)
    numero_papel        text UNIQUE,                   -- PAPEL: número de talonario, ej. "A-0007"
    pdf_id              uuid REFERENCES adjunto (id),  -- lo genera el servidor después
    entregado_por       uuid NOT NULL REFERENCES usuario (id),
    dispositivo_id      uuid REFERENCES dispositivo (id),  -- DIGITAL: tablet o celular de la empresa
    firmado_en          timestamptz NOT NULL,      -- reloj de la tablet, o la hora anotada en el papel
    recibido_en         timestamptz NOT NULL DEFAULT now(),  -- reloj del servidor
    CONSTRAINT acta_evidencia CHECK (
        (medio = 'DIGITAL' AND firma_trazos_id IS NOT NULL AND dispositivo_id IS NOT NULL
                           AND papel_escaneado_id IS NULL AND numero_papel IS NULL)
     OR (medio = 'PAPEL'   AND papel_escaneado_id IS NOT NULL AND numero_papel IS NOT NULL
                           AND firma_trazos_id IS NULL)),
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
-- Facturación (etapa 1: manual asistida · etapa 2: automática con ARCA)
-- ---------------------------------------------------------------------
-- Etapa 1: el sistema arma el BORRADOR desde la orden; Administración lo emite en ARCA y carga
-- punto de venta, número, CAE y PDF. Etapa 2: lo mismo, pero lo completa el servicio de ARCA (modo AUTOMATICA).
-- Se usa un PUNTO DE VENTA EXCLUSIVO para este sistema: así la base puede exigir numeración correlativa
-- y detectar un número mal tipeado.
CREATE TABLE comprobante (
    id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    orden_id                 uuid NOT NULL REFERENCES orden (id),
    cliente_id               uuid NOT NULL REFERENCES cliente (id),
    tipo                     tipo_comprobante NOT NULL,
    estado                   estado_comprobante NOT NULL DEFAULT 'BORRADOR',
    modo                     text NOT NULL DEFAULT 'MANUAL_ASISTIDA' CHECK (modo IN ('MANUAL_ASISTIDA', 'AUTOMATICA')),
    receptor_nombre          text NOT NULL,          -- copia al momento de facturar
    receptor_condicion_iva   text NOT NULL,
    neto                     numeric(14, 2) NOT NULL CHECK (neto >= 0),
    iva                      numeric(14, 2) NOT NULL CHECK (iva >= 0),
    total                    numeric(14, 2) NOT NULL,
    comprobante_asociado_id  uuid REFERENCES comprobante (id),   -- nota de crédito -> factura que corrige
    punto_venta              integer CHECK (punto_venta BETWEEN 1 AND 99999),
    numero                   bigint CHECK (numero BETWEEN 1 AND 99999999),
    cae                      text CHECK (cae ~ '^[0-9]{14}$'),
    cae_vence                date,
    fecha_emision            date,
    pdf_id                   uuid REFERENCES adjunto (id),
    emitido_por              uuid REFERENCES usuario (id),
    creado_en                timestamptz NOT NULL DEFAULT now(),
    emitido_en               timestamptz,
    CONSTRAINT comprobante_total CHECK (total = neto + iva),
    CONSTRAINT comprobante_numero_uq UNIQUE (tipo, punto_venta, numero),
    CONSTRAINT comprobante_datos_emision CHECK (estado = 'BORRADOR' OR (
        punto_venta IS NOT NULL AND numero IS NOT NULL AND cae IS NOT NULL AND cae_vence IS NOT NULL
        AND fecha_emision IS NOT NULL AND emitido_por IS NOT NULL AND emitido_en IS NOT NULL
        AND cae_vence >= fecha_emision)),
    CONSTRAINT comprobante_nota_credito CHECK (
        (tipo::text LIKE 'NOTA_CREDITO_%') = (comprobante_asociado_id IS NOT NULL))
);
CREATE INDEX comprobante_orden_idx ON comprobante (orden_id);

CREATE TABLE comprobante_item (     -- copia de los ítems al facturar (la factura no cambia si cambia la orden)
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    comprobante_id   uuid NOT NULL REFERENCES comprobante (id),
    descripcion      text NOT NULL,
    cantidad         numeric(10, 2) NOT NULL CHECK (cantidad > 0),
    precio_unitario  numeric(14, 2) NOT NULL CHECK (precio_unitario >= 0),   -- sin IVA
    alicuota_iva     numeric(4, 2) NOT NULL CHECK (alicuota_iva IN (0, 2.5, 5, 10.5, 21, 27))
);
CREATE INDEX comprobante_item_comprobante_idx ON comprobante_item (comprobante_id);

CREATE FUNCTION comprobante_validar() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_neto      numeric;
    v_iva       numeric;
    v_ultimo    bigint;
    v_acreditado numeric;
    f           comprobante%ROWTYPE;
BEGIN
    IF TG_OP = 'INSERT' AND NEW.estado <> 'BORRADOR' THEN
        RAISE EXCEPTION 'Un comprobante nace como BORRADOR (primero se cargan los ítems)'
            USING ERRCODE = 'check_violation';
    END IF;

    IF TG_OP = 'UPDATE' AND OLD.estado <> 'BORRADOR' THEN
        -- Ya emitido: sólo se puede adjuntar el PDF una vez, o quedar ANULADO por notas de crédito.
        IF (to_jsonb(NEW) - 'estado' - 'pdf_id') <> (to_jsonb(OLD) - 'estado' - 'pdf_id')
           OR (OLD.pdf_id IS NOT NULL AND NEW.pdf_id IS DISTINCT FROM OLD.pdf_id)
           OR (NEW.estado <> OLD.estado AND NOT (
                   OLD.estado = 'EMITIDO' AND NEW.estado = 'ANULADO'
                   AND (SELECT COALESCE(sum(total), 0) FROM comprobante
                         WHERE comprobante_asociado_id = NEW.id AND estado = 'EMITIDO') = NEW.total)) THEN
            RAISE EXCEPTION '% N° % ya emitido: no se modifica, se corrige con nota de crédito', NEW.tipo, NEW.numero
                USING ERRCODE = 'restrict_violation';
        END IF;
        RETURN NEW;
    END IF;

    IF NEW.estado = 'ANULADO' THEN
        RAISE EXCEPTION 'Sólo un comprobante emitido se puede anular' USING ERRCODE = 'check_violation';
    END IF;

    IF NEW.estado = 'EMITIDO' THEN                     -- emisión: BORRADOR -> EMITIDO
        IF NOT EXISTS (SELECT 1 FROM usuario
                        WHERE id = NEW.emitido_por AND rol IN ('ADMIN', 'ADMINISTRACION') AND activo) THEN
            RAISE EXCEPTION 'Sólo Administración puede emitir comprobantes' USING ERRCODE = 'insufficient_privilege';
        END IF;

        SELECT sum(round(cantidad * precio_unitario, 2)),
               sum(round(cantidad * precio_unitario * alicuota_iva / 100, 2))
          INTO v_neto, v_iva
          FROM comprobante_item WHERE comprobante_id = NEW.id;
        IF v_neto IS NULL THEN
            RAISE EXCEPTION 'El comprobante no tiene ítems' USING ERRCODE = 'check_violation';
        END IF;
        IF v_neto <> NEW.neto OR v_iva <> NEW.iva THEN
            RAISE EXCEPTION 'Los totales no coinciden con los ítems (neto %, IVA %)', v_neto, v_iva
                USING ERRCODE = 'check_violation';
        END IF;

        SELECT max(numero) INTO v_ultimo FROM comprobante
         WHERE tipo = NEW.tipo AND punto_venta = NEW.punto_venta AND estado <> 'BORRADOR';
        IF v_ultimo IS NOT NULL AND NEW.numero <> v_ultimo + 1 THEN
            RAISE EXCEPTION 'Numeración no correlativa en % PV %: el último es %, corresponde %',
                NEW.tipo, NEW.punto_venta, v_ultimo, v_ultimo + 1 USING ERRCODE = 'check_violation';
        END IF;

        IF NEW.comprobante_asociado_id IS NOT NULL THEN  -- nota de crédito
            SELECT * INTO f FROM comprobante WHERE id = NEW.comprobante_asociado_id;
            SELECT COALESCE(sum(total), 0) INTO v_acreditado FROM comprobante
             WHERE comprobante_asociado_id = f.id AND estado = 'EMITIDO';
            -- IS DISTINCT FROM / IS NOT TRUE: un NULL nunca debe "aprobar" un control
            IF f.id IS NULL OR f.estado IS DISTINCT FROM 'EMITIDO' OR f.tipo::text LIKE 'NOTA_CREDITO_%'
               OR right(f.tipo::text, 1) IS DISTINCT FROM right(NEW.tipo::text, 1)
               OR (v_acreditado + NEW.total <= f.total) IS NOT TRUE THEN
                RAISE EXCEPTION 'La nota de crédito tiene que corregir una factura emitida de la misma letra, sin superar su total'
                    USING ERRCODE = 'check_violation';
            END IF;
        END IF;

        NEW.emitido_en := now();
    END IF;
    RETURN NEW;
END
$$;
CREATE TRIGGER comprobante_validar BEFORE INSERT OR UPDATE ON comprobante
    FOR EACH ROW EXECUTE FUNCTION comprobante_validar();

CREATE FUNCTION comprobante_no_borrar_emitido() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.estado <> 'BORRADOR' THEN
        RAISE EXCEPTION 'Un comprobante emitido no se borra' USING ERRCODE = 'restrict_violation';
    END IF;
    RETURN OLD;
END
$$;
CREATE TRIGGER comprobante_no_borrar_emitido BEFORE DELETE ON comprobante
    FOR EACH ROW EXECUTE FUNCTION comprobante_no_borrar_emitido();

-- Nota de crédito emitida que completa el total de la factura => la factura queda ANULADA.
CREATE FUNCTION comprobante_aplicar_nota_credito() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.estado = 'BORRADOR' AND NEW.estado = 'EMITIDO' AND NEW.comprobante_asociado_id IS NOT NULL THEN
        UPDATE comprobante f SET estado = 'ANULADO'
         WHERE f.id = NEW.comprobante_asociado_id AND f.estado = 'EMITIDO'
           AND f.total = (SELECT sum(total) FROM comprobante
                           WHERE comprobante_asociado_id = f.id AND estado = 'EMITIDO');
    END IF;
    RETURN NULL;
END
$$;
CREATE TRIGGER comprobante_aplicar_nota_credito AFTER UPDATE ON comprobante
    FOR EACH ROW EXECUTE FUNCTION comprobante_aplicar_nota_credito();

-- Los ítems de un comprobante emitido no se tocan.
CREATE FUNCTION comprobante_item_proteger() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF (TG_OP <> 'INSERT' AND EXISTS (SELECT 1 FROM comprobante WHERE id = OLD.comprobante_id AND estado <> 'BORRADOR'))
       OR (TG_OP <> 'DELETE' AND EXISTS (SELECT 1 FROM comprobante WHERE id = NEW.comprobante_id AND estado <> 'BORRADOR')) THEN
        RAISE EXCEPTION 'Los ítems de un comprobante emitido no se modifican' USING ERRCODE = 'restrict_violation';
    END IF;
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END
$$;
CREATE TRIGGER comprobante_item_proteger BEFORE INSERT OR UPDATE OR DELETE ON comprobante_item
    FOR EACH ROW EXECUTE FUNCTION comprobante_item_proteger();

-- ---------------------------------------------------------------------
-- Agentes de IA (ver AGENTES.md): los agentes PROPONEN, las personas APRUEBAN
-- ---------------------------------------------------------------------
-- Ningún agente escribe en tablas de negocio. Escribe una propuesta; al aprobarla, la API
-- ejecuta lo propuesto EN NOMBRE DE LA PERSONA que aprobó, así que rigen todas las reglas de arriba.
CREATE TYPE estado_propuesta AS ENUM ('PENDIENTE', 'APROBADA', 'RECHAZADA', 'VENCIDA');

-- Qué puede proponer un agente y cuánto dura la propuesta (después, los datos ya cambiaron).
CREATE TABLE tipo_propuesta (
    tipo         text PRIMARY KEY,
    descripcion  text NOT NULL,
    vigencia     interval NOT NULL
);
-- Qué roles pueden revisar (aprobar o rechazar) cada tipo. Es la política, escrita como datos.
CREATE TABLE propuesta_aprobador (
    tipo  text NOT NULL REFERENCES tipo_propuesta (tipo),
    rol   rol_usuario NOT NULL,
    PRIMARY KEY (tipo, rol)
);
INSERT INTO tipo_propuesta (tipo, descripcion, vigencia) VALUES
    ('ORDEN_COMPRA',       'Compra sugerida a un proveedor',                           '3 days'),
    ('AJUSTE_STOCK',       'Corrección de stock por una diferencia detectada',         '2 days'),
    ('INGRESO_MERCADERIA', 'Ingreso de mercadería leído de un remito o factura',       '2 days'),
    ('BORRADOR_ORDEN',     'Orden armada a partir de un mensaje de WhatsApp',          '1 day'),
    ('RESPUESTA_CLIENTE',  'Respuesta sugerida a un cliente por WhatsApp',             '4 hours'),
    ('REPROGRAMACION',     'Cambio de turnos propuesto en el calendario',              '1 day');
INSERT INTO propuesta_aprobador (tipo, rol) VALUES
    ('ORDEN_COMPRA', 'ADMINISTRACION'),       ('ORDEN_COMPRA', 'ADMIN'),
    ('AJUSTE_STOCK', 'ADMINISTRACION'),       ('AJUSTE_STOCK', 'ADMIN'),
    ('INGRESO_MERCADERIA', 'ADMINISTRACION'), ('INGRESO_MERCADERIA', 'COORDINADOR'),
    ('BORRADOR_ORDEN', 'VENDEDOR'),           ('BORRADOR_ORDEN', 'COORDINADOR'),
    ('RESPUESTA_CLIENTE', 'VENDEDOR'),        ('RESPUESTA_CLIENTE', 'COORDINADOR'), ('RESPUESTA_CLIENTE', 'ENTREGA'),
    ('REPROGRAMACION', 'COORDINADOR');

CREATE TABLE propuesta_agente (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    agente          text NOT NULL,              -- 'reposicion', 'recepcion-whatsapp', 'agenda'...
    modelo          text NOT NULL,              -- modelo de IA que la generó (auditoría)
    tipo            text NOT NULL REFERENCES tipo_propuesta (tipo),
    orden_id        uuid REFERENCES orden (id),
    payload         jsonb NOT NULL,             -- lo que se propone hacer, exacto
    justificacion   text NOT NULL,              -- por qué, en lenguaje simple
    datos_usados    jsonb NOT NULL,             -- evidencia: lo que devolvieron las herramientas consultadas
    estado          estado_propuesta NOT NULL DEFAULT 'PENDIENTE',
    creada_en       timestamptz NOT NULL DEFAULT now(),
    vence_en        timestamptz NOT NULL,       -- lo calcula la base según el tipo
    revisada_por    uuid REFERENCES usuario (id),
    revisada_en     timestamptz,
    motivo_rechazo  text,
    CONSTRAINT propuesta_revision CHECK (
        (estado IN ('PENDIENTE', 'VENCIDA') AND revisada_por IS NULL AND revisada_en IS NULL)
     OR (estado IN ('APROBADA', 'RECHAZADA') AND revisada_por IS NOT NULL AND revisada_en IS NOT NULL)),
    CONSTRAINT propuesta_rechazo_con_motivo CHECK (estado <> 'RECHAZADA' OR motivo_rechazo IS NOT NULL)
);
CREATE INDEX propuesta_pendientes_idx ON propuesta_agente (tipo, creada_en) WHERE estado = 'PENDIENTE';

CREATE FUNCTION propuesta_validar() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.estado <> 'PENDIENTE' THEN
            RAISE EXCEPTION 'Una propuesta nace PENDIENTE: un agente no puede aprobarse a sí mismo'
                USING ERRCODE = 'check_violation';
        END IF;
        NEW.creada_en := now();                     -- un agente no puede antedatar ni alargar su propuesta
        NEW.vence_en  := now() + (SELECT vigencia FROM tipo_propuesta WHERE tipo = NEW.tipo);
        RETURN NEW;
    END IF;

    -- Sólo una propuesta pendiente cambia, y sólo su estado y los datos de la revisión.
    IF OLD.estado <> 'PENDIENTE'
       OR (to_jsonb(NEW) - 'estado' - 'revisada_por' - 'revisada_en' - 'motivo_rechazo')
          <> (to_jsonb(OLD) - 'estado' - 'revisada_por' - 'revisada_en' - 'motivo_rechazo') THEN
        RAISE EXCEPTION 'Lo propuesto no se edita y una propuesta revisada no cambia: se rechaza y se propone de nuevo'
            USING ERRCODE = 'restrict_violation';
    END IF;

    IF NEW.estado = 'VENCIDA' AND OLD.vence_en > now() THEN
        RAISE EXCEPTION 'La propuesta todavía no venció' USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.estado IN ('APROBADA', 'RECHAZADA') THEN
        IF NOT EXISTS (SELECT 1 FROM usuario u
                         JOIN propuesta_aprobador a ON a.rol = u.rol AND a.tipo = NEW.tipo
                        WHERE u.id = NEW.revisada_por AND u.activo) THEN
            RAISE EXCEPTION 'Ese usuario no puede revisar propuestas de tipo %', NEW.tipo
                USING ERRCODE = 'insufficient_privilege';
        END IF;
    END IF;
    IF NEW.estado = 'APROBADA' AND OLD.vence_en <= now() THEN
        RAISE EXCEPTION 'La propuesta venció: los datos en que se basó pueden haber cambiado'
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END
$$;
CREATE TRIGGER propuesta_validar BEFORE INSERT OR UPDATE ON propuesta_agente
    FOR EACH ROW EXECUTE FUNCTION propuesta_validar();
CREATE TRIGGER propuesta_sin_borrado BEFORE DELETE ON propuesta_agente
    FOR EACH ROW EXECUTE FUNCTION prohibir_cambios();

-- ---------------------------------------------------------------------
-- Historia clínica del vehículo (ver PROCESO.md)
-- ---------------------------------------------------------------------
CREATE TYPE estado_hallazgo AS ENUM ('ABIERTO', 'PRESUPUESTADO', 'RECHAZADO_POR_CLIENTE', 'RESUELTO', 'DESCARTADO');

-- Lo que se encuentra en el auto: daños previos al recibirlo, fallas, recomendaciones.
-- Queda en la historia del auto aunque el cliente no quiera arreglarlo ("se le informó").
CREATE TABLE hallazgo (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    vehiculo_id     uuid NOT NULL REFERENCES vehiculo (id),
    orden_id        uuid REFERENCES orden (id),          -- en qué visita se encontró
    tipo            text NOT NULL CHECK (tipo IN ('DANO_PREVIO', 'FALLA', 'RECOMENDACION', 'OBSERVACION')),
    severidad       text NOT NULL CHECK (severidad IN ('INFO', 'ATENCION', 'URGENTE')),
    descripcion     text NOT NULL,
    foto_id         uuid REFERENCES adjunto (id),
    registrado_por  uuid NOT NULL REFERENCES usuario (id),
    dispositivo_id  uuid REFERENCES dispositivo (id),
    registrado_en   timestamptz NOT NULL DEFAULT now(),
    estado          estado_hallazgo NOT NULL DEFAULT 'ABIERTO',
    resolucion      text,
    CONSTRAINT hallazgo_cierre_con_motivo CHECK (
        estado NOT IN ('RECHAZADO_POR_CLIENTE', 'RESUELTO', 'DESCARTADO') OR resolucion IS NOT NULL)
);
CREATE INDEX hallazgo_vehiculo_idx ON hallazgo (vehiculo_id, registrado_en);

CREATE FUNCTION hallazgo_proteger() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.estado IN ('RESUELTO', 'DESCARTADO')
       OR (to_jsonb(NEW) - ARRAY['estado', 'resolucion']) <> (to_jsonb(OLD) - ARRAY['estado', 'resolucion']) THEN
        RAISE EXCEPTION 'Lo que se encontró en el auto no se reescribe: sólo cambia su estado'
            USING ERRCODE = 'restrict_violation';
    END IF;
    RETURN NEW;
END
$$;
CREATE TRIGGER hallazgo_proteger BEFORE UPDATE ON hallazgo
    FOR EACH ROW EXECUTE FUNCTION hallazgo_proteger();
CREATE TRIGGER hallazgo_sin_borrado BEFORE DELETE ON hallazgo
    FOR EACH ROW EXECUTE FUNCTION prohibir_cambios();

ALTER TABLE orden_item ADD CONSTRAINT orden_item_hallazgo_fk FOREIGN KEY (hallazgo_id) REFERENCES hallazgo (id);

-- Lo que quedó instalado en el auto, con número de serie y garantía ("los implantes").
CREATE TABLE componente_instalado (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    vehiculo_id      uuid NOT NULL REFERENCES vehiculo (id),
    producto_id      uuid NOT NULL REFERENCES producto (id),
    orden_item_id    uuid NOT NULL REFERENCES orden_item (id),
    numero_serie     text,
    instalado_en     timestamptz NOT NULL DEFAULT now(),
    garantia_hasta   date,
    retirado_en      timestamptz,
    retirado_motivo  text,
    reemplazado_por  uuid REFERENCES componente_instalado (id),
    CONSTRAINT componente_retiro CHECK ((retirado_en IS NULL) = (retirado_motivo IS NULL))
);
-- Un mismo número de serie no puede estar instalado en dos autos a la vez.
CREATE UNIQUE INDEX componente_serie_uq ON componente_instalado (producto_id, numero_serie)
    WHERE numero_serie IS NOT NULL AND retirado_en IS NULL;
CREATE INDEX componente_vehiculo_idx ON componente_instalado (vehiculo_id);

CREATE FUNCTION componente_validar() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'UPDATE' THEN       -- sólo se registra el retiro o el reemplazo, una vez
        IF OLD.retirado_en IS NOT NULL
           OR (to_jsonb(NEW) - ARRAY['retirado_en', 'retirado_motivo', 'reemplazado_por'])
              <> (to_jsonb(OLD) - ARRAY['retirado_en', 'retirado_motivo', 'reemplazado_por']) THEN
            RAISE EXCEPTION 'Un componente instalado sólo se puede dar de baja (retiro o reemplazo)'
                USING ERRCODE = 'restrict_violation';
        END IF;
        RETURN NEW;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM orden_item i JOIN orden o ON o.id = i.orden_id
                    WHERE i.id = NEW.orden_item_id AND o.vehiculo_id = NEW.vehiculo_id AND i.estado = 'HECHO') THEN
        RAISE EXCEPTION 'El componente tiene que venir de una tarea hecha en ese mismo vehículo'
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END
$$;
CREATE TRIGGER componente_validar BEFORE INSERT OR UPDATE ON componente_instalado
    FOR EACH ROW EXECUTE FUNCTION componente_validar();
CREATE TRIGGER componente_sin_borrado BEFORE DELETE ON componente_instalado
    FOR EACH ROW EXECUTE FUNCTION prohibir_cambios();

-- ---------------------------------------------------------------------
-- Tareas: cambios en la marcha con trazabilidad
-- ---------------------------------------------------------------------
CREATE FUNCTION orden_item_validar() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_estado estado_orden;
    v_libres text[] := ARRAY['estado', 'hecho_en', 'hecho_por', 'observaciones', 'motivo', 'cancelado_por',
                             'cancelado_en', 'aprobacion_cliente_en', 'aprobacion_cliente_canal', 'aprobacion_cliente_ref'];
BEGIN
    IF TG_OP = 'DELETE' THEN
        SELECT estado INTO v_estado FROM orden WHERE id = OLD.orden_id;
        IF v_estado <> 'BORRADOR' THEN
            RAISE EXCEPTION 'Una tarea de una orden confirmada no se borra: se cancela con motivo'
                USING ERRCODE = 'restrict_violation';
        END IF;
        RETURN OLD;
    END IF;

    SELECT estado INTO v_estado FROM orden WHERE id = NEW.orden_id;

    IF TG_OP = 'INSERT' THEN
        IF v_estado IN ('TERMINADA', 'ENTREGADA', 'CANCELADA') THEN
            RAISE EXCEPTION 'La orden está %: no se agregan tareas (si hace falta, se reabre)', v_estado
                USING ERRCODE = 'check_violation';
        END IF;
        IF NEW.estado <> 'PENDIENTE' THEN
            RAISE EXCEPTION 'Una tarea nace pendiente' USING ERRCODE = 'check_violation';
        END IF;
        IF v_estado <> 'BORRADOR' AND (NEW.origen = 'ORIGINAL' OR NEW.motivo IS NULL) THEN
            RAISE EXCEPTION 'Con la orden confirmada, una tarea nueva indica de dónde sale (hallazgo o pedido del cliente) y por qué'
                USING ERRCODE = 'check_violation';
        END IF;
        NEW.agregado_por := COALESCE(NEW.agregado_por, ctx_uuid('app.usuario_id'));
        NEW.agregado_en  := hora_del_evento();
        RETURN NEW;
    END IF;

    -- UPDATE
    IF v_estado IN ('ENTREGADA', 'CANCELADA') THEN
        RAISE EXCEPTION 'La orden está %: sus tareas ya no se modifican', v_estado USING ERRCODE = 'restrict_violation';
    END IF;
    IF OLD.estado = 'CANCELADO' THEN
        RAISE EXCEPTION 'Una tarea cancelada no se reactiva: se agrega otra' USING ERRCODE = 'restrict_violation';
    END IF;
    IF v_estado <> 'BORRADOR' AND (to_jsonb(NEW) - v_libres) <> (to_jsonb(OLD) - v_libres) THEN
        RAISE EXCEPTION 'Con la orden confirmada, lo pactado de una tarea (qué, cuánto, a qué precio) no se edita: se cancela con motivo y se agrega otra'
            USING ERRCODE = 'restrict_violation';
    END IF;
    IF OLD.aprobacion_cliente_en IS NOT NULL
       AND (NEW.aprobacion_cliente_en, NEW.aprobacion_cliente_canal, NEW.aprobacion_cliente_ref)
           IS DISTINCT FROM (OLD.aprobacion_cliente_en, OLD.aprobacion_cliente_canal, OLD.aprobacion_cliente_ref) THEN
        RAISE EXCEPTION 'La aprobación del cliente ya registrada no se cambia' USING ERRCODE = 'restrict_violation';
    END IF;

    IF NEW.estado <> OLD.estado THEN
        IF NOT ((OLD.estado = 'PENDIENTE' AND NEW.estado IN ('HECHO', 'CANCELADO'))
             OR (OLD.estado = 'HECHO' AND NEW.estado = 'PENDIENTE' AND v_estado = 'EN_CURSO')) THEN
            RAISE EXCEPTION 'Cambio de tarea inválido: % -> %', OLD.estado, NEW.estado USING ERRCODE = 'check_violation';
        END IF;
        IF NEW.estado = 'HECHO' THEN
            IF v_estado <> 'EN_CURSO' THEN
                RAISE EXCEPTION 'Las tareas se marcan hechas con la orden en curso' USING ERRCODE = 'check_violation';
            END IF;
            IF NEW.origen <> 'ORIGINAL' AND COALESCE(NEW.precio_unitario, 0) > 0 AND NEW.aprobacion_cliente_en IS NULL THEN
                RAISE EXCEPTION 'Trabajo adicional con costo: falta la aprobación del cliente' USING ERRCODE = 'check_violation';
            END IF;
            NEW.hecho_en  := COALESCE(NEW.hecho_en, hora_del_evento());
            NEW.hecho_por := COALESCE(NEW.hecho_por, ctx_uuid('app.usuario_id'));
        ELSIF NEW.estado = 'PENDIENTE' THEN          -- se rehace (control de calidad)
            NEW.hecho_en := NULL;
            NEW.hecho_por := NULL;
        ELSE                                         -- CANCELADO
            NEW.cancelado_por := COALESCE(NEW.cancelado_por, ctx_uuid('app.usuario_id'));
            NEW.cancelado_en  := hora_del_evento();
        END IF;
    END IF;
    RETURN NEW;
END
$$;
CREATE TRIGGER orden_item_validar BEFORE INSERT OR UPDATE OR DELETE ON orden_item
    FOR EACH ROW EXECUTE FUNCTION orden_item_validar();

CREATE FUNCTION orden_item_registrar() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_estado  estado_orden;
    v_numero  bigint;
    v_tipo    text;
BEGIN
    SELECT estado, numero INTO v_estado, v_numero FROM orden WHERE id = NEW.orden_id;
    IF TG_OP = 'INSERT' THEN
        IF v_estado = 'BORRADOR' THEN
            RETURN NULL;                             -- armando la orden: todavía no es un cambio
        END IF;
        v_tipo := 'TAREA_AGREGADA';
        IF NEW.hallazgo_id IS NOT NULL THEN
            UPDATE hallazgo SET estado = 'PRESUPUESTADO' WHERE id = NEW.hallazgo_id AND estado = 'ABIERTO';
        END IF;
    ELSIF NEW.estado IS DISTINCT FROM OLD.estado THEN
        v_tipo := CASE NEW.estado WHEN 'HECHO' THEN 'TAREA_HECHA' WHEN 'CANCELADO' THEN 'TAREA_CANCELADA'
                                  ELSE 'TAREA_REABIERTA' END;
        IF NEW.estado = 'HECHO' AND NEW.hallazgo_id IS NOT NULL THEN
            UPDATE hallazgo SET estado = 'RESUELTO', resolucion = 'Resuelto en OT-' || v_numero
             WHERE id = NEW.hallazgo_id AND estado NOT IN ('RESUELTO', 'DESCARTADO');
        END IF;
    ELSIF NEW.aprobacion_cliente_en IS NOT NULL AND OLD.aprobacion_cliente_en IS NULL THEN
        v_tipo := 'TAREA_APROBADA_POR_CLIENTE';
    ELSE
        RETURN NULL;
    END IF;
    INSERT INTO evento_orden (orden_id, tipo, usuario_id, dispositivo_id, acceso_emergencia_id, datos, ocurrido_en)
    VALUES (NEW.orden_id, v_tipo, ctx_uuid('app.usuario_id'), ctx_uuid('app.dispositivo_id'),
            ctx_uuid('app.acceso_emergencia_id'),
            jsonb_build_object('tarea_id', NEW.id, 'descripcion', NEW.descripcion, 'origen', NEW.origen,
                               'motivo', NEW.motivo, 'precio_unitario', NEW.precio_unitario,
                               'canal_aprobacion', NEW.aprobacion_cliente_canal),
            hora_del_evento());
    RETURN NULL;
END
$$;
CREATE TRIGGER orden_item_registrar AFTER INSERT OR UPDATE ON orden_item
    FOR EACH ROW EXECUTE FUNCTION orden_item_registrar();

-- ---------------------------------------------------------------------
-- Stock: libro de movimientos (el stock es la suma; nada se pisa ni se borra)
-- ---------------------------------------------------------------------
CREATE TYPE tipo_movimiento AS ENUM ('INVENTARIO_INICIAL', 'INGRESO', 'CONSUMO', 'DEVOLUCION', 'AJUSTE');

CREATE TABLE movimiento_stock (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    producto_id     uuid NOT NULL REFERENCES producto (id),
    tipo            tipo_movimiento NOT NULL,
    cantidad        numeric(10, 2) NOT NULL CHECK (cantidad <> 0),   -- con signo: + entra, − sale
    orden_item_id   uuid REFERENCES orden_item (id),                 -- CONSUMO / DEVOLUCION: contra qué tarea
    documento       text,                                            -- INGRESO: remito o factura del proveedor
    motivo          text,                                            -- AJUSTE: por qué
    registrado_por  uuid NOT NULL REFERENCES usuario (id),
    aprobado_por    uuid REFERENCES usuario (id),                    -- AJUSTE: otra persona
    ocurrido_en     timestamptz NOT NULL DEFAULT now(),
    registrado_en   timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT mov_signo CHECK (
        (tipo IN ('INVENTARIO_INICIAL', 'INGRESO', 'DEVOLUCION') AND cantidad > 0)
     OR (tipo = 'CONSUMO' AND cantidad < 0)
     OR  tipo = 'AJUSTE'),
    CONSTRAINT mov_tarea CHECK (tipo NOT IN ('CONSUMO', 'DEVOLUCION') OR orden_item_id IS NOT NULL),
    CONSTRAINT mov_ingreso_con_documento CHECK (tipo <> 'INGRESO' OR documento IS NOT NULL),
    CONSTRAINT mov_ajuste_aprobado CHECK (
        tipo <> 'AJUSTE' OR (motivo IS NOT NULL AND aprobado_por IS NOT NULL AND aprobado_por <> registrado_por))
);
CREATE INDEX movimiento_stock_producto_idx ON movimiento_stock (producto_id, ocurrido_en);
-- El inventario inicial se carga una sola vez por artículo (después todo son movimientos).
CREATE UNIQUE INDEX movimiento_inventario_inicial_uq ON movimiento_stock (producto_id) WHERE tipo = 'INVENTARIO_INICIAL';

CREATE FUNCTION movimiento_stock_validar() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.tipo = 'AJUSTE' AND NEW.aprobado_por IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM usuario WHERE id = NEW.aprobado_por AND rol IN ('ADMIN', 'ADMINISTRACION') AND activo) THEN
        RAISE EXCEPTION 'Un ajuste de stock lo aprueba Administración' USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF NEW.tipo IN ('CONSUMO', 'DEVOLUCION')
       AND NOT EXISTS (SELECT 1 FROM orden_item i JOIN orden o ON o.id = i.orden_id
                        WHERE i.id = NEW.orden_item_id AND o.estado IN ('EN_CURSO', 'PAUSADA', 'TERMINADA')) THEN
        RAISE EXCEPTION 'El consumo se registra contra una tarea de una orden en curso o terminada'
            USING ERRCODE = 'check_violation';
    END IF;
    NEW.registrado_en := now();
    RETURN NEW;
END
$$;
CREATE TRIGGER movimiento_stock_validar BEFORE INSERT ON movimiento_stock
    FOR EACH ROW EXECUTE FUNCTION movimiento_stock_validar();
CREATE TRIGGER movimiento_stock_append_only BEFORE UPDATE OR DELETE ON movimiento_stock
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
    acceso_emergencia_id uuid REFERENCES acceso_emergencia (id),  -- hecho desde un celular personal
    datos            jsonb,
    ocurrido_en      timestamptz NOT NULL DEFAULT now(),  -- cuándo pasó (hora real si se cargó desde papel)
    registrado_en    timestamptz NOT NULL DEFAULT now()   -- cuándo se cargó en el sistema
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
        IF NEW.estado = 'CONFIRMADA'
           AND NOT EXISTS (SELECT 1 FROM orden_item WHERE orden_id = NEW.id AND estado <> 'CANCELADO') THEN
            RAISE EXCEPTION 'OT-% no tiene ítems a instalar', NEW.numero USING ERRCODE = 'check_violation';
        END IF;
        IF NEW.estado = 'AGENDADA'
           AND NOT EXISTS (SELECT 1 FROM turno WHERE orden_id = NEW.id AND estado = 'VIGENTE') THEN
            RAISE EXCEPTION 'OT-% no tiene turno asignado', NEW.numero USING ERRCODE = 'check_violation';
        END IF;
        IF NEW.estado = 'TERMINADA' THEN
            IF EXISTS (SELECT 1 FROM orden_item WHERE orden_id = NEW.id AND estado = 'PENDIENTE') THEN
                RAISE EXCEPTION 'OT-% tiene tareas pendientes: se hacen o se cancelan con motivo antes de terminar', NEW.numero
                    USING ERRCODE = 'check_violation';
            END IF;
            IF NOT EXISTS (SELECT 1 FROM orden_item WHERE orden_id = NEW.id AND estado = 'HECHO') THEN
                RAISE EXCEPTION 'OT-% no tiene ninguna tarea hecha', NEW.numero USING ERRCODE = 'check_violation';
            END IF;
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
        INSERT INTO evento_orden (orden_id, tipo, estado_nuevo, usuario_id, dispositivo_id,
                                  acceso_emergencia_id, datos, ocurrido_en)
        VALUES (NEW.id, 'CREADA', NEW.estado,
                COALESCE(ctx_uuid('app.usuario_id'), NEW.creada_por), ctx_uuid('app.dispositivo_id'),
                ctx_uuid('app.acceso_emergencia_id'),
                jsonb_build_object('origen', NEW.origen), hora_del_evento());
    ELSIF NEW.estado IS DISTINCT FROM OLD.estado THEN
        INSERT INTO evento_orden (orden_id, tipo, estado_anterior, estado_nuevo, usuario_id, dispositivo_id,
                                  acceso_emergencia_id, ocurrido_en)
        VALUES (NEW.id, 'CAMBIO_ESTADO', OLD.estado, NEW.estado,
                ctx_uuid('app.usuario_id'), ctx_uuid('app.dispositivo_id'),
                ctx_uuid('app.acceso_emergencia_id'), hora_del_evento());

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
-- Minimización de datos: el operario ve nombre y patente; NUNCA documento ni teléfono del cliente.
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

-- La historia clínica del auto: una línea de tiempo con todo lo que le pasó.
-- No incluye datos del cliente: si el auto cambia de dueño, la historia sigue
-- sin exponer al dueño anterior.
CREATE VIEW vista_historia_vehiculo AS
SELECT o.vehiculo_id, o.creada_en AS fecha, 'VISITA' AS tipo,
       'OT-' || o.numero || ' · ' || o.estado AS titulo,
       jsonb_build_object('km', o.km_ingreso, 'estado', o.estado) AS detalle, o.id AS orden_id
  FROM orden o WHERE o.vehiculo_id IS NOT NULL
UNION ALL
SELECT o.vehiculo_id, i.hecho_en, 'TAREA', i.descripcion,
       jsonb_build_object('por', u.nombre, 'origen', i.origen), o.id
  FROM orden_item i JOIN orden o ON o.id = i.orden_id LEFT JOIN usuario u ON u.id = i.hecho_por
 WHERE i.estado = 'HECHO'
UNION ALL
SELECT h.vehiculo_id, h.registrado_en, 'HALLAZGO', h.descripcion,
       jsonb_build_object('tipo', h.tipo, 'severidad', h.severidad, 'estado', h.estado), h.orden_id
  FROM hallazgo h
UNION ALL
SELECT c.vehiculo_id, c.instalado_en, 'COMPONENTE', p.descripcion,
       jsonb_build_object('serie', c.numero_serie, 'garantia_hasta', c.garantia_hasta,
                          'retirado', c.retirado_en IS NOT NULL), i.orden_id
  FROM componente_instalado c JOIN producto p ON p.id = c.producto_id JOIN orden_item i ON i.id = c.orden_item_id
UNION ALL
SELECT o.vehiculo_id, a.firmado_en, 'ENTREGA', 'Acta firmada · ' || a.conformidad,
       jsonb_build_object('medio', a.medio), o.id
  FROM acta_entrega a JOIN orden o ON o.id = a.orden_id;

-- Stock físico por artículo (suma del libro de movimientos).
CREATE VIEW vista_stock AS
SELECT p.id AS producto_id, p.sku, p.descripcion,
       COALESCE(sum(m.cantidad), 0) AS fisico,
       max(m.ocurrido_en) AS ultimo_movimiento
  FROM producto p LEFT JOIN movimiento_stock m ON m.producto_id = p.id
 GROUP BY p.id, p.sku, p.descripcion;

-- Precio vigente de cada artículo de marca: la última lista aprobada con vigencia <= hoy.
CREATE VIEW vista_precio_vigente AS
SELECT DISTINCT ON (p.id)
       p.id AS producto_id, p.sku, p.descripcion, m.nombre AS marca, i.precio, l.moneda,
       l.precios_con_iva, l.vigente_desde, l.id AS lista_id, i.id AS lista_precio_item_id
  FROM producto p
  JOIN marca m ON m.id = p.marca_id
  JOIN lista_precio_item i ON i.producto_id = p.id
  JOIN lista_precio l ON l.id = i.lista_id AND l.estado = 'APROBADA' AND l.vigente_desde <= current_date
 ORDER BY p.id, l.vigente_desde DESC;

COMMIT;
