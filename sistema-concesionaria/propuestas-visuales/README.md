# Propuestas visuales

Doce pantallas del sistema, con un diseño oscuro, preciso y centrado en el auto. **Abrí [`index.html`](index.html) en el navegador**: desde ahí se navega a todas, y también entre ellas (la barra lateral funciona).

Cada archivo es **autocontenido**: se puede abrir solo, sin instalar nada. Sólo usa las fuentes de Google Fonts, y si no cargan se ve igual con las del sistema.

| # | Pantalla | Qué muestra |
|---|---|---|
| 01 | [Ingreso](01-ingreso.html) | Entrada con passkey, sin contraseñas |
| 02 | [Tablero](02-tablero.html) | El día de un vistazo: próxima entrega, taller en vivo, propuestas de agentes, estado |
| 03 | [Agenda](03-agenda.html) | Turnos por operario, órdenes sin agendar y el bloqueo de superposiciones a la vista |
| 04 | [Orden](04-orden.html) | El auto como protagonista, etapas, trabajos con IVA, cliente con datos protegidos, historial |
| 05 | [Tablet del operario](05-tablet-operario.html) | **Interactiva**: tildar el checklist, sacar fotos y recién entonces terminar |
| 06 | [Tablet de firma](06-tablet-firma.html) | **Interactiva**: el cliente firma con el dedo (o el mouse) y ve la confirmación |
| 07 | [WhatsApp](07-whatsapp.html) | Etapa 2: conversación + propuesta del agente para aprobar |
| 08 | [Stock inteligente](08-stock.html) | Etapa 2: disponible real, proyección a 14 días y compra sugerida |
| 09 | [Facturación](09-facturacion.html) | Etapa 1: manual asistida (copiar a ARCA, cargar el CAE, controles) |
| 10 | [Centro de control](10-centro-control.html) | Plan de emergencia, conectividad, nube, equipos y registro de seguridad |
| 11 | [Historia del auto](11-historia-vehiculo.html) | La historia clínica: visitas, km, hallazgos, lo instalado con serie y garantía, pendientes |
| 12 | [Listas de precios](12-listas-precios.html) | **Interactiva**: el responsable de la marca confirma las variaciones grandes y recién ahí puede aprobar |

## Lenguaje visual

- **Fondo casi negro con una sola luz de acento** (celeste), como un auto en un estudio de fotos. Verde, amarillo y rojo sólo para estados.
- **Superficies de vidrio** con bordes finos, mucho espacio y tipografía grande y ajustada (SF Pro en Apple, Inter en el resto).
- **El auto como firma**: una silueta dibujada con trazo luminoso que aparece al cargar la pantalla, y la **patente Mercosur** como elemento de identidad en toda la interfaz.
- **Movimiento sutil**: entradas suaves, el punto de "ahora" en la agenda, el escaneo sobre el auto. Si el equipo pide reducir el movimiento, se desactiva.

## Datos

Todos los datos son de ejemplo y **coinciden con el diseño del sistema**:
- La OT-1042 suma $ 176.250, igual que en las pruebas de facturación.
- El caso de stock (14 en depósito, 12 reservadas, 2 libres) es el ejemplo de [`AGENTES.md`](../AGENTES.md).
- Los niveles de emergencia son los de [`PLAN-B.md`](../PLAN-B.md).

"Órbita" es un nombre provisorio.
