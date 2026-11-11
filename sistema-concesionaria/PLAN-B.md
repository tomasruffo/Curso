# Plan de emergencia del sistema de órdenes

> **Imprimir este documento y tenerlo en el taller y en la oficina.** Si el sistema está caído, no se va a poder abrir desde el sistema.
> Revisarlo cada 3 meses, después de cada simulacro y después de cada incidente real.

El sistema está **todo en la nube** y las tablets trabajan **conectadas a internet**. Si la tablet no llega a la nube, no puede trabajar. Este plan define **cómo devolverles la conexión en minutos** y, si no se puede, **cómo seguir sin el sistema** y cargarlo después sin perder nada.

---

## La hoja para pegar en la pared

| Nivel | Cuándo | Qué se hace | Quién | Objetivo |
|---|---|---|---|---|
| **0 · Normal** | Todo anda | — | — | — |
| **1 · Automático** | Se cortó la fibra | El router pasa solo a la línea 4G | Nadie | Segundos, nadie lo nota |
| **2 · Celular → tablets** | El local no tiene internet (router caído, sin luz, 4G caído) | Los **celulares de emergencia** comparten datos (red `TALLER-EMERGENCIA`) y las tablets se conectan ahí | Responsable de emergencia | Taller operando en **≤ 10 min** |
| **3 · Desde el celular** | Las tablets no pueden usarse (sin batería, rotas, no alcanza el hotspot) | Se trabaja **desde celulares**: los de la empresa para todo, los personales con **código de emergencia** y sólo para marcar avance | Responsable de emergencia | **≤ 15 min** |
| **4 · Papel** | **El sistema está caído**, no hay señal de celular, o los niveles 2–3 no funcionaron en **20 min** | **Agenda impresa + planilla de avance + talonarios**. Se carga todo después | Responsable de emergencia | **Inmediato** |

**Reglas de oro**
1. **Ante la duda, papel.** Pasar a papel nunca es un error. Quedarse esperando con el taller parado, sí.
2. **El hotspot sólo sirve si el problema es la red del local.** Si el sistema está caído, los celulares tampoco van a poder entrar: directo al nivel 4.
3. **Lo que no se guardó en el sistema se anota en papel.** Si la tablet dice "NO SE GUARDÓ", se anota en la planilla. Nada queda "en la cabeza".
4. **Al volver, se carga todo en el día.** Una emergencia termina cuando el papel está cargado, no cuando vuelve internet.

---

## Roles

| Rol | Quién (completar) | Qué hace |
|---|---|---|
| **Responsable de emergencia** | Coordinador de taller del turno | Diagnostica, **declara el nivel**, avisa a todos y decide pasar a papel. No necesita pedir permiso |
| **Suplente** | | Lo mismo, si el responsable no está |
| **Custodios de los celulares de emergencia** | 2 personas | Los tienen cargados, saben activar el hotspot |
| **Responsable de sistemas** | | Diagnostica la nube, habla con proveedores e informa cada 30 min |
| **Todos** | | Saben dónde está el kit y qué nivel está declarado |

**Cómo se avisa un cambio de nivel:** en voz alta en el taller **y** en el grupo interno de WhatsApp "Emergencia taller" (los celulares tienen datos propios). Ejemplo: *"NIVEL 2 desde las 10:15. Conecten las tablets a TALLER-EMERGENCIA."*

---

## Preparación: lo que tiene que estar listo ANTES

### Celulares de emergencia (la pieza clave)
- **2 celulares de la empresa**, cada uno de **una compañía distinta**, y distinta también de la del 4G del router. Si se cae una compañía, queda la otra.
- **Plan de datos con margen** para un día completo de taller: medir el consumo real el primer mes y contratar al menos el doble.
- **Enrolados en el MDM** como equipos de la empresa. Pueden hacer todo, **incluida la firma del cliente**.
- **Hotspot preconfigurado** con nombre `TALLER-EMERGENCIA` y la misma clave en los dos.
- **La red `TALLER-EMERGENCIA` ya guardada en todas las tablets** (se carga desde el MDM). Al prender el hotspot, las tablets se conectan con un toque o solas.
- **Capacidad:** en la práctica, un celular atiende bien unas **5 tablets**. Con más tablets se usan los 2 celulares, o se suma un **router 4G portátil** con batería.
- **Siempre cargados** (más del 80 % al abrir) y con **cargador y power bank** en el kit. El hotspot gasta mucha batería: mientras se usa, el celular va enchufado.

