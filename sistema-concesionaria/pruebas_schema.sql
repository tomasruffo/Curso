-- =====================================================================
--  Pruebas de las reglas de negocio del esquema.
--  Uso:  psql -v ON_ERROR_STOP=1 -f schema.sql -f pruebas_schema.sql
--  Todo corre dentro de una transacción que termina en ROLLBACK: no deja datos.
-- =====================================================================
\set ON_ERROR_STOP on
\o /dev/null
BEGIN;

-- Ejecuta un SQL que DEBE fallar con el SQLSTATE indicado.
CREATE FUNCTION pg_temp.debe_fallar(descripcion text, sentencia text, sqlstate_esperado text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    fallo boolean := false;
BEGIN
    BEGIN
        EXECUTE sentencia;
    EXCEPTION WHEN OTHERS THEN
        IF SQLSTATE <> sqlstate_esperado THEN
            RAISE EXCEPTION '[%] falló con % (se esperaba %): %', descripcion, SQLSTATE, sqlstate_esperado, SQLERRM;
        END IF;
        fallo := true;
        RAISE NOTICE 'OK  % -> rechazado: %', descripcion, SQLERRM;
    END;
    IF NOT fallo THEN
        RAISE EXCEPTION '[%] debía fallar y no falló', descripcion;
    END IF;
END
$$;

CREATE FUNCTION pg_temp.verificar(descripcion text, condicion boolean)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF condicion IS NOT TRUE THEN
        RAISE EXCEPTION '[%] no se cumple', descripcion;
    END IF;
    RAISE NOTICE 'OK  %', descripcion;
END
$$;

-- ---------------------------------------------------------------------
-- Datos base
-- ---------------------------------------------------------------------
INSERT INTO usuario (id, nombre, email, rol) VALUES
    ('a0000000-0000-0000-0000-000000000001', 'Coordinadora', 'coord@example.com',  'COORDINADOR'),
    ('a0000000-0000-0000-0000-000000000002', 'Vendedor',     'ventas@example.com', 'VENDEDOR'),
    ('a0000000-0000-0000-0000-000000000005', 'Entregas',     'entrega@example.com','ENTREGA'),
    ('a0000000-0000-0000-0000-000000000006', 'Admin',        'admin@example.com',  'ADMIN'),
    ('a0000000-0000-0000-0000-000000000007', 'Administración','cuentas@example.com','ADMINISTRACION');
INSERT INTO usuario (id, nombre, rol) VALUES
    ('a0000000-0000-0000-0000-000000000003', 'Operario Juan', 'OPERARIO'),
    ('a0000000-0000-0000-0000-000000000004', 'Operaria Ana',  'OPERARIO');

INSERT INTO dispositivo (id, nombre, tipo, clave_publica) VALUES
    ('d0000000-0000-0000-0000-000000000001', 'Tablet Box 1',    'TABLET_OPERARIO', 'pk-box1'),
    ('d0000000-0000-0000-0000-000000000002', 'Tablet Firma 1',  'TABLET_FIRMA',    'pk-firma1');

INSERT INTO puesto (id, nombre) VALUES ('b0000000-0000-0000-0000-000000000001', 'Box 1');

INSERT INTO catalogo_trabajo (id, codigo, descripcion, duracion_estimada_min) VALUES
    ('c0000000-0000-0000-0000-000000000001', 'ALARMA', 'Instalación de alarma', 90);

-- En producción la API cifra con el KMS y calcula el HMAC con otra clave.
-- En las pruebas: bytes cualquiera como "cifrado" y sha256() como sustituto del HMAC.
INSERT INTO cliente (id, nombre, doc_tipo, doc_cifrado, doc_hmac, doc_ultimos, telefono_cifrado, telefono_hmac) VALUES
    ('e0000000-0000-0000-0000-000000000001', 'María Pérez', 'DNI', '\x0a0b0c'::bytea,
     sha256('DNI:30123456'::bytea), '456', '\x0d0e0f'::bytea, sha256('+5491155551234'::bytea));

-- ---------------------------------------------------------------------
-- Patentes y vehículos
-- ---------------------------------------------------------------------
INSERT INTO vehiculo (id, patente, marca, modelo, cliente_id) VALUES
    ('f0000000-0000-0000-0000-000000000001', ' ab-123 cd ', 'Toyota', 'Corolla',
     'e0000000-0000-0000-0000-000000000001');
SELECT pg_temp.verificar('la patente se normaliza a AB123CD',
    (SELECT patente FROM vehiculo WHERE id = 'f0000000-0000-0000-0000-000000000001') = 'AB123CD');

SELECT pg_temp.debe_fallar('patente con formato inválido',
    $$INSERT INTO vehiculo (patente) VALUES ('AB12')$$, '23514');
SELECT pg_temp.debe_fallar('patente duplicada',
    $$INSERT INTO vehiculo (patente) VALUES ('ab123cd')$$, '23505');
SELECT pg_temp.debe_fallar('vehículo sin patente ni VIN',
    $$INSERT INTO vehiculo (marca) VALUES ('Ford')$$, '23514');

INSERT INTO vehiculo (id, vin, marca, modelo) VALUES       -- 0km todavía sin patente
    ('f0000000-0000-0000-0000-000000000002', '8ajba3fs0n0123456', 'Toyota', 'Hilux');
SELECT pg_temp.verificar('un 0km se registra por VIN (normalizado) sin patente',
    (SELECT vin FROM vehiculo WHERE id = 'f0000000-0000-0000-0000-000000000002') = '8AJBA3FS0N0123456');

-- ---------------------------------------------------------------------
-- Orden: de WhatsApp a confirmada
-- ---------------------------------------------------------------------
SET LOCAL app.usuario_id = 'a0000000-0000-0000-0000-000000000002';

INSERT INTO orden (id, origen, whatsapp_chat, creada_por) VALUES     -- borrador sin datos todavía
    ('10000000-0000-0000-0000-000000000001', 'WHATSAPP', 'wa-chat-77', 'a0000000-0000-0000-0000-000000000002');

SELECT pg_temp.debe_fallar('confirmar orden sin ítems',
    $$UPDATE orden SET estado = 'CONFIRMADA' WHERE id = '10000000-0000-0000-0000-000000000001'$$, '23514');

INSERT INTO orden_item (id, orden_id, trabajo_id, descripcion) VALUES
    ('11000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001',
     'c0000000-0000-0000-0000-000000000001', 'Alarma con sensor volumétrico');

SELECT pg_temp.debe_fallar('confirmar orden sin cliente/vehículo',
    $$UPDATE orden SET estado = 'CONFIRMADA' WHERE id = '10000000-0000-0000-0000-000000000001'$$, '23514');

UPDATE orden SET cliente_id  = 'e0000000-0000-0000-0000-000000000001',
                 vehiculo_id = 'f0000000-0000-0000-0000-000000000001'
 WHERE id = '10000000-0000-0000-0000-000000000001';

SELECT pg_temp.debe_fallar('saltar de BORRADOR a EN_CURSO',
    $$UPDATE orden SET estado = 'EN_CURSO' WHERE id = '10000000-0000-0000-0000-000000000001'$$, '23514');

UPDATE orden SET estado = 'CONFIRMADA' WHERE id = '10000000-0000-0000-0000-000000000001';

SELECT pg_temp.debe_fallar('marcar AGENDADA a mano sin turno',
    $$UPDATE orden SET estado = 'AGENDADA' WHERE id = '10000000-0000-0000-0000-000000000001'$$, '23514');

-- ---------------------------------------------------------------------
-- Calendario
-- ---------------------------------------------------------------------
SET LOCAL app.usuario_id = 'a0000000-0000-0000-0000-000000000001';

INSERT INTO turno (id, orden_id, operario_id, puesto_id, rango, asignado_por) VALUES
    ('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001',
     'a0000000-0000-0000-0000-000000000003', 'b0000000-0000-0000-0000-000000000001',
     '[2026-11-12 09:00-03, 2026-11-12 10:30-03)', 'a0000000-0000-0000-0000-000000000001');
SELECT pg_temp.verificar('asignar turno pasa la orden a AGENDADA',
    (SELECT estado FROM orden WHERE id = '10000000-0000-0000-0000-000000000001') = 'AGENDADA');

-- segunda orden para probar choques de agenda
INSERT INTO orden (id, estado, cliente_id, vehiculo_id, origen, creada_por) VALUES
    ('10000000-0000-0000-0000-000000000002', 'BORRADOR', 'e0000000-0000-0000-0000-000000000001',
     'f0000000-0000-0000-0000-000000000002', 'MOSTRADOR', 'a0000000-0000-0000-0000-000000000002');
INSERT INTO orden_item (orden_id, descripcion) VALUES ('10000000-0000-0000-0000-000000000002', 'Polarizado');
UPDATE orden SET estado = 'CONFIRMADA' WHERE id = '10000000-0000-0000-0000-000000000002';

SELECT pg_temp.debe_fallar('operario con dos turnos superpuestos',
    $$INSERT INTO turno (orden_id, operario_id, rango, asignado_por) VALUES
      ('10000000-0000-0000-0000-000000000002', 'a0000000-0000-0000-0000-000000000003',
       '[2026-11-12 10:00-03, 2026-11-12 11:00-03)', 'a0000000-0000-0000-0000-000000000001')$$, '23P01');
SELECT pg_temp.debe_fallar('puesto con dos autos a la vez',
    $$INSERT INTO turno (orden_id, operario_id, puesto_id, rango, asignado_por) VALUES
      ('10000000-0000-0000-0000-000000000002', 'a0000000-0000-0000-0000-000000000004',
       'b0000000-0000-0000-0000-000000000001',
       '[2026-11-12 10:00-03, 2026-11-12 11:00-03)', 'a0000000-0000-0000-0000-000000000001')$$, '23P01');
SELECT pg_temp.debe_fallar('asignar turno a quien no es operario',
    $$INSERT INTO turno (orden_id, operario_id, rango, asignado_por) VALUES
      ('10000000-0000-0000-0000-000000000002', 'a0000000-0000-0000-0000-000000000002',
       '[2026-11-12 14:00-03, 2026-11-12 15:00-03)', 'a0000000-0000-0000-0000-000000000001')$$, '23514');

-- turno contiguo (empieza justo cuando termina el otro): es válido
INSERT INTO turno (id, orden_id, operario_id, rango, asignado_por) VALUES
    ('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002',
     'a0000000-0000-0000-0000-000000000003',
     '[2026-11-12 10:30-03, 2026-11-12 11:30-03)', 'a0000000-0000-0000-0000-000000000001');
SELECT pg_temp.verificar('turno contiguo permitido',
    (SELECT estado FROM orden WHERE id = '10000000-0000-0000-0000-000000000002') = 'AGENDADA');

-- quitar el turno => la orden vuelve a CONFIRMADA (para reprogramar)
UPDATE turno SET estado = 'CANCELADO' WHERE id = '20000000-0000-0000-0000-000000000002';
SELECT pg_temp.verificar('quitar el último turno devuelve la orden a CONFIRMADA',
    (SELECT estado FROM orden WHERE id = '10000000-0000-0000-0000-000000000002') = 'CONFIRMADA');
SELECT pg_temp.debe_fallar('reactivar un turno cancelado',
    $$UPDATE turno SET estado = 'VIGENTE' WHERE id = '20000000-0000-0000-0000-000000000002'$$, '23001');

-- cancelar la orden libera la agenda
INSERT INTO turno (id, orden_id, operario_id, rango, asignado_por) VALUES
    ('20000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000002',
     'a0000000-0000-0000-0000-000000000004',
     '[2026-11-12 15:00-03, 2026-11-12 16:00-03)', 'a0000000-0000-0000-0000-000000000001');
UPDATE orden SET estado = 'CANCELADA' WHERE id = '10000000-0000-0000-0000-000000000002';
SELECT pg_temp.verificar('cancelar la orden cancela sus turnos',
    (SELECT estado FROM turno WHERE id = '20000000-0000-0000-0000-000000000003') = 'CANCELADO');
SELECT pg_temp.debe_fallar('borrar una orden',
    $$DELETE FROM orden WHERE id = '10000000-0000-0000-0000-000000000002'$$, '23001');

-- ---------------------------------------------------------------------
-- Tablet del operario (operación idempotente)
-- ---------------------------------------------------------------------
SET LOCAL app.usuario_id     = 'a0000000-0000-0000-0000-000000000003';
SET LOCAL app.dispositivo_id = 'd0000000-0000-0000-0000-000000000001';

INSERT INTO operacion_sync (id, dispositivo_id, usuario_id, orden_id, tipo, payload, ocurrida_en, resultado)
VALUES ('30000000-0000-0000-0000-000000000001', 'd0000000-0000-0000-0000-000000000001',
        'a0000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001',
        'INICIAR', '{}', '2026-11-12 09:02-03', 'APLICADA');
UPDATE orden SET estado = 'EN_CURSO' WHERE id = '10000000-0000-0000-0000-000000000001';

SELECT pg_temp.debe_fallar('la misma operación reintentada no se aplica dos veces',
    $$INSERT INTO operacion_sync (id, dispositivo_id, tipo, payload, ocurrida_en, resultado)
      VALUES ('30000000-0000-0000-0000-000000000001', 'd0000000-0000-0000-0000-000000000001',
              'INICIAR', '{}', '2026-11-12 09:02-03', 'APLICADA')$$, '23505');

UPDATE orden_item SET hecho_en = '2026-11-12 10:10-03', hecho_por = 'a0000000-0000-0000-0000-000000000003'
 WHERE id = '11000000-0000-0000-0000-000000000001';
UPDATE orden SET estado = 'TERMINADA' WHERE id = '10000000-0000-0000-0000-000000000001';

-- ---------------------------------------------------------------------
-- Entrega y firma
-- ---------------------------------------------------------------------
SET LOCAL app.usuario_id     = 'a0000000-0000-0000-0000-000000000005';
SET LOCAL app.dispositivo_id = 'd0000000-0000-0000-0000-000000000002';

SELECT pg_temp.debe_fallar('entregar sin acta firmada',
    $$UPDATE orden SET estado = 'ENTREGADA' WHERE id = '10000000-0000-0000-0000-000000000001'$$, '23514');

INSERT INTO adjunto (id, orden_id, tipo, storage_key, sha256, mime, capturado_en, dispositivo_id) VALUES
    ('40000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'FIRMA_TRAZOS',
     'ordenes/1000/firma.json', repeat('a', 64), 'application/json', '2026-11-12 18:00-03',
     'd0000000-0000-0000-0000-000000000002');

SELECT pg_temp.debe_fallar('acta cuyo hash no coincide con el contenido',
    $$INSERT INTO acta_entrega (id, orden_id, contenido_canonico, contenido_sha256, firmante_nombre,
          firmante_doc, conformidad, firma_trazos_id, entregado_por, dispositivo_id, firmado_en)
      VALUES ('50000000-0000-0000-0000-000000000009', '10000000-0000-0000-0000-000000000001',
              '{"orden":"OT-1000","patente":"AB123CD"}', repeat('0', 64), 'María Pérez', '30123456',
              'CONFORME', '40000000-0000-0000-0000-000000000001',
              'a0000000-0000-0000-0000-000000000005', 'd0000000-0000-0000-0000-000000000002',
              '2026-11-12 18:00-03')$$, '23514');

INSERT INTO acta_entrega (id, orden_id, contenido_canonico, contenido_sha256, firmante_nombre,
                          firmante_doc, conformidad, firma_trazos_id, entregado_por, dispositivo_id, firmado_en)
VALUES ('50000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001',
        '{"orden":"OT-1000","patente":"AB123CD"}',
        encode(sha256(convert_to('{"orden":"OT-1000","patente":"AB123CD"}', 'UTF8')), 'hex'),
        'María Pérez', '30123456', 'CONFORME', '40000000-0000-0000-0000-000000000001',
        'a0000000-0000-0000-0000-000000000005', 'd0000000-0000-0000-0000-000000000002', '2026-11-12 18:00-03');

UPDATE orden SET estado = 'ENTREGADA' WHERE id = '10000000-0000-0000-0000-000000000001';

SELECT pg_temp.debe_fallar('modificar un acta firmada',
    $$UPDATE acta_entrega SET firmante_nombre = 'Otro' WHERE id = '50000000-0000-0000-0000-000000000001'$$, '23001');
SELECT pg_temp.debe_fallar('borrar un acta firmada',
    $$DELETE FROM acta_entrega WHERE id = '50000000-0000-0000-0000-000000000001'$$, '23001');

-- el servidor adjunta el PDF una única vez
INSERT INTO adjunto (id, orden_id, tipo, storage_key, sha256, mime, capturado_en) VALUES
    ('40000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'ACTA_PDF',
     'ordenes/1000/acta.pdf', repeat('b', 64), 'application/pdf', now());
UPDATE acta_entrega SET pdf_id = '40000000-0000-0000-0000-000000000002'
 WHERE id = '50000000-0000-0000-0000-000000000001';
SELECT pg_temp.debe_fallar('reemplazar el PDF del acta',
    $$UPDATE acta_entrega SET pdf_id = '40000000-0000-0000-0000-000000000001'
       WHERE id = '50000000-0000-0000-0000-000000000001'$$, '23001');

SELECT pg_temp.debe_fallar('reabrir una orden entregada',
    $$UPDATE orden SET estado = 'EN_CURSO' WHERE id = '10000000-0000-0000-0000-000000000001'$$, '23514');

-- ---------------------------------------------------------------------
-- Historial
-- ---------------------------------------------------------------------
SELECT pg_temp.verificar('el historial registra el recorrido completo de la orden',
    (SELECT array_agg(estado_nuevo ORDER BY id) FROM evento_orden
      WHERE orden_id = '10000000-0000-0000-0000-000000000001')
    = ARRAY['BORRADOR', 'CONFIRMADA', 'AGENDADA', 'EN_CURSO', 'TERMINADA', 'ENTREGADA']::estado_orden[]);
SELECT pg_temp.verificar('el historial guarda quién y desde qué tablet',
    EXISTS (SELECT 1 FROM evento_orden
             WHERE orden_id = '10000000-0000-0000-0000-000000000001' AND estado_nuevo = 'EN_CURSO'
               AND usuario_id = 'a0000000-0000-0000-0000-000000000003'
               AND dispositivo_id = 'd0000000-0000-0000-0000-000000000001'));
SELECT pg_temp.debe_fallar('editar el historial',
    $$UPDATE evento_orden SET estado_nuevo = 'CANCELADA'$$, '23001');
SELECT pg_temp.debe_fallar('borrar el historial',
    $$DELETE FROM evento_orden$$, '23001');

SELECT pg_temp.verificar('la vista de agenda muestra el turno con patente y operario',
    EXISTS (SELECT 1 FROM vista_agenda WHERE vehiculo = 'AB123CD' AND operario = 'Operario Juan'));
SELECT pg_temp.verificar('una tablet que nunca sincronizó aparece en ROJO',
    (SELECT semaforo FROM vista_estado_tablets WHERE nombre = 'Tablet Box 1') = 'ROJO');

-- ---------------------------------------------------------------------
-- Plan de emergencia: carga diferida desde papel
-- (las horas son relativas a now() para que las pruebas no dependan de la fecha)
-- ---------------------------------------------------------------------
SET LOCAL app.usuario_id     = 'a0000000-0000-0000-0000-000000000001';   -- coordinadora carga el papel
SET LOCAL app.dispositivo_id = '';

INSERT INTO orden (id, cliente_id, vehiculo_id, origen, creada_por) VALUES
    ('10000000-0000-0000-0000-000000000003', 'e0000000-0000-0000-0000-000000000001',
     'f0000000-0000-0000-0000-000000000002', 'MOSTRADOR', 'a0000000-0000-0000-0000-000000000002');
INSERT INTO orden_item (orden_id, descripcion) VALUES ('10000000-0000-0000-0000-000000000003', 'Polarizado');
UPDATE orden SET estado = 'CONFIRMADA' WHERE id = '10000000-0000-0000-0000-000000000003';
INSERT INTO turno (orden_id, operario_id, rango, asignado_por)
SELECT '10000000-0000-0000-0000-000000000003', 'a0000000-0000-0000-0000-000000000004',
       tstzrange(date_trunc('hour', now()) - interval '1 day', date_trunc('hour', now()) - interval '21 hours'),
       'a0000000-0000-0000-0000-000000000001';

-- Hubo un corte: Ana trabajó la orden con la planilla de papel. Al volver, se carga con la hora real.
SELECT set_config('app.hora_real', (now() + interval '1 day')::text, true);
SELECT pg_temp.debe_fallar('cargar con hora real en el futuro',
    $$UPDATE orden SET estado = 'EN_CURSO' WHERE id = '10000000-0000-0000-0000-000000000003'$$, '23514');
SELECT set_config('app.hora_real', (now() - interval '30 days')::text, true);
SELECT pg_temp.debe_fallar('cargar con hora real de hace un mes (error de tipeo)',
    $$UPDATE orden SET estado = 'EN_CURSO' WHERE id = '10000000-0000-0000-0000-000000000003'$$, '23514');

SELECT set_config('app.hora_real', (now() - interval '1 day')::text, true);
UPDATE orden SET estado = 'EN_CURSO'  WHERE id = '10000000-0000-0000-0000-000000000003';
SELECT set_config('app.hora_real', (now() - interval '22 hours')::text, true);
UPDATE orden SET estado = 'TERMINADA' WHERE id = '10000000-0000-0000-0000-000000000003';

-- Se entregó con el acta de papel A-0001
INSERT INTO adjunto (id, orden_id, tipo, storage_key, sha256, mime, capturado_en) VALUES
    ('40000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000003', 'PAPEL_ESCANEADO',
     'ordenes/1002/acta-papel-A-0001.jpg', repeat('c', 64), 'image/jpeg', now());

SELECT pg_temp.debe_fallar('acta en papel sin el escaneo',
    $$INSERT INTO acta_entrega (id, orden_id, medio, numero_papel, contenido_canonico, contenido_sha256,
          firmante_nombre, firmante_doc, conformidad, entregado_por, firmado_en)
      VALUES ('50000000-0000-0000-0000-000000000008', '10000000-0000-0000-0000-000000000003', 'PAPEL', 'A-0001',
              '{}', encode(sha256(convert_to('{}', 'UTF8')), 'hex'), 'María Pérez', '30123456', 'CONFORME',
              'a0000000-0000-0000-0000-000000000005', now() - interval '21 hours')$$, '23514');
SELECT pg_temp.debe_fallar('acta digital sin los trazos de la firma',
    $$INSERT INTO acta_entrega (id, orden_id, contenido_canonico, contenido_sha256,
          firmante_nombre, firmante_doc, conformidad, entregado_por, dispositivo_id, firmado_en)
      VALUES ('50000000-0000-0000-0000-000000000008', '10000000-0000-0000-0000-000000000003',
              '{}', encode(sha256(convert_to('{}', 'UTF8')), 'hex'), 'María Pérez', '30123456', 'CONFORME',
              'a0000000-0000-0000-0000-000000000005', 'd0000000-0000-0000-0000-000000000002', now())$$, '23514');

INSERT INTO acta_entrega (id, orden_id, medio, numero_papel, papel_escaneado_id, contenido_canonico,
                          contenido_sha256, firmante_nombre, firmante_doc, conformidad, entregado_por, firmado_en)
VALUES ('50000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000003', 'PAPEL', 'A-0001',
        '40000000-0000-0000-0000-000000000003', '{"acta":"A-0001","vin":"8AJBA3FS0N0123456"}',
        encode(sha256(convert_to('{"acta":"A-0001","vin":"8AJBA3FS0N0123456"}', 'UTF8')), 'hex'),
        'María Pérez', '30123456', 'CONFORME', 'a0000000-0000-0000-0000-000000000005',
        now() - interval '21 hours');
SELECT set_config('app.hora_real', (now() - interval '21 hours')::text, true);
UPDATE orden SET estado = 'ENTREGADA' WHERE id = '10000000-0000-0000-0000-000000000003';
SELECT set_config('app.hora_real', '', true);

SELECT pg_temp.verificar('una orden entregada en papel queda ENTREGADA con su acta escaneada',
    (SELECT estado FROM orden WHERE id = '10000000-0000-0000-0000-000000000003') = 'ENTREGADA');
SELECT pg_temp.verificar('la carga diferida guarda la hora real y, aparte, la hora de carga',
    (SELECT bool_and(registrado_en - ocurrido_en > interval '20 hours') FROM evento_orden
      WHERE orden_id = '10000000-0000-0000-0000-000000000003'
        AND estado_nuevo IN ('EN_CURSO', 'TERMINADA', 'ENTREGADA')));

INSERT INTO orden (origen, numero_papel, creada_por) VALUES
    ('CONTINGENCIA_PAPEL', 'C-0001', 'a0000000-0000-0000-0000-000000000001');
SELECT pg_temp.debe_fallar('cargar dos veces la misma orden de talonario',
    $$INSERT INTO orden (origen, numero_papel, creada_por) VALUES
      ('CONTINGENCIA_PAPEL', 'C-0001', 'a0000000-0000-0000-0000-000000000001')$$, '23505');

-- ---------------------------------------------------------------------
-- Plan de emergencia: acceso desde celular personal (nivel 3)
-- ---------------------------------------------------------------------
SELECT pg_temp.debe_fallar('un operario no puede habilitar accesos de emergencia',
    $$INSERT INTO acceso_emergencia (usuario_id, habilitado_por, codigo_hash, motivo, vence_en)
      VALUES ('a0000000-0000-0000-0000-000000000004', 'a0000000-0000-0000-0000-000000000003',
              'x', 'corte', now() + interval '8 hours')$$, '23514');
SELECT pg_temp.debe_fallar('acceso de emergencia de más de 12 horas',
    $$INSERT INTO acceso_emergencia (usuario_id, habilitado_por, codigo_hash, motivo, vence_en)
      VALUES ('a0000000-0000-0000-0000-000000000003', 'a0000000-0000-0000-0000-000000000001',
              'x', 'corte', now() + interval '2 days')$$, '23514');
SELECT pg_temp.debe_fallar('habilitarse un acceso de emergencia a uno mismo',
    $$INSERT INTO acceso_emergencia (usuario_id, habilitado_por, codigo_hash, motivo, vence_en)
      VALUES ('a0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000001',
              'x', 'corte', now() + interval '8 hours')$$, '23514');

INSERT INTO acceso_emergencia (id, usuario_id, habilitado_por, codigo_hash, motivo, vence_en) VALUES
    ('60000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000003',
     'a0000000-0000-0000-0000-000000000001', 'hash-del-codigo', 'Nivel 3: tablet sin batería', now() + interval '8 hours');

INSERT INTO orden (id, cliente_id, vehiculo_id, origen, creada_por) VALUES
    ('10000000-0000-0000-0000-000000000004', 'e0000000-0000-0000-0000-000000000001',
     'f0000000-0000-0000-0000-000000000001', 'TELEFONO', 'a0000000-0000-0000-0000-000000000002');
INSERT INTO orden_item (orden_id, descripcion) VALUES ('10000000-0000-0000-0000-000000000004', 'Cámara de retroceso');
UPDATE orden SET estado = 'CONFIRMADA' WHERE id = '10000000-0000-0000-0000-000000000004';
INSERT INTO turno (orden_id, operario_id, rango, asignado_por) VALUES
    ('10000000-0000-0000-0000-000000000004', 'a0000000-0000-0000-0000-000000000003',
     '[2030-01-07 09:00-03, 2030-01-07 10:00-03)', 'a0000000-0000-0000-0000-000000000001');

SET LOCAL app.usuario_id           = 'a0000000-0000-0000-0000-000000000003';   -- Juan, desde su celular
SET LOCAL app.acceso_emergencia_id = '60000000-0000-0000-0000-000000000001';
UPDATE orden SET estado = 'EN_CURSO' WHERE id = '10000000-0000-0000-0000-000000000004';
SET LOCAL app.acceso_emergencia_id = '';

SELECT pg_temp.verificar('el historial marca lo hecho con acceso de emergencia (sin equipo enrolado)',
    EXISTS (SELECT 1 FROM evento_orden
             WHERE orden_id = '10000000-0000-0000-0000-000000000004' AND estado_nuevo = 'EN_CURSO'
               AND acceso_emergencia_id = '60000000-0000-0000-0000-000000000001'
               AND dispositivo_id IS NULL));

-- ---------------------------------------------------------------------
-- Seguridad de acceso
-- ---------------------------------------------------------------------
SELECT pg_temp.debe_fallar('un operario no puede entrar con contraseña',
    $$INSERT INTO sesion (token_hash, usuario_id, nivel, expira_en)
      VALUES (sha256('t-1'), 'a0000000-0000-0000-0000-000000000003', 'PASSWORD_TOTP', now() + interval '1 hour')$$, '42501');
SELECT pg_temp.debe_fallar('el admin sólo entra con passkey (contraseña + TOTP no alcanza)',
    $$INSERT INTO sesion (token_hash, usuario_id, nivel, expira_en)
      VALUES (sha256('t-2'), 'a0000000-0000-0000-0000-000000000006', 'PASSWORD_TOTP', now() + interval '1 hour')$$, '42501');

INSERT INTO sesion (id, token_hash, usuario_id, nivel, expira_en) VALUES
    ('90000000-0000-0000-0000-000000000001', sha256('t-3'), 'a0000000-0000-0000-0000-000000000006',
     'PASSKEY', now() + interval '8 hours');

SELECT pg_temp.debe_fallar('sesión de admin más larga que 8 horas',
    $$INSERT INTO sesion (token_hash, usuario_id, nivel, expira_en)
      VALUES (sha256('t-4'), 'a0000000-0000-0000-0000-000000000006', 'PASSKEY', now() + interval '10 hours')$$, '23514');
SELECT pg_temp.debe_fallar('PIN sin una tablet enrolada',
    $$INSERT INTO sesion (token_hash, usuario_id, nivel, expira_en)
      VALUES (sha256('t-5'), 'a0000000-0000-0000-0000-000000000003', 'PIN_DISPOSITIVO', now() + interval '1 hour')$$, '23514');

INSERT INTO sesion (id, token_hash, usuario_id, nivel, dispositivo_id, expira_en) VALUES
    ('90000000-0000-0000-0000-000000000002', sha256('t-6'), 'a0000000-0000-0000-0000-000000000003',
     'PIN_DISPOSITIVO', 'd0000000-0000-0000-0000-000000000001', now() + interval '12 hours');

-- código de emergencia (generado en la sección anterior, todavía sin usar, vence en 8 h)
INSERT INTO sesion (id, token_hash, usuario_id, nivel, acceso_emergencia_id, expira_en) VALUES
    ('90000000-0000-0000-0000-000000000003', sha256('t-7'), 'a0000000-0000-0000-0000-000000000003',
     'CODIGO_EMERGENCIA', '60000000-0000-0000-0000-000000000001', now() + interval '12 hours');
SELECT pg_temp.verificar('la sesión de emergencia no dura más que el código',
    (SELECT s.expira_en = a.vence_en FROM sesion s JOIN acceso_emergencia a ON a.id = s.acceso_emergencia_id
      WHERE s.id = '90000000-0000-0000-0000-000000000003'));
SELECT pg_temp.debe_fallar('un código de emergencia sirve una sola vez',
    $$INSERT INTO sesion (token_hash, usuario_id, nivel, acceso_emergencia_id, expira_en)
      VALUES (sha256('t-8'), 'a0000000-0000-0000-0000-000000000003', 'CODIGO_EMERGENCIA',
              '60000000-0000-0000-0000-000000000001', now() + interval '1 hour')$$, '42501');

UPDATE dispositivo SET activa = false WHERE id = 'd0000000-0000-0000-0000-000000000001';   -- tablet robada
SELECT pg_temp.verificar('revocar una tablet corta al instante sus sesiones',
    (SELECT revocada_en IS NOT NULL FROM sesion WHERE id = '90000000-0000-0000-0000-000000000002'));
SELECT pg_temp.debe_fallar('no se puede entrar desde una tablet revocada',
    $$INSERT INTO sesion (token_hash, usuario_id, nivel, dispositivo_id, expira_en)
      VALUES (sha256('t-9'), 'a0000000-0000-0000-0000-000000000003', 'PIN_DISPOSITIVO',
              'd0000000-0000-0000-0000-000000000001', now() + interval '1 hour')$$, '42501');

INSERT INTO sesion (id, token_hash, usuario_id, nivel, expira_en) VALUES
    ('90000000-0000-0000-0000-000000000004', sha256('t-10'), 'a0000000-0000-0000-0000-000000000005',
     'PASSKEY', now() + interval '4 hours');
UPDATE usuario SET rol = 'VENDEDOR' WHERE id = 'a0000000-0000-0000-0000-000000000005';
SELECT pg_temp.verificar('cambiar el rol de alguien corta sus sesiones (los permisos nuevos rigen ya)',
    (SELECT revocada_en IS NOT NULL FROM sesion WHERE id = '90000000-0000-0000-0000-000000000004'));

UPDATE usuario SET activo = false WHERE id = 'a0000000-0000-0000-0000-000000000004';     -- baja de Ana
SELECT pg_temp.debe_fallar('un usuario dado de baja no puede entrar',
    $$INSERT INTO sesion (token_hash, usuario_id, nivel, dispositivo_id, expira_en)
      VALUES (sha256('t-11'), 'a0000000-0000-0000-0000-000000000004', 'PIN_DISPOSITIVO',
              'd0000000-0000-0000-0000-000000000002', now() + interval '1 hour')$$, '42501');

UPDATE usuario SET intentos_fallidos = 5, bloqueado_hasta = now() + interval '15 minutes'
 WHERE id = 'a0000000-0000-0000-0000-000000000001';
SELECT pg_temp.debe_fallar('usuario bloqueado por intentos fallidos no puede entrar',
    $$INSERT INTO sesion (token_hash, usuario_id, nivel, expira_en)
      VALUES (sha256('t-12'), 'a0000000-0000-0000-0000-000000000001', 'PASSKEY', now() + interval '1 hour')$$, '42501');

SELECT pg_temp.debe_fallar('una sesión revocada no se reactiva',
    $$UPDATE sesion SET revocada_en = NULL WHERE id = '90000000-0000-0000-0000-000000000002'$$, '23001');
SELECT pg_temp.debe_fallar('una sesión no se puede extender',
    $$UPDATE sesion SET expira_en = expira_en + interval '1 day' WHERE id = '90000000-0000-0000-0000-000000000001'$$, '23001');

SELECT pg_temp.verificar('ingresos, revocaciones, cambio de rol, baja y bloqueo quedan en el registro de seguridad',
    (SELECT count(*) FILTER (WHERE tipo = 'SESION_INICIADA') = 4
        AND count(*) FILTER (WHERE tipo = 'SESION_REVOCADA') = 2
        AND count(*) FILTER (WHERE tipo = 'EQUIPO_REVOCADO') = 1
        AND count(*) FILTER (WHERE tipo = 'ROL_CAMBIADO') = 1
        AND count(*) FILTER (WHERE tipo = 'USUARIO_DADO_DE_BAJA') = 1
        AND count(*) FILTER (WHERE tipo = 'USUARIO_BLOQUEADO') = 1
       FROM evento_seguridad));
SELECT pg_temp.debe_fallar('borrar el registro de seguridad',
    $$DELETE FROM evento_seguridad$$, '23001');
SELECT pg_temp.debe_fallar('borrar un usuario (se da de baja, no se borra)',
    $$DELETE FROM usuario WHERE id = 'a0000000-0000-0000-0000-000000000004'$$, '23001');

-- ---------------------------------------------------------------------
-- Datos sensibles
-- ---------------------------------------------------------------------
SELECT pg_temp.debe_fallar('DNI duplicado detectado sin descifrar (por HMAC)',
    $$INSERT INTO cliente (nombre, doc_tipo, doc_cifrado, doc_hmac)
      VALUES ('María P.', 'DNI', '\x99'::bytea, sha256('DNI:30123456'::bytea))$$, '23505');
SELECT pg_temp.verificar('la agenda que baja a las tablets no expone documento ni teléfono',
    NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_name = 'vista_agenda'
                   AND (column_name LIKE '%doc%' OR column_name LIKE '%telefono%' OR column_name LIKE '%email%')));

