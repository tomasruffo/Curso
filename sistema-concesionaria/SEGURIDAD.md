# Seguridad: ingreso al sistema y datos sensibles

El sistema maneja **DNI/CUIT, teléfonos, firmas, facturas y datos de vehículos**. Por eso la seguridad está en la etapa 1: agregar cifrado y passkeys a un sistema que ya tiene datos cargados es mucho más caro y riesgoso.

La idea central es **defensa en capas**: si una falla, la siguiente frena el ataque. Las reglas más importantes no dependen sólo del código de la aplicación: **las hace cumplir la base de datos**, y están probadas en [`pruebas_schema.sql`](pruebas_schema.sql).

---

## 1. Cómo entra cada persona

| Quién | Cómo entra | Desde dónde | Sesión máxima | Sin uso, pide de nuevo a los |
|---|---|---|---|---|
| **Admin · Administración** (facturación) | **Passkey o llave física**, sin contraseña | Sólo PCs de la empresa | 8 h | 15 min |
| **Coordinador · Vendedor · Entregas** | Passkey (recomendado) o contraseña + app autenticadora | PCs o celulares de la empresa | 12 h | 30 min |
| **Operario** | **Tablet enrolada + PIN de 6 dígitos** (no tiene contraseña) | Sólo tablets de la empresa | 12 h | 5 min |
| **Emergencia** (nivel 3 del [plan](PLAN-B.md)) | Código de un solo uso que da el coordinador | Celular personal | Lo que dure el código (≤ 12 h) | 30 min |

Esta tabla está **escrita como datos en la base** (`politica_acceso`). Si alguien intenta una sesión de admin con contraseña, o de operario desde un equipo no enrolado, **la base la rechaza aunque la aplicación tenga un bug**.

### Por qué passkeys

Hoy la forma más común de robar una cuenta es el **phishing**: un mail o WhatsApp falso que lleva a una página igual a la del sistema.

- Una **contraseña** se roba así, o se reusa de otra página que se filtró.
- Un **código por SMS o de app autenticadora** también se roba: la página falsa lo pide y lo usa en el momento. El SMS además se puede interceptar duplicando el chip.
- Una **passkey** (huella, cara o PIN del equipo, o una llave física USB/NFC) **no se puede robar así**. Está atada a la dirección real del sistema, así que no funciona en una página falsa, y la clave secreta nunca sale del equipo.

Por eso **quien puede facturar o administrar sólo entra con passkey**. Cada persona registra **dos**: la principal (por ejemplo, la notebook con huella) y una de **respaldo** (una llave física guardada en un lugar seguro).

**No se usa SMS** como segundo factor en ningún caso.

### Si se usa contraseña (roles que lo permiten)

- **Mínimo 12 caracteres**. Se recomiendan frases ("auto-rojo-llega-martes").
- Se compara contra listas de **contraseñas filtradas** y se rechazan las que aparecen ahí.
- **No se fuerza a cambiarla cada X meses** (eso lleva a contraseñas peores). Se cambia si hay sospecha.
- Se guarda sólo su hash con **argon2id**, nunca la contraseña.
- Siempre con **segundo factor** (app autenticadora). El secreto de esa app se guarda cifrado.

---

## 2. Ataques al ingreso y cómo se frenan

| Ataque | Defensa | Dónde |
|---|---|---|
| Probar contraseñas o PINs (fuerza bruta) | **5 intentos fallidos → bloqueo de 15 min** (se duplica si se repite), límite por IP y alerta al responsable | API + base (`bloqueado_hasta`, probado) |
| Bloquear a alguien a propósito escribiendo mal su contraseña | **El bloqueo no corta las sesiones que ya están abiertas** | Base (probado) |
| Averiguar qué usuarios existen | El mensaje de error es siempre el mismo: "usuario o clave incorrectos" | API |
| Robar el token de sesión de la base | En la base **sólo se guarda el hash** del token, nunca el token | Base (probado) |
| Robar la cookie desde el navegador | Cookie `HttpOnly` + `Secure` + `SameSite=Strict`; nunca en `localStorage` | API |
| Seguir usando una sesión después de un cambio | **Baja, cambio de rol, de contraseña, de PIN o de autenticador → se cortan TODAS sus sesiones al instante** | Base (probado) |
| Tablet o celular robado | **Revocar el equipo corta sus sesiones al instante**; el MDM lo borra a distancia | Base (probado) + MDM |
| Estirar una sesión o "revivir" una revocada | Imposible: la base sólo deja registrar actividad o revocarla | Base (probado) |
| Reusar un código de emergencia | **Un código = una sesión**, y la sesión no dura más que el código | Base (probado) |
| Ingreso de un admin desde un equipo nuevo | Alerta inmediata a los demás admins | API |

### Acciones críticas: se vuelve a confirmar con passkey