### Acceso desde celulares personales (nivel 3)
- Sólo se usa en nivel 3 y sólo si hace falta.
- El responsable lo habilita desde el back-office (**Admin → Acceso de emergencia**): genera un **código por persona** y se lo dicta. El código **vence solo en 12 horas como máximo**.
- **Qué se puede hacer:** ver la propia agenda y marcar inicio, pausa, ítems y fin.
- **Qué NO:** firma del cliente, fotos del vehículo o del cliente (se sacan con el celular de la empresa), ver datos de otros clientes.
- Todo lo hecho así queda marcado en el historial como "acceso de emergencia".

### Papel
- **Agenda impresa del día**: el sistema la manda por email todos los días a las 7:00. **Se imprime al abrir y se pega en el taller.**
- **Planilla de avance del taller** (una hoja por día). Columnas: N° de orden · patente · operario · hora de inicio · hora de fin · estado · observaciones. Sirve para las órdenes que **ya existían** en el sistema.
- **Talonario de Órdenes de contingencia** (`C-0001`, `C-0002`…), para órdenes **nuevas**.
- **Talonario de Actas de entrega de contingencia** (`A-0001`…), con original para la concesionaria y duplicado para el cliente, y **el mismo texto de conformidad** que la tablet.

### Requisitos del sistema (para el equipo de desarrollo)
- [ ] Si no hay conexión, la app muestra **"SIN CONEXIÓN"** en **10 segundos como máximo**. **Nunca** una ruedita girando sin fin.
- [ ] Cada acción muestra claramente **"Guardado ✓"** o **"NO SE GUARDÓ, reintentar"**. Reintentar es seguro: el sistema no duplica (ya está en la base).
- [ ] Las pantallas de operario y de entregas **funcionan en un celular** (no sólo en tablet).
- [ ] Back-office: **carga diferida con hora real** (la base ya guarda hora real y hora de carga), **acta en papel con escaneo obligatorio** (ya en la base), **acceso de emergencia** (ya en la base) y un reporte de **talonarios usados vs. cargados**.
- [ ] Email automático de la **agenda del día a las 7:00**.
- [ ] Red `TALLER-EMERGENCIA` distribuida por MDM a todas las tablets.

---

## Paso 1 · Diagnóstico (minutos 0 a 3)

```
¿Las tablets muestran "SIN CONEXIÓN"?
│
├── Sólo una ──────► Problema de esa tablet: cerrar y abrir la app; apagar y prender el Wi-Fi.
│                    Si sigue: TABLET DE RESERVA (ver "Otros problemas").
│
└── Varias / todas ─► Con un celular de emergencia, CON EL WI-FI APAGADO (sólo datos móviles):
                      ¿abre el sistema?
                      │
                      ├── SÍ ──► Falla la red del local ──────────────────► NIVEL 2
                      │
                      └── NO ──► ¿Abre cualquier otra página (ej. google.com)?
                                 │
                                 ├── SÍ ──► EL SISTEMA ESTÁ CAÍDO ──► NIVEL 4 + avisar a Sistemas
                                 │          (el hotspot no sirve)
                                 │
                                 └── NO ──► Sin señal: probar con el OTRO celular (otra compañía).
                                            Si ninguno tiene datos ──────► NIVEL 4
```

Anotar la **hora de inicio** en el **Registro del incidente** (al final de este documento).

---

## Nivel 1 · Automático (router con 4G)

El router pasa solo de la fibra a la línea 4G. **Nadie tiene que hacer nada.**

- Si las tablets muestran "SIN CONEXIÓN" por más de **2 minutos**, el nivel 1 no alcanzó: hacer el diagnóstico y pasar a **nivel 2**.
- Llamar al proveedor de fibra y anotar el número de reclamo.

---

## Nivel 2 · Celular → tablets (hotspot)