-- ---------------------------------------------------------------------
-- Facturación manual asistida
-- ---------------------------------------------------------------------
-- Borrador armado desde la OT-1000: 1 alarma $100.000 + 21 %, 2 h de mano de obra $25.000 + 10,5 %
INSERT INTO comprobante (id, orden_id, cliente_id, tipo, receptor_nombre, receptor_condicion_iva, neto, iva, total) VALUES
    ('70000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001',
     'e0000000-0000-0000-0000-000000000001', 'FACTURA_B', 'María Pérez', 'CONSUMIDOR_FINAL',
     150000.00, 26250.00, 176250.00);
INSERT INTO comprobante_item (comprobante_id, descripcion, cantidad, precio_unitario, alicuota_iva) VALUES
    ('70000000-0000-0000-0000-000000000001', 'Alarma con sensor volumétrico', 1, 100000.00, 21),
    ('70000000-0000-0000-0000-000000000001', 'Mano de obra instalación (h)',  2,  25000.00, 10.5);

SELECT pg_temp.debe_fallar('un vendedor no puede emitir facturas',
    $$UPDATE comprobante SET estado = 'EMITIDO', punto_venta = 5, numero = 1, cae = '75123456789012',
             cae_vence = current_date + 10, fecha_emision = current_date,
             emitido_por = 'a0000000-0000-0000-0000-000000000002'
       WHERE id = '70000000-0000-0000-0000-000000000001'$$, '42501');
