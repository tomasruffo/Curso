# Tecnologías: con qué construirlo

**Criterios:**
- que **vuele** en las tablets y en la oficina;
- que corra bien en **Google Cloud** ([INFRA-GCP.md](INFRA-GCP.md));
- que sea **seguro** ([SEGURIDAD.md](SEGURIDAD.md));
- que un **equipo chico** pueda construirlo y mantenerlo sin depender de una persona.

**La decisión central: TypeScript en todo.** Un solo lenguaje para la app de las tablets, el back-office, la API, los procesos de fondo y los agentes.
- **Menos costo:** los tipos y las validaciones se escriben una vez y se comparten entre frontend y backend.
- **Equipo:** es el lenguaje con más desarrolladores disponibles en Argentina para este tipo de sistema.
- **La única excepción posible** es la facturación automática con ARCA (etapa 2), que puede ir en un servicio aparte en Python (ver abajo).

---

## El stack

| Capa | Tecnología | Por qué |
|---|---|---|
| **Base de datos** | **PostgreSQL 16 en Cloud SQL** (alta disponibilidad) | Ya está diseñada y probada: [`schema.sql`](schema.sql) con 123 pruebas. Las reglas importantes viven en la base |
| **Migraciones** | **SQL puro** con una herramienta simple (por ejemplo, dbmate) | El esquema usa triggers, restricciones de exclusión y enums. Un ORM pesado pelea con eso; SQL puro lo respeta |
| **Acceso a datos** | **Kysely** (consultas en TypeScript con tipos generados desde la base) | Consultas rápidas y con tipos, sin esconder el SQL. Cada request abre una transacción con `SET LOCAL app.usuario_id`, que es lo que usa el historial de auditoría |
| **API** | **Node.js + TypeScript con Fastify**, validación con **Zod** | Fastify es de los frameworks más rápidos de Node. Zod valida todo lo que entra y comparte los tipos con el frontend |
| **Arquitectura** | **Un monolito modular** (órdenes, agenda, stock, precios, facturación…) + **procesos de fondo** aparte | Mucho más simple de operar que microservicios. Se separa sólo lo pesado: PDFs, WhatsApp, agentes y facturación |
| **Frontend** (back-office y tablets) | **React + Vite + TypeScript**, instalable como app (**PWA**) | Una sola aplicación con pantallas por rol. Vite genera paquetes chicos y carga rápida |
| **Datos en pantalla** | **TanStack Query** | Caché, reintentos y **respuesta inmediata al tocar** (el botón cambia y después confirma el servidor) |
| **Diseño** | Los tokens de las [propuestas visuales](propuestas-visuales/) (colores, vidrio, tipografía) + componentes accesibles (Radix) | El estilo ya está definido; se pasa a componentes reutilizables |
| **Agenda** | **Componente propio** con arrastrar y soltar (dnd-kit) | Las vistas por recurso (operarios, boxes) de las librerías de calendario conocidas suelen ser de pago. La [agenda diseñada](propuestas-visuales/03-agenda.html) es simple de construir |
| **Firma del cliente** | **signature_pad** (código abierto) | Captura los trazos con tiempo y presión, que es lo que guarda el acta |
| **Ingreso con passkey** | **SimpleWebAuthn** | Librería estándar de passkeys para TypeScript. Las sesiones son las del modelo (`sesion`) |
| **Tiempo real** | **Server-Sent Events** + **LISTEN/NOTIFY de PostgreSQL** | Cuando la oficina agenda, la tablet se entera en segundos. No hace falta otro servidor (como Redis): la base avisa a todas las instancias |
| **Procesos de fondo** | **Cloud Tasks** (cola con reintentos) + **Cloud Scheduler** (tareas programadas) | Avisos por WhatsApp, PDFs, la agenda de las 7:00, el agente nocturno. Todo administrado por Google |
| **PDFs** (actas, facturas, agenda) | **HTML → PDF con Chromium** (por ejemplo, Gotenberg en un contenedor) | El PDF se ve igual que la pantalla y se arma con el mismo HTML |
| **Excel de las marcas** | **exceljs** | Lee las listas de precios y de campañas. Una configuración por marca dice qué columna es cada dato |
| **WhatsApp** | **API oficial de WhatsApp Business** (Cloud API), por HTTPS | Sin librerías intermedias. Cada mensaje que llega se verifica con su firma |
| **Agentes de IA** | **SDK oficial de Anthropic para TypeScript**, con el cliente para **Google Cloud** y su Tool Runner | Mismo lenguaje que el resto. Se autentica con la cuenta de servicio, sin claves ([AGENTES.md](AGENTES.md)) |
| **Facturación con ARCA** (etapa 2) | Servicio aparte. Por ejemplo, **pyafipws** (Python, código abierto y muy usado en Argentina) o un proveedor | En la etapa 1 la facturación es manual asistida y no hace falta. Aislarlo deja todo lo demás en TypeScript |
| **Archivos** (fotos, firmas, PDFs) | **Cloud Storage**, con subida directa desde la tablet mediante links firmados | Las fotos no pasan por la API: se suben solas en segundo plano |
| **Infraestructura** | **Terraform** + **Cloud Run** (contenedores) | Ya definido en [INFRA-GCP.md](INFRA-GCP.md) |
| **Integración y despliegue** | **GitHub Actions** → Artifact Registry → Cloud Run, sin claves (Workload Identity Federation) | Cada cambio pasa por pruebas antes de llegar a producción |
| **Pruebas** | **Vitest** (lógica), **Playwright** (pantallas de punta a punta) y las **pruebas SQL** que ya existen, contra un PostgreSQL real en cada despliegue | Las reglas de la base ya tienen 123 pruebas; se suman las de la app |
| **Monitoreo** | **OpenTelemetry** → Cloud Logging, Monitoring y Trace | Ver qué pantalla o consulta se pone lenta antes de que lo note el taller |

