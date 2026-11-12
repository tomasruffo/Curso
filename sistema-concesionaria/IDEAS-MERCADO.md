# Ideas del mercado: qué agregar al sistema

Síntesis de tres investigaciones independientes, cada una con su propio enfoque:
- **Mercado:** softwares de gestión de concesionarias y talleres, internacionales y de Latinoamérica.
- **Cliente:** experiencia del cliente y confianza.
- **Operación:** rentabilidad y particularidades de Argentina.

**Cómo leer los datos:** casi todas las cifras de impacto son de EE.UU. y muchas vienen de los propios proveedores (se aclara en cada caso). Las más sólidas son las de J.D. Power. No se encontraron estudios de impacto argentinos.

**Señal fuerte:** varias ideas aparecieron en dos o tres investigaciones por separado. Se marcan con ★.

---

## Resumen priorizado

| # | Idea | Encontrada en | ¿Ya está en el diseño? | Etapa sugerida | Complejidad |
|---|---|---|---|---|---|
| 1 | ★ **Accesorios prometidos en la venta** ("we owe"): OT interna desde Ventas, atada al 0 km y su fecha de entrega | Mercado, Operación | No | **1** | Media |
| 2 | **Quién paga cada línea**: cliente, Ventas (interno) o garantía | Mercado, Operación | No | **1** | Media |
| 3 | ★ **Kits por modelo con tiempo estándar** (baremo propio) | Mercado, Operación | Parcial: duración por trabajo, no por modelo ni en kits | **1** | Baja |
| 4 | ★ **Recepción guiada con fotos y firma** + **control de calidad con fotos** antes de entregar | las tres | Parcial: hallazgos de daños previos y km | **1** | Baja |
| 5 | **Costo de reposición, piso de precio y control de descuentos** | Operación | No (no guardamos costos) | **1** | Baja |
| 6 | **Factura: IVA contenido en la B** y condición frente al IVA del receptor | Operación | Parcial: la condición ya está en el modelo | **1** | Baja |
| 7 | ★ **Fotos y video del trabajo para el cliente** + **seguimiento del estado** + **aprobación por link** | las tres | Parcial: fotos en la tablet y aprobación registrada | 2 | Media |
| 8 | ★ **Registro de tiempos por tarea** y **tablero de productividad** | Mercado, Operación | Parcial: sólo hora de "hecho" | 2 | Media |
| 9 | **Margen neto por OT** y **ritmo del mes** para el gerente | Operación | No | 2 | Media |
| 10 | **Encuesta a las 48–72 h** con alerta + **reseña en Google** | Cliente | No | 2 | Baja |
| 11 | **Entrega guiada con video de uso** + **pasaporte digital del accesorio** (QR) | Cliente | Parcial: acta y componentes con garantía | 2 | Baja |
| 12 | ★ **Garantías: reclamos al proveedor** y **retrabajos** | Mercado, Operación | Parcial: serie y garantía por componente | 2 | Media |
| 13 | **Auditoría de fugas**: consumido sin facturar, OT sin facturar, prometidos abiertos | Operación | No | 2 | Baja |
| 14 | **Ventas perdidas, pedidos especiales con aviso y obsolescencia del stock** | Mercado, Operación | Parcial: reposición en la etapa 2 | 2 | Media |
| 15 | **Precios en dos monedas** con cotización automática y subas programadas | Operación | Parcial: la lista tiene moneda | 2 | Media |
| 16 | **Semáforo de recomendaciones** (necesario / recomendado / opcional) | Cliente | Parcial: severidad del hallazgo | 2 | Baja |
| 17 | ★ **Órdenes de canales externos** (vouchers de Mercado Libre y de la marca) | Mercado, Operación | No | Según marca | Alta |
| 18 | ★ **Cobro por link o QR** (Mercado Pago) y seña | las tres | No | 3 | Media |
| 19 | ★ **Turnos online** con disponibilidad real | Cliente, Mercado | No | 3 | Media |
| 20 | ★ **Catálogo visual o configurador** para vendedores | Cliente, Mercado | No | 3 | Media-alta |

---

## Detalle