SELECT pg_temp.debe_fallar('emitir con totales que no coinciden con los ítems',
    $$UPDATE comprobante SET estado = 'EMITIDO', iva = 26000.00, total = 176000.00, punto_venta = 5, numero = 1,
             cae = '75123456789012', cae_vence = current_date + 10, fecha_emision = current_date,
             emitido_por = 'a0000000-0000-0000-0000-000000000007'
       WHERE id = '70000000-0000-0000-0000-000000000001'$$, '23514');
SELECT pg_temp.debe_fallar('emitir sin cargar el CAE',
    $$UPDATE comprobante SET estado = 'EMITIDO', punto_venta = 5, numero = 1,
             cae_vence = current_date + 10, fecha_emision = current_date,
             emitido_por = 'a0000000-0000-0000-0000-000000000007'
       WHERE id = '70000000-0000-0000-0000-000000000001'$$, '23514');
SELECT pg_temp.debe_fallar('CAE mal tipeado (no tiene 14 dígitos)',
    $$UPDATE comprobante SET cae = '7512345678901' WHERE id = '70000000-0000-0000-0000-000000000001'$$, '23514');

UPDATE comprobante SET estado = 'EMITIDO', punto_venta = 5, numero = 1, cae = '75123456789012',
       cae_vence = current_date + 10, fecha_emision = current_date,
       emitido_por = 'a0000000-0000-0000-0000-000000000007'
 WHERE id = '70000000-0000-0000-0000-000000000001';