1. **Declarar NIVEL 2** en voz alta y en el grupo.
2. **Prender el hotspot `TALLER-EMERGENCIA`** en el celular de emergencia 1, **enchufado** al cargador o power bank.
3. **Ubicarlo en el centro del taller y en alto**, fuera de armarios metálicos. Si el taller es grande o hay más de 5 tablets: prender también el celular 2 en la otra punta.
4. **En cada tablet**: si no se conecta sola, ir a **Ajustes → Wi-Fi → `TALLER-EMERGENCIA`**.
5. **Prioridad** si no alcanza para todas:
   1. **Tablet de firma** (hay un cliente esperando para llevarse el auto)
   2. Tablets de operarios con **trabajos en curso**
   3. El resto
   4. **Oficina:** una sola PC, o atender desde el celular
6. **Verificar** que cada tablet muestre "conectado" y que una acción de prueba diga "Guardado ✓".
7. **¿Hubo acciones con "NO SE GUARDÓ" durante el corte?** Se reintentan ahora, o se anotan en la planilla.
8. Si en **10 minutos** no está funcionando: **nivel 3** (si el sistema anda desde los celulares) o **nivel 4**.

**Corte de luz:** la UPS mantiene el router de 30 a 60 minutos. Cuando se agota, es un nivel 2 (los celulares tienen batería). Bajar el brillo de las tablets. Para cargarlas se puede usar un vehículo con cargador USB o power banks.

---

## Nivel 3 · Trabajar desde el celular

Para cuando **el sistema funciona** desde los celulares pero **las tablets no se pueden usar**: sin batería, rotas, o el hotspot no alcanza.

1. **Declarar NIVEL 3.**
2. **Celulares de la empresa:** se usan para **entregas (firma del cliente)** y **fotos**.
3. **Operarios con celular propio:** el responsable entra a **Admin → Acceso de emergencia**, genera un código para cada uno y se lo dicta. Con el código, el operario ve **sólo su agenda** y marca avance.
4. **Operarios sin celular o sin datos:** usan la **planilla de avance** en papel.
5. **La firma del cliente NUNCA va en un celular personal**: se usa el celular de la empresa o el acta de papel.

---

## Nivel 4 · Papel

**Cuándo:** el sistema está caído, no hay señal de celular, o los niveles 2 y 3 no funcionaron en 20 minutos.

1. **Declarar NIVEL 4.** Avisar a Sistemas si el sistema está caído.
2. **Taller:** seguir con la **agenda impresa** del día.
3. **Avance de órdenes existentes:** cada operario anota en la **planilla de avance** el N° de orden, la patente y las **horas reales** de inicio y fin.
4. **Órdenes nuevas:** **talonario `C-xxxx`**, con todos los campos (cliente, DNI/CUIT, teléfono, **patente o VIN**, trabajos, quién la tomó). Si se le da turno, anotarlo **en lapicera sobre la agenda impresa**, con operario y horario, y **verificar a ojo que no se superponga**.
5. **Entregas:** **acta `A-xxxx`** con original y duplicado. El cliente firma y se lleva el duplicado. **Sacarle una foto al acta** con el celular de la empresa, como respaldo.
6. **Clientes por WhatsApp o teléfono:** atender desde el celular de la empresa y anotar en el talonario.

---

## Vuelta a la normalidad

1. El responsable verifica que **el sistema funciona desde una tablet en el Wi-Fi normal** y declara **NIVEL 0**.
2. **Apagar los hotspots.** Las tablets vuelven al Wi-Fi normal (si alguna no vuelve, seleccionarlo a mano).
3. **Revocar los accesos de emergencia:** Admin → Acceso de emergencia → **Revocar todos**. Igual vencen solos.
4. **Cargar el papel en el día** (máximo 24 h). Lo hace el coordinador, en este orden:
   1. **Actas de entrega `A-xxxx`**: se cargan como acta en papel con **el escaneo o foto obligatorio**.
   2. **Planilla de avance**: estados de cada orden con la **hora real** anotada (el sistema guarda aparte la hora real y la hora de carga).
   3. **Órdenes nuevas `C-xxxx`**: con origen "Contingencia papel" y el número de talonario. El sistema no deja cargar dos veces el mismo número.
5. **Control:** el reporte **talonarios usados vs. cargados** tiene que dar **0 pendientes**. Archivar los originales en la carpeta del mes.
6. **Completar el Registro del incidente.** Si algo no funcionó como dice este plan, **corregir el plan**.

---

## Otros problemas (no de conexión)

