# Plan B — contingencias del sistema de órdenes

> **Imprimir este documento y tenerlo en el taller y en la oficina.** Si el sistema está caído, no se va a poder abrir desde el sistema.
> Revisarlo cada 3 meses, después de cada simulacro y después de cada incidente real.

---

## Contactos (completar)

| Rol | Nombre | Teléfono | Cuándo llamar |
|---|---|---|---|
| Responsable de sistemas / guardia | | | Cualquier escenario de este documento |
| Proveedor de internet (fibra) — soporte | | | Escenario 1 |
| Proveedor 4G/5G del router | | | Escenario 1 |
| Electricista / mantenimiento | | | Escenario 2 |
| Proveedor del desarrollo (si es externo) | | | Escenarios 3, 6, 7 |
| Proveedor de WhatsApp Business (BSP) | | | Escenario 4 |
| Coordinador de taller (reemplazo) | | | Decide pasar a papel |

**¿Quién decide pasar a modo papel?** El coordinador de taller, o quien lo reemplace. No hace falta pedir permiso: es preferible pasar a papel de más que frenar el taller.

---

## Kit de contingencia (revisar el primer lunes de cada mes)

- [ ] **Tablet de reserva** enrolada, cargada al 100 % y con la app actualizada
- [ ] **Talonario de Órdenes de Trabajo de contingencia** pre-numerado (`C-0001`, `C-0002`…) con duplicado
- [ ] **Talonario de Actas de Entrega de contingencia** con el mismo texto de conformidad que la tablet
- [ ] **Agenda impresa** del día (la manda el sistema cada mañana a las 7:00 por email: imprimirla al llegar)
- [ ] **Celular de la empresa con datos** (para hotspot y para atender WhatsApp/teléfono)
- [ ] **UPS** probada (desenchufarla 1 minuto y verificar que el router sigue andando)
- [ ] **Router dual-WAN**: la línea 4G/5G tiene saldo/plan activo
- [ ] Cargadores y cables de repuesto para las tablets
- [ ] Este documento impreso y actualizado

---

## Diagnóstico rápido: ¿qué está fallando?

```
¿Las tablets muestran 🔴 "sin conexión"?
├── NO  → El problema es sólo de una persona/tablet → Escenario 5 (tablet) o reiniciar la app
└── SÍ  → ¿Desde un celular CON DATOS MÓVILES (sin Wi-Fi) abre el back-office?
          ├── SÍ → El problema es la red del local → Escenario 1 (internet) o 2 (luz)
          └── NO → El problema es el sistema → Escenario 3 (sistema caído)
```

**Regla de oro:** las tablets de los operarios **siguen funcionando sin conexión**. Mientras tengan batería y las órdenes del día ya descargadas, **el taller no se detiene**. Lo que se hace offline se sube solo cuando vuelve la conexión.

---

## Escenario 1 — Se corta internet en el local

**Síntoma:** tablets en 🔴, el back-office no abre desde las PCs, pero desde un celular con datos móviles sí abre.

**Qué pasa automáticamente:** el router dual-WAN pasa a la línea 4G/5G en segundos. En la mayoría de los casos nadie lo nota.

**Si el 4G también falla:**
1. **Taller: seguir trabajando normal.** Las tablets guardan todo localmente. No apagar ni reiniciar las tablets.
2. **Oficina:** activar el **hotspot del celular de la empresa** y conectar *una* PC para ver la agenda y atender WhatsApp.
3. **Órdenes nuevas que no se pueden cargar:** anotarlas en el talonario de contingencia (ver "Modo papel").
4. **Entregas:** la tablet de firma tiene precargadas las órdenes terminadas del día. El empleado elige la orden con su PIN y se la pasa al cliente. La firma queda guardada y se sube sola al volver internet.
5. Llamar al proveedor de internet.

**Al volver:** verificar en el tablero de tablets que todas pasen a 🟢 y que "pendientes" llegue a 0. Revisar la **bandeja de conflictos**.

---

## Escenario 2 — Se corta la luz

**Qué pasa automáticamente:** la UPS mantiene router y access points de 30 a 60 minutos. Las tablets funcionan con batería.

1. **Taller:** seguir trabajando con las tablets mientras haya luz natural y sea seguro.
2. **Bajar el brillo de las tablets** y no usar la de reserva salvo necesidad.
3. Si el corte supera 45 minutos: **cargar las tablets en un vehículo** con cargador USB, o con un power bank.
4. Si el corte se extiende y las tablets se agotan: **pasar a modo papel**.
5. Antes de que se agote la UPS, nada que hacer: las tablets guardan todo local.

**Al volver:** igual que el escenario 1.

---

## Escenario 3 — El sistema (servidor/nube) está caído

**Síntoma:** el back-office no abre **ni desde un celular con datos móviles**.

**Qué pasa automáticamente:** el monitoreo externo detecta la caída y avisa al responsable de sistemas. Si es una falla de zona, el failover la resuelve en minutos.

1. **Avisar al responsable de sistemas** aunque ya haya llegado la alerta automática.
2. **Taller:** seguir trabajando con las tablets (modo offline).
3. **Oficina:** usar la **agenda impresa del día** para saber qué se hace y en qué orden.
4. **Órdenes nuevas / cambios de agenda:** anotarlos en papel. No intentar reprogramar de memoria.
5. **Entregas:** igual que en el escenario 1, punto 4.
6. Si la caída supera **2 horas** o se acerca el cierre del día: pasar a **modo papel** para todo lo nuevo.