SELECT pg_temp.verificar('Administración emite la factura con los datos de ARCA',
    (SELECT estado = 'EMITIDO' AND emitido_en IS NOT NULL FROM comprobante WHERE id = '70000000-0000-0000-0000-000000000001'));

SELECT pg_temp.debe_fallar('modificar una factura emitida',
    $$UPDATE comprobante SET receptor_nombre = 'Otro' WHERE id = '70000000-0000-0000-0000-000000000001'$$, '23001');
SELECT pg_temp.debe_fallar('agregar ítems a una factura emitida',
    $$INSERT INTO comprobante_item (comprobante_id, descripcion, cantidad, precio_unitario, alicuota_iva)
      VALUES ('70000000-0000-0000-0000-000000000001', 'Extra', 1, 1000, 21)$$, '23001');
SELECT pg_temp.debe_fallar('borrar una factura emitida',
    $$DELETE FROM comprobante WHERE id = '70000000-0000-0000-0000-000000000001'$$, '23001');
SELECT pg_temp.debe_fallar('anular una factura sin nota de crédito',
    $$UPDATE comprobante SET estado = 'ANULADO' WHERE id = '70000000-0000-0000-0000-000000000001'$$, '23001');

-- Segunda factura (OT-1002): $80.000 + 21 %
INSERT INTO comprobante (id, orden_id, cliente_id, tipo, receptor_nombre, receptor_condicion_iva, neto, iva, total) VALUES
    ('70000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000003',
     'e0000000-0000-0000-0000-000000000001', 'FACTURA_B', 'María Pérez', 'CONSUMIDOR_FINAL',
     80000.00, 16800.00, 96800.00);