### 1. Accesorios prometidos en la venta ★
**El problema:** el vendedor promete accesorios con el 0 km y el pedido pasa en papel al taller, donde se pierde. Reynolds lo describe así ([Fuel](https://fuel.reyrey.com/?p=3571)).

**La propuesta:**
- El vendedor carga los accesorios prometidos atados al VIN y a la **fecha de entrega**.
- El taller los recibe como **OT interna**, con precio interno.
- Un tablero muestra los pendientes por vendedor y alerta si se acerca la entrega con algo sin instalar.
- **Indicadores:** accesorios por unidad vendida y porcentaje de unidades con al menos un accesorio.

**Quién lo tiene:** Dealertrack (Digital We Owe), DealerSocket, Dominion y PBS ([due bills](https://academy.pbssystems.com/db1-due-bills)). Los softwares de talleres independientes no lo resuelven.

**Por qué va primero:** es **la fuente principal de trabajo** de un taller de accesorios de concesionaria.

### 2. Quién paga cada línea
Dentro de una misma OT, cada línea se le carga a quien corresponda:
- el **cliente** (genera factura en ARCA);
- **Ventas**, para accesorios bonificados o de preparación del 0 km (movimiento interno con tarifa interna);
- la **garantía** de la marca o del proveedor.

Es estándar en los DMS ([trabajo interno](https://www.ventavid.com/glossary/internal-work)). Define qué se factura y qué no, y evita "regalar" mano de obra sin registro. Conviene cobrar el trabajo interno a tarifa real ([Brady Ware](https://bradyware.com/stop-subsidizing-make-internal-work-profitable/)).

### 3. Kits por modelo con tiempo estándar ★
Paquetes como "Kit seguridad Hilux": los códigos de producto, los insumos, la mano de obra con **tiempo por modelo** y un precio cerrado. Se agregan a la OT con un clic.

**Por qué conviene:** es la base de casi todo lo demás. Una alarma en Hilux no lleva lo mismo que en Onix, y de ese tiempo salen la duración en la agenda, la reserva de stock, el precio y la medición de productividad.

**Fuentes:**
- Kits ya armados: Tekmetric, Shopmonkey ([canned services](https://support.shopmonkey.io/hc/en-us/articles/38743415099924-Create-a-Canned-Service)), Dealernet.
- NCM recomienda que cada concesionaria arme su propio baremo de accesorios ([NCM](https://sf.ncmassociates.com/flat-rate-file-layout)).
- **Referencia local:** FAATRA fija una hora taller de $84.000 + IVA para el segundo trimestre de 2026 ([La Nación](https://www.lanacion.com.ar/autos/cuanto-cobra-un-mecanico-por-hora-en-argentina-en-agosto-2026-nid05082026/)).

### 4. Recepción guiada y control de calidad con fotos ★
**Recepción:**
- Recorrido guiado alrededor del auto con la tablet: fotos de cada lado, daños marcados sobre un dibujo, km y checklist.
- El cliente firma la recepción y recibe el informe por WhatsApp.
- Hace **obligatoria** el acta de recepción que ya recomendábamos.

**Antes de entregar:** checklist de calidad por kit y fotos del "después".

**Por qué:** instalar accesorios implica agujerear y desarmar paneles. Protege a los dos lados.

**Quién lo tiene:**
- Autologica DealerTablet, argentino ([blog](https://blog.autologica.com/en/tag/dealertablet-en/)).
- ClearMechanic, recomendado por BMW México y GM Sudamérica ([comunicado de GM](https://clearmechanic.com/wp-content/uploads/2026/07/Prensa-General-Motors-elige-a-ClearMechanic-unico-proveedor-de-posventa-recomendado-para-Sudamerica.pdf)).
- Dealerware.

**Dato de impacto:** un concesionario FCA bajó la recepción de 30 a 10 minutos ([Portal Automotriz](https://portalautomotriz.com/print/noticias/servicios/caso-de-exito-de-clearmechanic-autoser), dato de proveedor).

### 5. Costo de reposición, piso de precio y control de descuentos
- Guardar el **costo de reposición actualizado** de cada artículo (hoy el modelo sólo tiene precio de venta).
- **Bloquear la venta por debajo de ese costo**.
- Poner un **límite de descuento por rol**, con autorización y motivo.

**Por qué:** con inflación, vender a costo histórico descapitaliza el stock sin que se note.

**Quién lo tiene:** Autologica tiene estos controles ([blog](https://blog.autologica.com/?p=7321)).

### 6. Factura
- **Condición frente al IVA del receptor:** según la RG 5616, **desde el 1/12/2026 ARCA rechaza las facturas sin ese dato** ([iProfesional](https://www.iprofesional.com/impuestos/464104-nuevo-requisito-arca-puede-trabar-emision-facturas)). El modelo ya la guarda en el cliente y en el comprobante.
- **IVA contenido en la factura B:** Ley 27.743 de Transparencia Fiscal ([preguntas frecuentes](https://contadoresenred.com/transparencia-fiscal-preguntas-frecuentes/)). El comprobante ya separa neto e IVA, así que alcanza con mostrarlo.
- **Para la etapa 2:** facturas en USD, CAEA sólo como contingencia, Factura de Crédito Electrónica MiPyME para flotas y percepciones de Ingresos Brutos. Las fuentes no coinciden en algunas fechas: **confirmar con el contador**.

### 7. Fotos y video del trabajo, seguimiento del estado y aprobación por link ★
**Los datos más sólidos de toda la investigación (J.D. Power):**
- **Estudio CSI 2026:** el 64% de los clientes quiere fotos o video, pero sólo el 26–44% de las marcas los envía ([J.D. Power 2026](https://www.jdpower.com/business/press-releases/2026-us-customer-service-index-csi-study)).
- **Estudio ASI 2024:** el trabajo recomendado se hace el **51% de las veces con foto o video, y el 24% sin ellos** ([J.D. Power 2024 ASI](https://www.jdpower.com/business/press-releases/2024-us-aftermarket-service-index-asi-study)).

**En accesorios,** la calidad está en lo que no se ve: el cableado, el sellado de una perforación. Mostrarlo justifica el precio frente al instalador de la esquina.

**Lo que se suma:**
- **Seguimiento del estado tipo delivery:** Recibido → En instalación → Control de calidad → Listo. Saca llamadas del taller.
- **Aprobación de adicionales por link:** con foto, precio y un toque para aprobar o rechazar. Aprovecha la aprobación del cliente que el modelo ya registra.

### 8. Registro de tiempos por tarea y productividad ★
**En la tablet:** el operario marca inicio, pausa y fin de cada tarea, con motivo cuando el tiempo no es productivo.

**Los indicadores** (las fuentes usan los mismos nombres para fórmulas distintas, así que conviene fijar las propias):
- **Ocupación:** horas en OT / horas de presencia.
- **Eficiencia:** horas estándar / horas reales.
- **Productividad:** horas facturadas / horas de presencia.

**Para qué sirve:** genera los tiempos reales por accesorio y modelo, que alimentan la idea 3.

**Quién lo tiene:** Mitchell 1, Tekmetric, Autologica y Quiter ([Operarios](https://biblioteca.quiter.com/wp-content/uploads/2023/06/Operarios-1.pdf)).

### 9. Margen neto por OT y ritmo del mes
- El **margen de cada OT** descuenta el costo del operario, el costo de reposición y el **costo del medio de pago**. Por ejemplo, Mercado Pago Point cobra 5,99% + IVA en crédito con acreditación inmediata ([YoFacturo](https://yo-facturo.com/blog/comisiones-y-plazos-de-acreditacion-de-terminales-de-pago/)). Con cuotas, una OT que parece rentable puede quedar en cero.
- **Tablero diario del gerente:** si el mes viene en ritmo contra el objetivo.

### 10. Encuesta a las 48–72 h y reseña en Google
- **Encuesta:** dos preguntas por WhatsApp. Si la nota es baja, se avisa al jefe de taller para que llame ese mismo día. Ahí aparecen los problemas típicos de los primeros días: burbujas en el polarizado, falsas alarmas.
- **Reseña:** después se envía el link a **todos** los clientes. Pedírsela sólo a los conformes va contra la política de Google ([política](https://support.google.com/contributionpolicy/answer/7400114)).
- **En Argentina:** Tecnom ya automatiza las encuestas NPS que piden las terminales ([Tecnom](https://intercom.help/tecnom/es/articles/13403547-que-es-tecnom-boxes-touch-y-con-que-otras-herramientas-interactua)).

### 11. Entrega guiada con video de uso y pasaporte digital del accesorio
**Video de uso:** un video corto por accesorio (emparejar la dashcam, usar la alarma, cuidar el polarizado). Se graba una vez y se reutiliza. Reduce los reclamos de "no sé usarlo".

**Pasaporte digital:** un QR con número de serie, técnico, fotos y garantía. Sale directo de la historia clínica, que ya guarda los componentes.

**Por qué:** hace tangible el "original, instalado por la red y con garantía". VW Argentina da 12 meses de garantía a los accesorios originales instalados por un concesionario oficial ([Libro Blanco VW](https://www.volkswagen.com.ar/idhub/content/dam/onehub_pkw/importers/ar/tengo-un-volkswagen/mantenimiento/Vw_LibroBlanco.pdf)).

### 12. Garantías: reclamos al proveedor y retrabajos ★
- **Reclamos al proveedor o a la fábrica:** estado, pieza retenida, nota de crédito esperada y antigüedad.
- **Retrabajos:** si el auto vuelve antes de 30 días, se vincula a la OT original, al operario y a la causa.
- **Marco legal:** la Ley 24.240 da 30 días de garantía sobre el servicio (art. 23) y 6 meses sobre cosas nuevas (art. 11) ([Mendoza](https://www.mendoza.gov.ar/prensa/derechos-del-consumidor-plazo-legal-de-garantia-de-productos-y-servicios/)).
- **Por qué:** cada reclamo no presentado es margen perdido.

### 13. Auditoría de fugas
Alertas de:
- repuestos que salieron a una OT y no se facturaron;
- OT cerradas sin facturar;
- accesorios prometidos en la venta que siguen abiertos;
- ajustes de stock sin explicación.

Con el libro de movimientos y los comprobantes que ya tiene el modelo, es casi sólo armar consultas.

**Quién lo tiene:** Autologica ([auditorías](https://autologica.com/audits-module)).

### 14. Ventas perdidas, pedidos especiales y obsolescencia
- **Ventas perdidas:** registrar cada venta que no se hizo por falta de stock, con su motivo. Así el sistema sabe qué empezar a stockear. Un caso de Autologica bajó la venta perdida del 29% al 9,5% ([caso](https://www.autologica.com/?p=4065), dato de proveedor).
- **Pedidos especiales:** aviso al asesor y al cliente cuando llega la pieza, y repuestos preparados el día anterior al turno.
- **Obsolescencia:** stock valorizado por meses sin movimiento, con alerta antes de que venza la devolución al proveedor. Los accesorios quedan obsoletos cuando cambia el modelo.

### 15. Precios en dos monedas
- **Cotización:** cada lista tiene su regla de conversión (por ejemplo, BNA vendedor del día hábil anterior), tomada de la API del BCRA ([anuncio](https://www.bcra.gob.ar/noticias/nuevo-impulso-a-la-transparencia-financiera-el-bcra-lanza-la-api-de-estadisticas-cambiarias/)).
- **Subas por porcentaje:** programadas con fecha de vigencia.
- **Presupuestos sin aprobar:** se recotizan al vencer, con validez separada para mano de obra y repuestos.

**Se apoya en** las listas de precios por marca que ya están en el modelo.

### 16. Semáforo de recomendaciones
Cada sugerencia se muestra como "Necesario", "Recomendado" u "Opcional", sin ninguna preseleccionada. Si el cliente dice "no, gracias", se guarda sin insistir.

**Por qué:** ataca el motivo número uno de desconfianza en los talleres, que es la recomendación de trabajos innecesarios. Según AAA, el 76% de quienes desconfían de los talleres da ese motivo ([AAA](https://newsroom.aaa.com/2016/12/u-s-drivers-leery-auto-repair-shops/)).

### 17. Órdenes de canales externos ★
**Lo que cambia:** desde el **1/12/2026, GM y Mercado Libre venden servicios y accesorios Chevrolet con instalación en la red oficial**, en hasta 12 cuotas, con voucher y contacto en 24 h ([iProUP](https://www.iproup.com/innovacion/72887-chevrolet-vendera-el-service-de-tu-auto-en-mercado-libre-en-hasta-12-cuotas)).

**Qué hacer:**
- **Si la concesionaria es Chevrolet, es urgente.**
- Si no, alcanza con prever en la orden un origen "canal externo", porque otras marcas probablemente lo copien.

### 18 a 20. Para más adelante
- **Cobro por link o QR de Mercado Pago, y seña.** Depende de la integración con la facturación de la concesionaria.
- **Turnos online.** Gran parte del trabajo entra por Ventas, no por reserva directa del cliente.
- **Catálogo visual o configurador para vendedores.** Según izmocars, con su configurador 1 de cada 2 compradores llevaba accesorios, contra 1 de cada 10 antes. Es un dato de proveedor de 2010.

---

## Lo que confirma decisiones ya tomadas
- **WhatsApp como canal:** llega a cerca del 90% de los argentinos. Tecnom maneja más de 1 millón de mensajes por mes para unas 90 concesionarias ([iProfesional](https://www.iprofesional.com/negocios/430485-no-venden-un-solo-auto-pero-estos-argentinos-facturan-millones-con-las-agencias)). Una plantilla de tipo "utility" cuesta unos USD 0,03 por mensaje (a confirmar en Meta).
- **Tablets rápidas y que toleren cortes:** dos de las críticas más repetidas a los softwares del mercado son la **app móvil lenta** y el **mal funcionamiento sin conexión** ([Capterra](https://www.capterra.com/p/147213/AutoRepair-Cloud/reviews/?page=4)). Refuerza la fase opcional de "tolerancia a cortes" de [README §5](README.md).

## Para verificar con el abogado y el contador
- Si el **art. 21 de la Ley 24.240** (presupuesto y trabajos adicionales) sigue vigente: hay una referencia no confirmada a su derogación por el Decreto 55/2025.
- Cómo aplica el **Registro "No Llame"** a los mensajes de WhatsApp de seguimiento, y el consentimiento según la Ley 25.326.
- Las **fechas exactas de ARCA**: condición frente al IVA, restricción del CAEA y Factura de Crédito MiPyME.
- La **garantía de los accesorios originales de cada marca** (sólo se encontró la de VW: 12 meses).