Aunque la sesión esté abierta, estas acciones piden **confirmar con la passkey en ese momento**. Así una PC desbloqueada o una sesión robada no alcanzan:

- Emitir o anular facturas y notas de crédito
- Ver el DNI/CUIT completo de un cliente
- Exportar datos de clientes
- Dar de alta usuarios o cambiar roles y permisos
- Habilitar accesos de emergencia, revocar equipos
- Cambiar precios del catálogo

---

## 3. Quién ve qué

Cada persona ve **lo mínimo que necesita para su trabajo**.

| Dato | Operario | Vendedor / Coordinador | Entregas | Administración | Admin |
|---|---|---|---|---|---|
| Nombre del cliente + patente | ✅ | ✅ | ✅ | ✅ | ✅ |
| Teléfono / email | — | ✅ *(queda registrado)* | ✅ *(queda registrado)* | ✅ | ✅ |
| DNI / CUIT | — | Sólo últimos 3 (`•••••456`) | Sólo últimos 3 (se le pregunta al cliente) | ✅ completo *(confirmando y registrado)* | ✅ completo *(confirmando y registrado)* |
| Actas firmadas | — | — | ✅ | ✅ | ✅ |
| Facturas | — | Ver | Ver | **Emitir** | **Emitir** |
| Exportar clientes | — | — | — | — | ✅ *(confirmando + alerta a otro admin)* |

La agenda que baja a las tablets **no incluye documento, teléfono ni email**. Esto también está probado: la vista `vista_agenda` no tiene esas columnas.

---

## 4. Datos sensibles cifrados

### Qué se cifra
**DNI/CUIT, teléfono y email** de los clientes, y el secreto del autenticador de cada usuario.

### Cómo
- **Cifrado de sobre con un KMS** (servicio de claves del proveedor de nube). La API cifra cada dato antes de guardarlo. La clave maestra **vive dentro del KMS y nunca sale de ahí**: la API le pide que descifre, y cada uso queda registrado por el proveedor.
- Para **buscar sin descifrar** se guarda un **HMAC** (una huella con otra clave). Cuando escribe un cliente, el sistema calcula la huella de su teléfono y lo encuentra al instante, y con el mismo mecanismo **la base impide DNIs duplicados** sin ver ningún DNI (probado).
- Para mostrar se guardan sólo los **últimos 3 dígitos** del documento.

### Qué se lleva alguien que roba la base o un backup
Nombres, patentes y **bloques cifrados que no sirven sin el KMS**. Al KMS sólo llega la API, nunca una persona.

### Otros datos sensibles
- **Fotos, firmas, actas y facturas en PDF**: en un storage **privado**, cifrado, con versionado y bloqueo. Se ven sólo con **links firmados que vencen en 5 minutos**, nunca con links públicos.
- **Acta de entrega**: guarda el DNI del firmante **en claro, a propósito**, porque el hash se verifica sobre el contenido exacto que se firmó. Se compensa con acceso sólo para Entregas, Administración y Admin, y cada lectura queda registrada.
- **Logs de la aplicación**: nunca se escriben DNIs, teléfonos, tokens ni contraseñas (se filtran automáticamente).
- **Backups**: cifrados, en otra cuenta/región, inmutables.
- **Claves**: una para cifrar y otra para el HMAC, separadas. Se rotan una vez por año.

---

## 5. Equipos

- **Tablets y celulares de la empresa**: enrolados en el MDM, en modo kiosco, con la clave del equipo guardada en el **hardware** (Android Keystore). Bloqueo con PIN de 6 dígitos y borrado remoto. Sin enrolar, la API no los acepta.
- **PCs de Administración y Admin**: equipos de la empresa, con disco cifrado, actualizaciones automáticas, usuarios sin permisos de administrador local y el navegador al día.
- **Opcional (recomendado para Administración):** que el panel de administración sólo se pueda abrir desde **equipos gestionados por la empresa**, con un proxy de acceso por identidad (en GCP: **Identity-Aware Proxy**, ver [INFRA-GCP.md](INFRA-GCP.md)).

---

## 6. Infraestructura

Cómo se aplica todo esto en Google Cloud, con las políticas que impiden errores de configuración: [INFRA-GCP.md](INFRA-GCP.md).

- **La base de datos no es accesible desde internet**: está en una red privada y sólo la API llega a ella.
- **Cuenta de la nube**: quienes la administran entran con **llave física**; **nadie usa la cuenta raíz**; permisos mínimos; registro de auditoría de la nube activado.
- **Secretos** (claves de la API, de WhatsApp, certificado de ARCA en la etapa 2) en un **gestor de secretos**, nunca en el código. El certificado de ARCA permite facturar en nombre de la empresa: **sólo lo usa el servicio de facturación**.
- **TLS** en todo, HSTS, cabeceras de seguridad (CSP) y **WAF** con límites de tasa.
- **Dependencias** revisadas automáticamente contra vulnerabilidades conocidas, con actualización mensual.
- **Prueba de penetración externa** antes de salir a producción y una vez por año.