INSERT INTO comprobante_item (comprobante_id, descripcion, cantidad, precio_unitario, alicuota_iva) VALUES
    ('70000000-0000-0000-0000-000000000002', 'Polarizado', 1, 80000.00, 21);
SELECT pg_temp.debe_fallar('número de factura salteado (se tipeó 3 en vez de 2)',
    $$UPDATE comprobante SET estado = 'EMITIDO', punto_venta = 5, numero = 3, cae = '75123456789013',
             cae_vence = current_date + 10, fecha_emision = current_date,
             emitido_por = 'a0000000-0000-0000-0000-000000000007'
       WHERE id = '70000000-0000-0000-0000-000000000002'$$, '23514');
UPDATE comprobante SET estado = 'EMITIDO', punto_venta = 5, numero = 2, cae = '75123456789013',
       cae_vence = current_date + 10, fecha_emision = current_date,
       emitido_por = 'a0000000-0000-0000-0000-000000000007'
 WHERE id = '70000000-0000-0000-0000-000000000002';

-- Notas de crédito
SELECT pg_temp.debe_fallar('nota de crédito sin factura asociada',
    $$INSERT INTO comprobante (orden_id, cliente_id, tipo, receptor_nombre, receptor_condicion_iva, neto, iva, total)
      VALUES ('10000000-0000-0000-0000-000000000001', 'e0000000-0000-0000-0000-000000000001', 'NOTA_CREDITO_B',
              'María Pérez', 'CONSUMIDOR_FINAL', 0, 0, 0)$$, '23514');