---

## Las tablets: web, y nativa sólo si hace falta

1. **Arrancar como PWA:** la misma aplicación web, instalada en las tablets Android.
   - El MDM puede instalarla y fijarla en modo kiosco.
   - Usa la cámara del navegador para las fotos.
2. **Si el kiosco o la cámara se quedan cortos** en algún equipo, se envuelve la misma aplicación con **Capacitor** y queda una app Android nativa. **No se reescribe nada.**
3. **Tolerancia a cortes (fase opcional):** TanStack Query + IndexedDB para guardar la agenda del día y una cola de acciones. El modelo ya está preparado: las acciones llevan un ID que no se duplica.

---

## Qué lo hace rápido

| Dónde | Qué |
|---|---|
| **Distancia** | Todo en **São Paulo**: unos 30–40 ms desde Buenos Aires. Los archivos estáticos (la app en sí) desde una **CDN** |
| **Arranque** | **Mínimo 2 instancias** de Cloud Run siempre encendidas: nunca hay "primer request lento" |
| **Base de datos** | Conexiones reutilizadas (pool) y los índices que ya están en el esquema. Con el volumen de un taller, PostgreSQL responde en milisegundos |
| **Pantallas** | Paquetes divididos por rol: la tablet del técnico no descarga el back-office |
| **Interacción** | Respuesta inmediata al tocar; las fotos se suben por detrás; los cambios llegan por SSE sin recargar |
| **Medición** | Los objetivos del [README §5](README.md) (respuesta < 100 ms al tocar, < 0,5 s confirmado) se miden con OpenTelemetry desde el primer día |

---

## Alternativas que descarto

| Opción | Por qué no |
|---|---|
| **Backend en Python (FastAPI)** | Muy buena opción técnica, pero suma un segundo lenguaje. Se reserva sólo para ARCA si hace falta |
| **Firebase o Supabase** | Arrancan rápido, pero el diseño de seguridad (cifrado con KMS, perímetro de VPC, reglas en la base) encaja mejor con los servicios nativos de Google Cloud |
| **ORM con su propio esquema** (por ejemplo, Prisma) | Las reglas viven en triggers y restricciones de PostgreSQL; un ORM que quiere manejar el esquema choca con eso |
| **Microservicios desde el día 1** | Más cosas para operar, desplegar y monitorear sin beneficio a esta escala |
| **Herramientas low-code** (AppSheet, Retool) | No alcanzan la velocidad que piden las tablets ni el control de seguridad |
| **App nativa desde el inicio** | El doble de código. Capacitor queda como plan B sin reescribir |

---

## Para arrancar

1. **Repositorio único** con la API, la aplicación web, los procesos de fondo y el esquema SQL. Tipos compartidos entre todo.
2. **Primer entregable:** login con passkey → alta de orden → agenda → tablet del operario. Así se prueba **de punta a punta** que "vuela" en tablets reales del taller.
3. **Ambiente de pruebas en Google Cloud desde la primera semana**, armado con Terraform, para medir la velocidad real desde el taller y no desde la oficina de desarrollo.