**Responsable de sistemas — procedimiento técnico (resumen):**
1. Revisar el estado del proveedor cloud y el monitoreo.
2. Falla de una instancia o zona → verificar que el failover se completó.
3. Falla de la base → promover la réplica o restaurar con PITR al último punto válido.
4. Falla de región → restaurar en la región alternativa desde backups (procedimiento detallado en el runbook técnico).
5. Comunicar al taller cada 30 minutos aunque no haya novedades.

---

## Escenario 4 — Falla WhatsApp (caída de la API o número bloqueado)

1. **Atender por teléfono** y por el **celular de la empresa** si es necesario.
2. Cargar las órdenes en el back-office con origen **`TELEFONO`** (el sistema sigue funcionando).
3. Los avisos automáticos (confirmación, recordatorio, acta) quedan **en cola** y se envían cuando vuelve. Si es urgente, el acta en PDF se puede mandar por **email** desde el back-office.
4. **Número bloqueado:** contactar al proveedor (BSP) o a Meta. Mientras tanto, publicar el número alternativo en los canales de la concesionaria.

**Prevención:** respetar las políticas de WhatsApp (sólo plantillas aprobadas, nada de mensajes masivos no solicitados) para no arriesgar el número.

---

## Escenario 5 — Una tablet se rompe, se pierde o la roban

1. **Tomar la tablet de reserva**: el operario entra con su PIN. Baja su agenda en segundos (si hay conexión).
2. **Revocar la tablet perdida** desde el back-office (Admin → Tablets → Revocar). Desde ese momento la API la rechaza.
3. **Borrado remoto** desde el MDM.
4. **¿Tenía datos sin sincronizar?** Revisar en el tablero cuántas operaciones pendientes tenía al momento de su última sincronización. Si había pendientes, rehacer esas acciones en la nueva tablet. Por ejemplo, volver a sacar fotos si el auto sigue en el taller.
5. Enrolar una nueva tablet de reserva lo antes posible.

**Tablet de firma:** si se rompe **antes** de mostrar "sincronizado ✓" de una firma, hacer firmar al cliente el **acta de papel** y cargarla después (ver "Modo papel").

**Prevención:** la sincronización es continua, así que con conexión una tablet nunca acumula más que unos segundos de datos sin subir.

---

## Escenario 6 — Después de una actualización, la app falla

1. **Avisar al responsable de sistemas.**
2. Desde el MDM, **volver a la versión anterior** de la app. Las actualizaciones se hacen primero en una tablet piloto justamente para que esto no afecte a todas.
3. Mientras tanto, si alguna tablet no se puede usar: tablet de reserva o modo papel.

**Prevención:** las actualizaciones se instalan **fuera del horario de trabajo**, primero en **una** tablet, y recién al otro día en el resto.

---

## Escenario 7 — Pérdida o corrupción de datos (error humano, ransomware)

1. **No borrar ni "arreglar" nada a mano.** Avisar al responsable de sistemas.
2. Sistemas restaura desde **backup punto-en-el-tiempo** al momento previo al problema. Los backups están en otra cuenta/región y son inmutables, así que un ataque no los alcanza.
3. Lo que se hizo entre el backup y la restauración se recupera desde las tablets (que reenvían sus operaciones) y desde el papel.

**Prevención:** prueba de restauración **mensual** y documentada.

---

## Modo papel (último recurso)

Se usa cuando no se puede registrar en el sistema por ningún medio.

### Orden de Trabajo de contingencia (talonario `C-0001`…)
Completar **siempre**: número de talonario · fecha y hora · cliente (nombre, DNI/CUIT, teléfono) · **patente o VIN** · marca/modelo/color · trabajos a realizar · operario asignado · horario · firma de quien la armó.

### Acta de Entrega de contingencia
Mismo texto de conformidad que la tablet · número de OT (del sistema o `C-xxxx`) · patente · trabajos realizados · conforme / con observaciones · **nombre, DNI y firma del cliente** · fecha y hora · empleado que entrega. **Original** para la concesionaria y **duplicado** para el cliente.

### Carga posterior (dentro de las 24 h de restablecido el sistema)
1. Crear la orden con origen **`CONTINGENCIA_PAPEL`** y el **número de talonario** (el sistema no permite cargar dos veces el mismo número).
2. Cargar los estados reales con la fecha/hora real (agenda, inicio, fin).
3. **Escanear o fotografiar** el papel y adjuntarlo a la orden (tipo `PAPEL_ESCANEADO`).
4. Archivar el original en papel en la carpeta del mes.
5. Al final, el coordinador verifica que **no quede ningún número de talonario usado sin cargar**.

---

## Simulacros

| Cuándo | Qué | Éxito si… |
|---|---|---|
| Cada 3 meses, en un día de poco trabajo | Desconectar el cable de fibra 30 min | El router pasa a 4G sin que el taller lo note |
| Cada 3 meses | Desconectar fibra **y** 4G 30 min | El taller sigue trabajando offline; al volver, todo sincroniza y 0 pendientes |
| Cada 6 meses | Una entrega completa en modo papel + carga posterior | La orden queda completa en el sistema con el papel adjunto |
| Cada mes | Restaurar un backup en un entorno de prueba | Los datos restaurados están completos y la restauración tardó menos que el RTO |

Anotar el resultado de cada simulacro y actualizar este documento con lo aprendido.