INSERT INTO comprobante (id, orden_id, cliente_id, tipo, comprobante_asociado_id, receptor_nombre,
                         receptor_condicion_iva, neto, iva, total) VALUES
    ('70000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000003',
     'e0000000-0000-0000-0000-000000000001', 'NOTA_CREDITO_B', '70000000-0000-0000-0000-000000000002',
     'María Pérez', 'CONSUMIDOR_FINAL', 200000.00, 42000.00, 242000.00);
INSERT INTO comprobante_item (comprobante_id, descripcion, cantidad, precio_unitario, alicuota_iva) VALUES
    ('70000000-0000-0000-0000-000000000004', 'Devolución', 1, 200000.00, 21);
SELECT pg_temp.debe_fallar('nota de crédito por más que la factura',
    $$UPDATE comprobante SET estado = 'EMITIDO', punto_venta = 5, numero = 1, cae = '75123456789014',
             cae_vence = current_date + 10, fecha_emision = current_date,
             emitido_por = 'a0000000-0000-0000-0000-000000000007'
       WHERE id = '70000000-0000-0000-0000-000000000004'$$, '23514');

INSERT INTO comprobante (id, orden_id, cliente_id, tipo, comprobante_asociado_id, receptor_nombre,
                         receptor_condicion_iva, neto, iva, total) VALUES
    ('70000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001',
     'e0000000-0000-0000-0000-000000000001', 'NOTA_CREDITO_B', '70000000-0000-0000-0000-000000000001',
     'María Pérez', 'CONSUMIDOR_FINAL', 150000.00, 26250.00, 176250.00);
