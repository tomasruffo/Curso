# Modelo vintage de osciladores: Diverge y Drift

Este documento explica qué hace el parche `vintage`, en qué datos se basa
cada número, cómo se aplica dentro del firmware, qué se probó y qué falta
para las mejoras siguientes (#3, #4 y el filtro).

## Qué cambia

En el Summit original, los controles **Diverge** y **Drift** de cada sonido
hacen esto (del firmware, `docs/findings` de gipfel_mpe, y de la
lectura de `osc_drift_update` en 0x08013844):

- **Diverge:** suma a cada oscilador un desvío fijo de una tabla de 48
  valores (`diverge_rand`) por la cantidad del control. Las voces 9 a 16
  repiten los valores de las voces 1 a 8.
- **Drift:** un solo valor al azar por parte y por oscilador, compartido por
  todas las voces, que se acerca a un objetivo nuevo cada 100 ms. Todo el
  acorde sube y baja junto. Al máximo llega a ±50 cents.
- Los dos son una fracción fija de semitono: los mismos cents en todas las
  octavas.

Con el parche, esos dos controles manejan un modelo de un oscilador analógico
real (clase Prophet-5 / OB-Xa). Si un sonido tiene Diverge y Drift en 0,
suena exactamente igual que en el original.

## El modelo

Para cada voz `v` y oscilador `o`, en cents:

**Parte fija (control Diverge).** Errores de calibración que quedan para
siempre en cada oscilador:

1. **Residuo del autotune:** un desvío fijo, distinto en cada oscilador.
2. **Error de seguimiento (tracking):** cada oscilador tiene una escala de
   volt/octava apenas distinta, así que el error crece a medida que te alejás
   de C4, para arriba y para abajo. Esto es la mejora #5.
3. **Agudos bemoles:** el oscilador tarda un tiempo fijo en reiniciar cada
   ciclo, así que en las notas agudas cada ciclo dura un poco más y la nota
   baja. Casi nada en los graves, notable arriba.

**Parte que se mueve (control Drift).** Cambios mientras tocás:

4. **Temperatura:** una del equipo entero, que cambia muy despacio (unos
   50 s), más una propia de cada voz (unos 6 s). Cada oscilador reacciona
   distinto (su coeficiente de temperatura), y el efecto crece cuanto más
   aguda es la nota.
5. **Deriva 1/f:** un movimiento lento y aleatorio propio de cada oscilador,
   en dos bandas (unos 0,1 Hz y 0,4 Hz).

**Escala por octava (#2).** Un ajuste de gusto, no parte del modelo físico:
multiplica todo por `2^(escala × octavas desde C4)`. Con −100% el batido entre
osciladores queda parejo en todo el teclado. Por defecto está en 0 (el modelo
tal cual).

**Límite:** el desvío total nunca pasa de ±49,6 cents.

### Cómo responden los controles

| Control | Efecto |
|---|---|
| 0 | Sin efecto: el sonido queda como en el original |
| 32 | Un instrumento real típico, bien mantenido |
| 64 | El doble de un instrumento típico |
| 65 a 127 | Crece rápido: un instrumento descuidado. A 127 es 19,5 veces lo típico |

## Valores y fuentes

Los valores son a control 32. Tipo: **dato** = sale de una hoja de datos o de
un manual; **derivado** = cálculo a partir de un dato; **supuesto** = no
encontré datos, es una estimación razonable.

| Parámetro | CEM3340 (Prophet-5 rev3, OB-Xa) | SSM2030 (Prophet-5 rev1/2) | Fuente | Tipo |
|---|---|---|---|---|
| Residuo del autotune | ±0,65 c | ±0,65 c | Paso del autotune del Prophet-5, unos 1,3 c ("un poco más de un semitono" en 0–100 cuentas del firmware), según Profit-5; el residuo es medio paso | derivado |
| Error de seguimiento | hasta ±0,75 c/octava (desvío típico 0,3) | hasta ±1,5 c/octava (desvío típico 0,6) | Hoja de datos del AS3340 (clon del CEM3340): error de escala exponencial ajustado 0,05–0,3 %. 0,05 % = 0,6 c/octava. SSM: el doble | CEM derivado, SSM supuesto |
| Reset que queda tras el ajuste de agudos | 20 ns | 150 ns | SSM2030: 500 ns de bajada del diente de sierra (hoja de datos) × 30 % que deja el ajuste HI V/OCT; CEM: 0,2 µs × 10 %. Ambos según Profit-5 | SSM dato + supuesto, CEM supuesto |
| Efecto a 8,4 kHz | −0,3 c | −2,1 c | Calculado; Profit-5 da −0,2 y −1,8 c | derivado |
| Coeficiente de temperatura | ±0,18 c/octava/°C | ±0,36 c/octava/°C | AS3340: compensación de temperatura ±150 ppm/°C = 0,18 c por octava por °C. SSM: el doble | CEM dato, SSM supuesto |
| Temperatura del equipo | desvío típico 1 °C, unos 50 s | igual | Sin datos | supuesto |
| Temperatura de cada voz | desvío típico 0,5 °C, unos 6 s | igual | Sin datos | supuesto |
| Deriva 1/f | 0,9 c de desvío típico | 1,8 c | Profit-5 (1,5 y 3,0 c × su valor por defecto 0,6), forma en bandas de Profit-5 | estimación de otra emulación |

Dónde está cada fuente:

- **AS3340:** hoja de datos de Alfa RPAR, por ejemplo
  [alfatriode.lv](https://alfatriode.lv/eng/sc/AS3340.pdf) o la copia de
  [Synthrotek](https://store.synthrotek.com/assets/images/AS3340-datasheet.pdf).
  No la pude abrir completa (red bloqueada); los valores vienen del resumen
  del buscador. Conviene verificarlos con el PDF.
- **Profit-5:** [sd88me/mpc-vst-profit5](https://github.com/sd88me/mpc-vst-profit5)
  (MIT), `docs/ENGINE.md` y `src/engine.c`. Emulación de un Prophet-5 con SSM,
  que cita la hoja de datos del SSM2030 y el manual de servicio del Prophet-5
  (secciones 3.3 y 3.4). Su autor dice que varias leyes son "estimaciones
  medidas", no una copia calibrada.
- **OB-Xf:** [surge-synthesizer/OB-Xf](https://github.com/surge-synthesizer/OB-Xf)
  (GPL-3). Varía por voz el filtro, las envolventes, el glide y el volumen,
  pero no modela el drift de los osciladores. Solo lo leímos.
- **Surge XT:** su drift es un único ruido filtrado lento por oscilador, con
  la cantidad que elige el usuario. Confirma el enfoque, no aporta números.

No encontré una medición sistemática de un Prophet-5 o un Oberheim real. Para
llegar más cerca habría que medir uno: grabar cada voz en varias octavas
durante 30–60 minutos y sacar estos mismos números. El banco de pruebas de
gipfel_mpe (`tools/hwrig`) ya mide la afinación de cada voz a partir del audio.

## Cómo se aplica dentro del firmware

El firmware original ya suma a cada voz y oscilador un término propio:
`diverge_amount[parte] × diverge_rand[3v + o] >> 5` (en 1/256 de semitono).
El parche usa ese mismo camino en vez de agregar código en cada cálculo de
afinación.

Una vez por milisegundo, después de que el firmware actualiza la modulación
(`mod_tick` → `mod_update(1)`, el mismo punto que usa el MPE), y solo para
una parte cuyo sonido tiene Diverge o Drift por encima de 0:

1. Pone `diverge_amount` en 32. Así, cada entrada de la tabla es exactamente
   el desvío (1/256 de semitono = 0,39 cents, hasta ±127 = ±49,6 cents).
2. Pone `drift_amount` en 0. El Drift de fábrica multiplica por ese valor
   (0x08013876), así que queda en 0.
3. Escribe en la tabla el desvío del modelo: un oscilador por milisegundo
   (cada uno se actualiza cada 48 ms), al instante para una voz que empieza
   una nota nueva, y todas de una vez cuando el sonido pasa de 0 a activo.

El firmware usa esos valores en el ciclo siguiente, también al empezar una
nota. Una parte con los dos controles en 0 no se toca. Con `vintage_off`, se
devuelven la tabla y los valores originales.

### Por qué así, y no enganchando cada cálculo

La primera versión envolvía las 48 llamadas por milisegundo a `osc_pitch`.
Medido en el simulador a la velocidad de procesador que reproduce al Summit
real (0,3 con el costo del bus SPI, el mismo calibrado que usa gipfel_mpe),
eso no alcanzaba:

| Diseño | Ciclos de 1 ms perdidos cada 300 ms (MPE + vintage, controles en 32) |
|---|---|
| Envolver cada `osc_pitch` | 44 (15 %) |
| Escribir la tabla una vez por milisegundo | 0 |

## Seguridad

Las reglas, y cómo se cumplen:

1. **En 0, igual al original.** Con Diverge y Drift en 0, el parche no
   escribe nada. En la PC: 96.000 de 96.000 afinaciones iguales, la tabla y
   los valores sin tocar. En el simulador: igual que el firmware original.
2. **Cero mensajes nuevos al chip de sonido.** El parche no manda nada; el
   firmware manda la afinación como siempre. En el simulador, los mismos
   tipos de mensaje y la misma cantidad que el original.
3. **No toca el manejo de notas** ni las envolventes, y no reemplaza ninguna
   función de afinación: un solo enganche, en el mismo lugar que el MPE.
4. **Todo con límites:** ±127 en la tabla (±49,6 cents).
   `vintage_clamp_hits` cuenta cada vez que actúa el límite; en 30 minutos
   simulados a control 32 quedó en 0.
5. **No cambia cómo se guardan los sonidos ni los settings.**

Además: usa solo enteros y no usa memoria con valor inicial (el armador de
parches la rechaza). Ocupa 1,8 KB de código y 1,1 KB de RAM (hay 64 KB
libres de cada uno). Usa 0,12 % del procesador con los controles en 0 y
0,47 % con los controles en 32.

**Lo que no se puede evitar:** al girar Diverge o Drift mientras suenan notas,
el firmware vuelve a poner sus propios valores durante el ciclo en que cambia
el control, hasta que el parche los corrige un milisegundo después. Puede
dar un salto de afinación de 1–2 ms solo mientras se gira el control.

## Tests

**En la PC** (`tests/host/run.sh`): el código del parche contra un firmware
simulado que sigue el código documentado de `osc_pitch` y `osc_drift_update`.
28 chequeos, todos pasan. Entre ellos:

- Diverge y Drift en 0: nada tocado, idéntico al original (96.000 de 96.000).
- Parche apagado: idéntico al original, aunque los controles estén arriba.
- Apagado mientras estaba activo: vuelven la tabla y los valores originales.
- Cada afinación es la nota más su entrada de la tabla, y el Drift de fábrica
  queda en 0.
- Las 16 voces se mueven cada una por su cuenta (correlación media 0,09).
- Drift 32 en C4 (CEM3340): 0,99 cents de desvío típico.
- Una nota nueva recibe sus valores en el mismo ciclo.
- Modo Multi: una parte con los controles en 0 queda intacta.
- 30 minutos simulados: temperatura y deriva estables, sin usar el límite.

Con `GIPFEL=<carpeta de gipfel_mpe>` también compila para el Cortex-M4 con
los flags del proyecto y verifica que no haya llamadas al chip de sonido, ni
punto flotante, ni librería de C, ni `.data`.

**En el simulador del Summit de gipfel_mpe** (con el firmware oficial 2.2):

- El parche se arma y verifica contra el firmware real, solo y junto al MPE.
- `tests/sim/test_vintage.py`: 11 tests, todos pasan. Incluyen: con los
  controles en 0 idéntico al original; los mismos mensajes al chip de sonido;
  apagado devuelve lo original; menos de 0,5 % de procesador; ningún ciclo
  perdido a la velocidad del Summit real, con MPE y los controles en 32.
- Los tests del propio MPE contra MPE + vintage (`tests/sim/vintage_as_mpe.py`):
  156 pasan; las 3 diferencias son la etiqueta de versión, que el build
  cambia a propósito a "MPV1".

**Límite del simulador:** el Drift de fábrica no se mueve nunca en el
simulador (su fuente de números al azar da 0 ahí), así que no se puede
comparar contra él. Que el parche lo apague se probó en la PC, con un
firmware simulado que sigue el código real de `osc_drift_update`.

**Lo que todavía no se probó:** el equipo real.

## Filter Diverge

Confirmado con el firmware y el simulador:

- Es el parámetro **FltDiverge**: byte 0x08B del sonido, NRPN 0:48, de 0 a 127.
- El firmware manda un valor por voz al chip de sonido (registro 0x4F),
  **solo cuando cambia el parámetro**. No lo vuelve a mandar en cada nota y
  no se mueve con el tiempo.
- El valor es un centro más la cantidad por un factor fijo de cada voz. Las
  16 voces tienen factores distintos, pero **alternan**: una más brillante,
  la siguiente más oscura. No es al azar.
- No hay deriva del filtro.

**¿Hace falta mejorarlo?** No es prioridad: las diferencias de filtro se
escuchan mucho menos que las de afinación. Si se hace, el camino seguro es el
mismo que acá: encontrar la tabla de factores en el firmware y cambiarla por
valores al azar con la dispersión de un equipo real (Profit-5: ±3 % de octava
en CEM, ±6 % en SSM). Eso no agrega mensajes. Una deriva lenta del filtro sí
necesitaría mensajes nuevos al chip de sonido (unos pocos por segundo).

## Base para las mejoras siguientes

El modelo ya genera, al arrancar, valores aleatorios por voz que todavía no
se usan, para que las próximas mejoras no cambien el carácter que ya existe
(`struct vintage_voice`: `env_u[3]`, `level_u`, `cutoff_u`). Los perfiles ya
tienen la dispersión de envolventes y de filtro de cada familia de chips.

- **#5 Voces únicas + error por octava:** hecho como parte del Diverge.
- **#3 Envolventes por voz.** Dato: dispersión de tiempos entre voces de 8 %
  en el Prophet-5 rev1/2 y 3 % en CEM (Profit-5, según el manual de servicio
  3.4). Falta encontrar cómo recibe el chip de sonido los tiempos de cada
  envolvente. Lo aprendido acá aplica: buscar primero si el firmware ya
  tiene un valor por voz que se pueda aprovechar, antes de agregar código o
  mensajes.
- **#4 Volumen y brillo por voz.** La velocity se manda una vez por nota
  (`0x66`, valor `vel << 8`, observado). El plan seguro: en ese único envío,
  sumar un desvío chico por voz (`level_u`) y limitarlo siempre entre 1 y 127.
  Falta ubicar ese envío en `voice_alloc` y probar qué cambia en el sonido.

## Próximos pasos

1. **Una página en Settings** para elegir el modelo (Original, CEM3340,
   SSM2030), la escala por octava y apagar el parche.
2. **Probarlo en el equipo** con el banco de pruebas, siguiendo las reglas de
   gipfel_mpe (`docs/hardware.md`): solo con una imagen armada y verificada
   por `scripts/build-image.sh` en su entorno con el compilador fijado.
3. Después, #4 y #3.