---

## 7. Recuperación de cuenta (el punto más débil)

Muchos ataques no rompen el ingreso: **engañan al proceso de "perdí mi clave"**. Por eso:

- **No existe "olvidé mi contraseña" por email** para Admin y Administración.
- Cada persona tiene **2 passkeys** (principal y respaldo). Si pierde una, usa la otra y registra una nueva.
- Si pierde las dos: **otro admin verifica su identidad en persona**, revoca las anteriores y registra nuevas. Queda en el registro de seguridad.
- Siempre hay **al menos 2 admins**, para que nadie sea un punto único de falla.
- **Cuenta "rompe-vidrio"**: un admin de emergencia con llave física guardada en **caja fuerte**. Usarla **dispara una alerta a todos los admins**.

---

## 8. Personas y procesos

- **Un usuario por persona.** Prohibido compartir: cada acción queda a nombre de alguien.
- **Baja el mismo día** que alguien deja la empresa: un clic, y la base corta todas sus sesiones.
- **Revisión trimestral** de usuarios, roles y equipos enrolados.
- **Separación de funciones**: quien carga precios no emite facturas, y los ajustes de stock (etapa 2) los aprueba otra persona.
- **Capacitación anti-phishing** al empezar y una vez por año. Mensaje clave: *"Nadie del sistema te va a pedir tu PIN, tu código ni que apruebes una passkey."*

---

## 9. Detección y respuesta

**Registro de seguridad** (`evento_seguridad`): ingresos, revocaciones, bloqueos, cambios de rol, bajas, equipos revocados, datos sensibles vistos y exportaciones. **No se puede editar ni borrar** (probado).

**Alertas automáticas** al responsable:
- 5 o más intentos fallidos de un usuario, o muchos de una misma IP
- Ingreso de Admin o Administración desde un equipo nuevo
- Uso de la cuenta rompe-vidrio
- Exportaciones, o muchas consultas de DNI completo en poco tiempo
- Accesos de emergencia **sin un incidente declarado**

**Si hay un incidente:**
1. **Contener**: revocar sesiones, equipo o usuario (corta todo al instante).
2. **Investigar** con el registro de seguridad.
3. **Notificar** a quien corresponda (afectados, AAIP), según lo que indique legal.
4. **Corregir** y anotar qué se aprendió.

---

## 10. Marco legal (validar con un abogado)

- **Ley 25.326 de Protección de Datos Personales**: aviso de privacidad al cliente, finalidad clara, derechos de acceso, rectificación y supresión, y medidas de seguridad. La AAIP publicó medidas de seguridad recomendadas (Res. 47/2018) que este diseño sigue.
- Inscripción de la base ante la AAIP, si corresponde.
- Plazos de conservación de actas y facturas: definir con el contador y el abogado.

---

## 11. Qué garantiza cada capa

| Garantía | Base de datos (probado) | API | Infraestructura / MDM |
|---|---|---|---|
| Cada rol entra sólo con su método | ✅ | ✅ | |
| Duración máxima de sesión por rol | ✅ | ✅ | |
| Baja, cambio de rol o de credenciales corta sesiones | ✅ | | |
| Equipo revocado corta sesiones | ✅ | | ✅ borrado remoto |
| Código de emergencia de un solo uso | ✅ | | |
| Registro de seguridad inmutable | ✅ | | |
| DNI/teléfono cifrados, búsqueda por HMAC | ✅ (estructura) | ✅ (cifrado con KMS) | ✅ KMS |
| La agenda de las tablets no expone datos personales | ✅ | | |
| Passkeys, reautenticación, límites de intentos | | ✅ | |
| Base no accesible desde internet, WAF, TLS | | | ✅ |

---

## 12. Checklist antes de salir a producción

- [ ] Todos los Admin y Administración con **2 passkeys** registradas
- [ ] Cuenta rompe-vidrio creada, llave en caja fuerte, alerta probada
- [ ] KMS configurado; claves de cifrado y HMAC separadas; **nadie** con acceso humano al descifrado
- [ ] Base de datos en red privada; storage privado con links firmados
- [ ] Alertas de seguridad llegando al responsable (probadas)
- [ ] Tablets y celulares enrolados; prueba de "revocar y verificar que se corta"
- [ ] Logs revisados: sin DNIs, teléfonos ni tokens
- [ ] Prueba de penetración externa sin hallazgos críticos abiertos
- [ ] Aviso de privacidad y texto de conformidad validados por legal
- [ ] Capacitación anti-phishing hecha