INSERT INTO comprobante_item (comprobante_id, descripcion, cantidad, precio_unitario, alicuota_iva) VALUES
    ('70000000-0000-0000-0000-000000000003', 'Alarma con sensor volumétrico', 1, 100000.00, 21),
    ('70000000-0000-0000-0000-000000000003', 'Mano de obra instalación (h)',  2,  25000.00, 10.5);
UPDATE comprobante SET estado = 'EMITIDO', punto_venta = 5, numero = 1, cae = '75123456789015',
       cae_vence = current_date + 10, fecha_emision = current_date,
       emitido_por = 'a0000000-0000-0000-0000-000000000007'
 WHERE id = '70000000-0000-0000-0000-000000000003';
SELECT pg_temp.verificar('una nota de crédito por el total anula la factura automáticamente',
    (SELECT estado = 'ANULADO' FROM comprobante WHERE id = '70000000-0000-0000-0000-000000000001'));

-- ---------------------------------------------------------------------
-- Agentes de IA: proponen, una persona aprueba
-- ---------------------------------------------------------------------
INSERT INTO propuesta_agente (id, agente, modelo, tipo, payload, justificacion, datos_usados, creada_en) VALUES
    ('80000000-0000-0000-0000-000000000001', 'reposicion', 'claude-opus-5-5', 'ORDEN_COMPRA',
     '{"proveedor": "Alarmas SRL", "items": [{"sku": "ALR-X200", "cantidad": 15}]}',
     'Hay 14 en depósito y 12 reservadas para la agenda: quedan 2 libres; el proveedor tarda 5 días hábiles.',
     '{"fisico": 14, "reservado": 12, "disponible": 2, "demora_proveedor_dias_habiles": 5}',
     now() - interval '30 days');          -- intenta antedatarla
