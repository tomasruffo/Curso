# Tecnologías: con qué construirlo

## La decisión: el stack de **nexograd**

Este sistema se construye **sobre el stack y los patrones del proyecto nexograd**, que el equipo ya usa en producción en Google Cloud. El equipo ya conoce ese stack y ya tiene funcionando:
- despliegue automático con GitHub Actions;
- Terraform;
- proyectos separados de staging y producción;
- login con Firebase;
- un sistema de permisos propio;
- un servicio de IA en Python con agentes.

Todo eso vale más que cualquier diferencia técnica con un stack "ideal" desde cero.

> **Importante para quien implemente (persona o IA):** antes de escribir código, **leé los repositorios de nexograd** que se listan abajo y **seguí sus convenciones**: estructura de módulos, guards de autenticación, chequeo de permisos, configuración de Prisma, estructura del servicio Python, Terraform y workflows. Copiá **patrones**, no lógica de negocio: el taller de nexograd es de **moldería** y éste es un **taller mecánico de posventa oficial**. Lo que se describe de nexograd en este documento sale de la descripción del proyecto; **el código real manda**.

### Los repositorios de nexograd que sirven de referencia

| Repositorio | Qué es en nexograd | Qué copiar para este sistema |
|---|---|---|
| **`nexograd-taller-web`** | Web en **Next.js 16 + React 19 + TypeScript**, **Tailwind 4**, login con **Firebase Auth**, tests con **Jest + Testing Library** | Estructura de la app, login con Firebase en el cliente, configuración de Tailwind y de los tests |
| **`nexograd-core`** | Backend principal en **NestJS 11 + Prisma 6 + PostgreSQL**. **Firebase Admin** para la autenticación y **sistema de permisos propio** (por ejemplo, `taller.usar`) | Módulos de NestJS, guard de Firebase, chequeo de permisos, configuración de Prisma, manejo de errores |
| **`nexograd-core/taller`** | Servicio en **Python 3.13 + FastAPI**. **LangGraph** arma el flujo de agentes y guarda cada corrida con sus pausas (checkpoints en Postgres en staging/prod, SQLite en local). Usa el **SDK de Anthropic** y **Pydantic** para los contratos. Tests con **pytest y respuestas de la IA grabadas**, más un **banco de regresión** de calidad | Estructura del servicio, LangGraph con checkpoints en Postgres, contratos Pydantic, tests con respuestas grabadas y banco de regresión |
| **`nexograd-infra`** | **Terraform**: Cloud Run, Cloud Storage, proyectos `nexograd-staging` y `nexograd-prod` | Módulos de Terraform y separación staging/prod |
| *(todos)* | **GitHub Actions** (lo que se mergea a `staging` o `main` se despliega solo) y **pnpm** | Workflows y monorepo |

---

## El stack de este sistema