| Problema | Qué hacer |
|---|---|
| **Una tablet se rompe, se pierde o la roban** | Usar la **tablet de reserva** (el operario entra con su PIN y ve su agenda al instante). **Revocar** la otra desde el back-office y **borrarla a distancia** desde el MDM. La tablet no guarda datos de clientes, así que no se pierde ni se expone nada |
| **WhatsApp no funciona o bloquean el número** | Atender por teléfono y por el celular de la empresa, y cargar las órdenes con origen "Teléfono". Los avisos automáticos quedan en cola. El acta se puede mandar por email |
| **ARCA no responde (no se puede facturar)** | Las entregas **siguen igual**: la factura queda en borrador ("para emitir") y se emite cuando ARCA vuelve. El reporte "órdenes entregadas sin factura" muestra qué falta. En la etapa 2, si la demora es larga, se vuelve a **manual asistida**. El régimen de contingencia de ARCA se define con el contador |
| **Una actualización del sistema anda mal** | Sistemas vuelve a la versión anterior desde el servidor (las tablets toman la web nueva sola). Mientras tanto, nivel 4 si hace falta |
| **Se perdieron o se dañaron datos** | No tocar nada a mano. Sistemas restaura desde el backup al momento anterior al problema. Lo hecho entre el backup y la restauración se recarga desde el papel y el historial |

---

## Kit de emergencia (revisar el primer lunes de cada mes)

- [ ] **2 celulares de emergencia** cargados, con saldo o plan de datos activo y el hotspot `TALLER-EMERGENCIA` funcionando (probarlo con una tablet)
- [ ] **Cargadores, cables y 2 power banks** cargados
- [ ] **Tablet de reserva** enrolada y cargada al 100 %
- [ ] **UPS** probada: desenchufarla 1 minuto y verificar que el router sigue andando
- [ ] **Línea 4G del router** con plan activo
- [ ] **Talonarios `C-` y `A-`** con hojas suficientes, y **planillas de avance** impresas
- [ ] **Este documento** impreso y actualizado, con **contactos y roles completos**
- [ ] El email de la **agenda de las 7:00** está llegando

---

## Simulacros

| Cada | Qué se hace | Éxito si… |
|---|---|---|
| 3 meses | Desconectar la fibra 15 min | El router pasa a 4G y nadie lo nota |
| 3 meses | **Apagar el router** 30 min (nivel 2) | Todas las tablets operando por hotspot en **≤ 10 min** |
| 6 meses | Un operario trabaja 1 h con **código de emergencia** desde su celular (nivel 3) | Su avance queda en el sistema, marcado como acceso de emergencia |
| 6 meses | **Una entrega completa en papel** y su carga posterior (nivel 4) | La orden queda ENTREGADA con el acta escaneada y las horas reales |
| Mes | Restaurar un backup en un entorno de prueba | Datos completos, y la restauración tardó menos de lo comprometido |

Hacerlos en un día y horario de poco trabajo, y anotar el resultado en el Registro del incidente como "SIMULACRO".

---

## Registro del incidente (fotocopiar)

| Campo | |
|---|---|
| Fecha / ¿simulacro? | |
| Hora de inicio · detectado por | |
| Causa (si se sabe) | |
| Cambios de nivel (nivel y hora) | |
| Hora de vuelta a nivel 0 | |
| Papel usado (`C-` desde/hasta · `A-` desde/hasta · planillas) | |
| Cargado por · fecha y hora de fin de carga | |
| Qué funcionó | |
| Qué falló | |
| Cambio a hacer en este plan | |

---

## Contactos (completar)

| Rol | Nombre | Teléfono | Para qué |
|---|---|---|---|
| Responsable de emergencia | | | Todo |
| Suplente | | | Todo |
| Responsable de sistemas / guardia | | | Sistema caído, datos, actualizaciones |
| Proveedor de fibra (soporte) | | | Nivel 1–2 |
| Proveedor 4G del router | | | Nivel 1–2 |
| Compañías de los celulares de emergencia | | | Nivel 2–3 |
| Electricista / mantenimiento | | | Cortes de luz |
| Proveedor de WhatsApp Business | | | WhatsApp caído o número bloqueado |
| Proveedor del desarrollo (si es externo) | | | Sistema caído, actualizaciones |