SELECT pg_temp.verificar('la base fija la fecha y el vencimiento de la propuesta (no los decide el agente)',
    (SELECT creada_en = now() AND vence_en = now() + interval '3 days'
       FROM propuesta_agente WHERE id = '80000000-0000-0000-0000-000000000001'));

SELECT pg_temp.debe_fallar('un agente no puede crear una propuesta ya aprobada',
    $$INSERT INTO propuesta_agente (agente, modelo, tipo, payload, justificacion, datos_usados, estado,
                                    revisada_por, revisada_en)
      VALUES ('reposicion', 'claude-opus-5-5', 'ORDEN_COMPRA', '{}', 'x', '{}', 'APROBADA',
              'a0000000-0000-0000-0000-000000000007', now())$$, '23514');
SELECT pg_temp.debe_fallar('un vendedor no puede aprobar una compra',
    $$UPDATE propuesta_agente SET estado = 'APROBADA', revisada_por = 'a0000000-0000-0000-0000-000000000002',
             revisada_en = now() WHERE id = '80000000-0000-0000-0000-000000000001'$$, '42501');
SELECT pg_temp.debe_fallar('cambiar lo propuesto (ej. la cantidad) antes de aprobar',
    $$UPDATE propuesta_agente SET payload = '{"proveedor": "Alarmas SRL", "items": [{"sku": "ALR-X200", "cantidad": 150}]}'
       WHERE id = '80000000-0000-0000-0000-000000000001'$$, '23001');
SELECT pg_temp.debe_fallar('rechazar sin decir por qué',
    $$UPDATE propuesta_agente SET estado = 'RECHAZADA', revisada_por = 'a0000000-0000-0000-0000-000000000007',
             revisada_en = now() WHERE id = '80000000-0000-0000-0000-000000000001'$$, '23514');
SELECT pg_temp.debe_fallar('marcar como vencida una propuesta vigente',
    $$UPDATE propuesta_agente SET estado = 'VENCIDA' WHERE id = '80000000-0000-0000-0000-000000000001'$$, '23514');

UPDATE propuesta_agente SET estado = 'APROBADA', revisada_por = 'a0000000-0000-0000-0000-000000000007',
       revisada_en = now() WHERE id = '80000000-0000-0000-0000-000000000001';
SELECT pg_temp.verificar('Administración aprueba la compra propuesta',
    (SELECT estado = 'APROBADA' FROM propuesta_agente WHERE id = '80000000-0000-0000-0000-000000000001'));
SELECT pg_temp.debe_fallar('una propuesta aprobada no se vuelve a cambiar',
    $$UPDATE propuesta_agente SET estado = 'RECHAZADA', motivo_rechazo = 'me arrepentí',
             revisada_por = 'a0000000-0000-0000-0000-000000000007', revisada_en = now()
       WHERE id = '80000000-0000-0000-0000-000000000001'$$, '23001');
SELECT pg_temp.debe_fallar('borrar una propuesta (queda el registro de qué propuso cada agente)',
    $$DELETE FROM propuesta_agente WHERE id = '80000000-0000-0000-0000-000000000001'$$, '23001');

-- una propuesta vieja no se aprueba: tipo de prueba con vigencia cero
INSERT INTO tipo_propuesta (tipo, descripcion, vigencia) VALUES ('PRUEBA_VENCE_YA', 'Sólo para pruebas', '0 seconds');
INSERT INTO propuesta_aprobador (tipo, rol) VALUES ('PRUEBA_VENCE_YA', 'ADMINISTRACION');
INSERT INTO propuesta_agente (id, agente, modelo, tipo, payload, justificacion, datos_usados) VALUES
    ('80000000-0000-0000-0000-000000000002', 'reposicion', 'claude-opus-5-5', 'PRUEBA_VENCE_YA', '{}', 'x', '{}');
SELECT pg_temp.debe_fallar('aprobar una propuesta vencida',
    $$UPDATE propuesta_agente SET estado = 'APROBADA', revisada_por = 'a0000000-0000-0000-0000-000000000007',
             revisada_en = now() WHERE id = '80000000-0000-0000-0000-000000000002'$$, '23514');

\echo '>>> Todas las pruebas pasaron'
ROLLBACK;