| Capa | Tecnología (igual que nexograd salvo donde se indica) | Uso en este sistema |
|---|---|---|
| **Base de datos** | **PostgreSQL 16** en **Cloud SQL con alta disponibilidad** | El modelo ya está diseñado y probado: [`schema.sql`](schema.sql) + [`pruebas_schema.sql`](pruebas_schema.sql) (123 pruebas). **Las reglas de negocio viven en la base** |
| **API principal** | **NestJS 11 + Prisma 6** | Monolito modular: órdenes y tareas, agenda, recepción, stock, precios, garantías, facturación, historia del auto, usuarios y sesiones. Ver [§ Prisma](#prisma-con-reglas-en-la-base) |
| **Web: oficina y tablets** | **Next.js 16 + React 19 + TypeScript + Tailwind 4** | Una sola aplicación con pantallas por rol. Las del **taller** (tablets) corren en el navegador y se instalan como app. Ver [§ Tablets](#nextjs-en-las-tablets) |
| **Autenticación** | **Firebase Auth** + **sistema de permisos** al estilo nexograd | Firebase identifica a la persona. **Passkeys, PIN de tablet, sesiones y revocación inmediata se resuelven en la API.** Ver [§ Autenticación](#autenticación-firebase--passkeys--sesiones-propias) |
| **Servicio de IA y procesos en Python** | **FastAPI + LangGraph + SDK de Anthropic + Pydantic** | Agentes ([AGENTES.md](AGENTES.md)), lectura de los Excel de las marcas, facturación con ARCA (etapa 2) y visión sobre fotos. Ver [§ Python](#el-servicio-en-python) |
| **Tiempo real** | **Server-Sent Events** desde NestJS + **LISTEN/NOTIFY** de PostgreSQL | Cuando la oficina agenda, la tablet se entera en segundos, sin sumar otro servidor |
| **Tareas de fondo** | **Cloud Tasks** + **Cloud Scheduler** | Avisos por WhatsApp, PDFs, agenda de las 7:00, agente nocturno |
| **PDFs** (actas, facturas, agenda) | HTML → PDF con Chromium (por ejemplo, Gotenberg en Cloud Run) | El PDF se ve igual que la pantalla |
| **Firma del cliente** | **signature_pad** | Guarda los trazos con tiempo y presión, como pide el acta |
| **Agenda** | Componente propio con arrastrar y soltar (por ejemplo, dnd-kit) | Las vistas por recurso de las librerías de calendario conocidas suelen ser de pago |
| **WhatsApp** | API oficial de WhatsApp Business (Cloud API) | Cada mensaje que llega se verifica con su firma |
| **Archivos** | **Cloud Storage** (como nexograd) | Fotos, firmas, actas, facturas, Excel originales de las marcas. Subida directa desde la tablet con links firmados |
| **Infraestructura** | **Terraform + Cloud Run + GitHub Actions + pnpm** (como nexograd) | Más lo que pide [INFRA-GCP.md](INFRA-GCP.md). Ver [§ Infraestructura](#infraestructura-ajustes-sobre-nexograd) |
| **Pruebas** | **Jest + Testing Library**, **pytest con respuestas grabadas** (como nexograd), **las pruebas SQL** y **Playwright** de punta a punta | Las 123 pruebas SQL corren en cada cambio contra un PostgreSQL real |
| **Monitoreo** | OpenTelemetry → Cloud Logging, Monitoring y Trace | Medir los objetivos de velocidad desde el primer día |

---

## Prisma con reglas en la base

Es **la única fricción real** con nexograd. El diseño pone reglas dentro de PostgreSQL:
- triggers para la máquina de estados, la auditoría y la inmutabilidad;
- la agenda con **rangos horarios que no se superponen**, como restricción de exclusión sobre un `tstzrange`;
- el **registro de quién hizo cada cambio**, que leen los triggers del contexto de la transacción.

Prisma prefiere manejar él el esquema y **no tiene tipo para rangos horarios**. **Se resuelve con disciplina**, con estas cuatro reglas:

### 1. `schema.sql` es la fuente de verdad; Prisma lo lee
- El esquema se cambia **sólo con migraciones SQL escritas a mano**, empezando por [`schema.sql`](schema.sql) como migración base.
- Se aplican con `prisma migrate deploy`, como archivos `migration.sql` en la carpeta de migraciones de Prisma.
- Después de cada migración: `prisma db pull` (Prisma lee la base y actualiza `schema.prisma`) y `prisma generate`.
- **Nunca** usar `prisma migrate dev` ni `prisma db push` contra estas bases. Calculan diferencias contra `schema.prisma`, que no conoce triggers, restricciones de exclusión, índices parciales ni CHECKs, y pueden querer resetear o borrar lo que no ven.
- Tipos que Prisma no maneja:
  - `turno.rango` (`tstzrange`) aparece como `Unsupported`;
  - `lista_precio_item.variacion_pct` es una **columna calculada por la base**: se lee y **nunca se escribe**.

### 2. La agenda usa SQL directo
Los turnos se crean y se leen con SQL parametrizado (`$queryRaw` / `$executeRaw`, o SQL tipado de Prisma si lo usan):

```ts
await tx.$executeRaw`
  INSERT INTO turno (orden_id, operario_id, puesto_id, rango, asignado_por)
  VALUES (${ordenId}::uuid, ${operarioId}::uuid, ${puestoId}::uuid,
          tstzrange(${inicio}::timestamptz, ${fin}::timestamptz), ${usuarioId}::uuid)`;
```

- **Para leer**, la vista `vista_agenda` ya expone `inicio` y `fin` como fechas comunes.
- **Si se superponen**, la base devuelve el error `23P01` (restricción de exclusión) y la API lo traduce a "ese operario o ese box ya tiene un turno en ese horario".

### 3. Toda escritura pasa por una función común que primero registra quién la hace
Los triggers leen el contexto de la **transacción**: `app.usuario_id`, `app.dispositivo_id`, `app.acceso_emergencia_id` y `app.hora_real`. Si una escritura no lo setea, el historial queda sin autor. Por eso **toda escritura** pasa por un único servicio de NestJS:

```ts
// db.service.ts — la ÚNICA forma de escribir en la base
async escribir<T>(ctx: ContextoAuditoria, fn: (tx: Prisma.TransactionClient) => Promise<T>): Promise<T> {
  return this.prisma.$transaction(async (tx) => {
    await tx.$executeRaw`SELECT set_config('app.usuario_id', ${ctx.usuarioId}, true)`;
    await tx.$executeRaw`SELECT set_config('app.dispositivo_id', ${ctx.dispositivoId ?? ''}, true)`;
    await tx.$executeRaw`SELECT set_config('app.acceso_emergencia_id', ${ctx.accesoEmergenciaId ?? ''}, true)`;
    await tx.$executeRaw`SELECT set_config('app.hora_real', ${ctx.horaReal ?? ''}, true)`;   // sólo en cargas desde papel
    return fn(tx);
  });
}
```

- `set_config(..., true)` vale sólo para esa transacción, igual que `SET LOCAL`. El texto vacío equivale a "sin valor" para los triggers.
- El `ContextoAuditoria` sale del guard de autenticación: usuario, equipo y acceso de emergencia de la sesión.
- **Que nadie escriba "por afuera":** una regla de lint, por ejemplo `no-restricted-syntax`, que prohíba `prisma.<modelo>.create/update/delete` fuera de `escribir()`, más revisión de código.
- **Las lecturas no necesitan contexto.**

### 4. Los errores de la base se traducen en un solo lugar
Un filtro de excepciones de NestJS lee el **SQLSTATE original** del error de Prisma y lo convierte en la respuesta HTTP, con el mensaje del trigger, que ya está en castellano y explica el motivo. Hay que verificar en qué propiedad del error lo expone la versión de Prisma que usan.

| SQLSTATE | Qué significa | HTTP |
|---|---|---|
| `23514` | Una regla de negocio no se cumple (transición inválida, falta aprobación del cliente, totales que no coinciden…) | 422 |
| `23P01` | Turno superpuesto | 409 |
| `23505` | Duplicado (patente, número de factura, código de emergencia ya usado…) | 409 |
| `23001` | Registro inmutable (acta, historial, factura emitida, lista aprobada…) | 409 |
| `42501` | El rol o el equipo no puede hacer eso | 403 |

### Las pruebas SQL corren siempre
En cada pull request, GitHub Actions levanta un PostgreSQL 16 y aplica las migraciones con un **usuario sin superusuario**, como en Cloud SQL. Después corre `pruebas_schema.sql`. Si una prueba falla, no se despliega.

---

## Autenticación: Firebase + passkeys + sesiones propias

**Firebase Auth no tiene passkeys propias.** Sólo existen extensiones de terceros ([CIAM Compass](https://guptadeepak.com/ciam-compass/vendors/firebase-auth/); [firebase-js-sdk #2123](https://github.com/firebase/firebase-js-sdk/issues/2123), abierto desde 2019). El diseño de [SEGURIDAD.md](SEGURIDAD.md) pide:
- passkey obligatoria para Admin y Administración;
- PIN atado a una tablet enrolada;
- código de emergencia de un solo uso;
- corte de acceso **inmediato**.

Firebase queda como **proveedor de identidad**, y lo demás se resuelve en la API:

| Caso | Cómo |
|---|---|
| **Passkey** (oficina) | NestJS valida la passkey (WebAuthn, por ejemplo con SimpleWebAuthn) contra `credencial_passkey` → crea la fila en `sesion` → emite un **custom token de Firebase** (`createCustomToken(uid, { sid, rol })`) → el cliente hace `signInWithCustomToken` |
| **Contraseña + app autenticadora** (roles que lo permiten) | Firebase con TOTP. **Nunca SMS** |
| **Tablet** (PIN) | La tablet se enrola y genera un par de claves que nunca sale del equipo. Al ingresar: PIN + firma de un desafío con la clave del equipo → la API valida ambos → `sesion` con `dispositivo_id` → custom token con `sid` |
| **Código de emergencia** | La API valida el código → `sesion` con `acceso_emergencia_id`. La base controla que sea de un solo uso → custom token con permisos mínimos |
| **Corte inmediato** | Un token de Firebase dura hasta una hora. Por eso **cada request** valida el token de Firebase **y** que la `sesion` del claim `sid` no esté revocada ni vencida (consulta indexada). La base ya revoca sola las sesiones ante una baja, un cambio de rol o una tablet revocada |
| **Permisos** | Igual que el sistema de permisos de nexograd: un permiso por acción (`ordenes.crear`, `facturas.emitir`, `precios.aprobar`…) mapeado a los roles. **La base sigue siendo la última barrera**: `politica_acceso`, aprobadores de propuestas, responsables de marca |

---

## Next.js en las tablets

- **Pantallas del taller:** componentes que corren **en el navegador** (`"use client"`). Leen y escriben **directo contra la API de NestJS** (con TanStack Query: caché, reintentos y respuesta inmediata al tocar). **No dependen del servidor de Next en cada toque.**
- **Pantallas de la oficina:** pueden aprovechar el render en el servidor de Next.js donde sume.
- **App instalable (PWA):** manifest y service worker (por ejemplo, Serwist). El MDM la instala y la fija en modo kiosco.
- **Paquetes livianos:** la tablet del técnico no descarga el back-office (grupos de rutas separados).
- **Plan B:** si el kiosco o la cámara no alcanzan en algún equipo, se envuelve con **Capacitor** sin reescribir.
- **Diseño:** las [propuestas visuales](propuestas-visuales/) son la referencia de estilo. Sus colores y medidas pasan a tokens de Tailwind 4.

---

## El servicio en Python

Se reutiliza el patrón de `nexograd-core/taller`, con estas reglas de este proyecto:

| Uso | Cómo | Regla |
|---|---|---|
| **Agentes** ([AGENTES.md](AGENTES.md)) | LangGraph con checkpoints en Postgres: la **pausa** de LangGraph es la **propuesta pendiente** que aprueba una persona | Los agentes **nunca escriben en la base**: llaman a la API de NestJS con herramientas tipadas (Pydantic) y crean `propuesta_agente` a través de ella. **Nunca reciben datos personales** |
| **Modelos** | Los que fija [AGENTES.md](AGENTES.md) (Claude Opus 5.5) | Si se reutiliza código de nexograd hecho para Opus 5 o Sonnet 5, revisar los cambios incompatibles de las versiones nuevas. Por ejemplo: no se puede forzar `tool_choice` y el razonamiento no se puede apagar |
| **Calidad** | Tests con **respuestas grabadas** + **banco de regresión**, como nexograd | Es el "medir antes de confiar" y el **modo sombra** de AGENTES.md |
| **Excel de las marcas** | Lectura de listas de precios y de campañas (pandas / openpyxl), con una configuración por marca | El resultado se carga en `lista_precio` como **borrador**. **Aprueba siempre el responsable de la marca** |
| **ARCA** (etapa 2) | Factura electrónica (por ejemplo, pyafipws) | Sólo cuando se pase a facturación automática. Si ARCA no responde, se vuelve a la manual asistida |
| **Visión** (opcional) | Leer patente o VIN de una foto en la recepción; avisar si una foto obligatoria salió borrosa o incompleta (OpenCV + Claude) | Sugiere; la persona confirma |

Puede correr con **una sola instancia**, como en nexograd: los agentes sólo proponen, así que **si se cae, no se frena nada**.

---

## Infraestructura: ajustes sobre nexograd

Igual que nexograd: **Terraform, Cloud Run, Cloud Storage, GitHub Actions, staging y producción.** Además:

- **Región São Paulo** (`southamerica-east1`) para la API, la web y la base, aunque nexograd esté en otra región.
- **API y web con al menos 2 instancias** siempre encendidas: sin "primer request lento" y sin caída si una falla.
- **Cloud SQL en alta disponibilidad** con réplica en Santiago y backups inmutables.
- **Lo de [INFRA-GCP.md](INFRA-GCP.md):** cifrado de datos personales con KMS, VPC Service Controls, políticas de organización, IAP para el panel de administración y auditoría.

**Pregunta abierta: ¿producto aparte o módulo de nexograd?** La recomendación es **producto aparte con el mismo stack y los mismos patrones**: proyectos de Google Cloud y base de datos **propios**. Los datos de los clientes del taller (DNI, teléfonos, facturas) no se mezclan con los de nexograd, y se puede aplicar todo el diseño de seguridad sin tocar lo que ya funciona. Se pueden compartir librerías y workflows.

---

## Guía para quien implemente (persona o IA)

### 1. Qué leer, en este orden
1. [`README.md`](README.md): visión general, modelo de datos y arquitectura.
2. [`FLUJOS.md`](FLUJOS.md): qué hace cada usuario, y qué es etapa 1 y qué etapa 2.
3. [`PROCESO.md`](PROCESO.md): historia clínica del auto, orden y tareas, cambios en la marcha, stock y listas de precios.
4. [`schema.sql`](schema.sql) y [`pruebas_schema.sql`](pruebas_schema.sql): **las reglas ya están implementadas y probadas**. Las pruebas son la mejor documentación de cada regla.
5. [`SEGURIDAD.md`](SEGURIDAD.md), [`INFRA-GCP.md`](INFRA-GCP.md) y [`PLAN-B.md`](PLAN-B.md).
6. [`AGENTES.md`](AGENTES.md), [`ETAPAS.md`](ETAPAS.md) e [`IDEAS-MERCADO.md`](IDEAS-MERCADO.md).
7. [`propuestas-visuales/`](propuestas-visuales/): cómo se tiene que ver.
8. **Los repositorios de nexograd** (tabla de arriba): cómo se escribe el código.

### 2. Reglas que no se negocian
- `schema.sql` es la fuente de verdad. **Nada de `prisma migrate dev` ni `prisma db push`.**
- **Toda escritura** pasa por `escribir()` con el contexto de auditoría.
- Las **123 pruebas SQL** (y las que se sumen) pasan en cada despliegue.
- **Admin y Administración sólo con passkey. Nunca SMS.**
- DNI, teléfono y email **cifrados con KMS** antes de guardarlos; se busca por HMAC.
- Los **agentes sólo proponen**, nunca escriben en la base y **nunca ven datos personales**.
- La tablet **nunca se queda esperando**: respuesta al tocar < 100 ms y aviso de "sin conexión" en ≤ 10 s.

### 3. Primer entregable completo: una "tajada vertical"
Que funcione **de punta a punta en staging**, con tablets reales del taller:

1. **Infraestructura** (Terraform, como `nexograd-infra`): proyecto de staging en São Paulo, Cloud SQL con las migraciones aplicadas, Cloud Run para la API y la web, Cloud Storage y KMS.
2. **API (NestJS):**
   - **autenticación:** passkey + PIN de tablet + sesiones con revocación;
   - **clientes y vehículos** (datos personales cifrados);
   - **órdenes y tareas** con motivo de ingreso;
   - **agenda** (SQL directo);
   - **endpoints de la tablet;**
   - **avisos en tiempo real** (SSE).
3. **Web (Next.js):** login, alta de orden, agenda de arrastrar y soltar y **tablet del técnico** (instalable). Con el estilo de las propuestas visuales.
4. **Pruebas:** SQL en CI, Jest en la API y la web, y Playwright para el recorrido completo.

**Terminado cuando:** en staging, una persona entra con passkey, carga una orden, la agenda, y el técnico la ve en la tablet, la ejecuta y la termina. Todo con las pruebas en verde y los tiempos de respuesta medidos desde el taller.

### 4. Después
Seguir el orden de [`FLUJOS.md` § 6](FLUJOS.md): recepción guiada, motivo de ingreso y tareas, garantía de fábrica, repuestos desde el box, cobro y retiro, y entrega con firma.
