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
    ('a0000000-0000-0000-0000-000000000005', 'Entregas',     'entrega@example.com','ENTREGA');
INSERT INTO usuario (id, nombre, rol) VALUES
    ('a0000000-0000-0000-0000-000000000003', 'Operario Juan', 'OPERARIO'),
    ('a0000000-0000-0000-0000-000000000004', 'Operaria Ana',  'OPERARIO');

INSERT INTO dispositivo (id, nombre, tipo, clave_publica) VALUES
    ('d0000000-0000-0000-0000-000000000001', 'Tablet Box 1',    'TABLET_OPERARIO', 'pk-box1'),
    ('d0000000-0000-0000-0000-000000000002', 'Tablet Firma 1',  'TABLET_FIRMA',    'pk-firma1');

INSERT INTO puesto (id, nombre) VALUES ('b0000000-0000-0000-0000-000000000001', 'Box 1');

INSERT INTO catalogo_trabajo (id, codigo, descripcion, duracion_estimada_min) VALUES
    ('c0000000-0000-0000-0000-000000000001', 'ALARMA', 'Instalación de alarma', 90);

INSERT INTO cliente (id, nombre, doc_tipo, doc_numero, telefono_e164) VALUES
    ('e0000000-0000-0000-0000-000000000001', 'María Pérez', 'DNI', '30123456', '+5491155551234');

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

\echo '>>> Todas las pruebas pasaron'
ROLLBACK;
