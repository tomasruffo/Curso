# Modelo vintage de osciladores: Diverge y Drift

Este documento explica qué hace el parche `vintage`, en qué datos se basa
cada número y qué falta para las mejoras siguientes (#3, #4, #5 y el filtro).

## Qué cambia

En el Summit original, los controles **Diverge** y **Drift** de cada sonido
hacen esto (sacado del firmware, `docs/findings` de gipfel_mpe):

- **Diverge:** suma a cada oscilador un desvío fijo de una tabla de solo 24
  valores. Las voces 9 a 16 repiten los valores de las voces 1 a 8.
- **Drift:** una sola curva al azar por parte y por oscilador, compartida por
  todas las voces. Todo el acorde sube y baja junto.
- Los dos son una fracción fija de semitono: los mismos cents en todas las
  octavas.

Con el parche, esos dos controles manejan un modelo de un oscilador analógico
real (clase Prophet-5 / OB-Xa). Si un sonido tiene Diverge y Drift en 0,
suena exactamente igual que en el original.

## El modelo

Para cada voz `v` y oscilador `o`, en cents:

**Parte fija (control Diverge).** Son los errores de calibración que quedan
para siempre en cada oscilador:

1. **Residuo del autotune:** un desvío fijo, distinto en cada oscilador.
2. **Error de seguimiento (tracking):** cada oscilador tiene una escala de
   volt/octava apenas distinta, así que el error crece a medida que te alejás
   de C4, para arriba y para abajo. Esto es la mejora #5.
3. **Agudos bemoles:** el oscilador tarda un tiempo fijo en reiniciar cada
   ciclo (el "reset"), así que en las notas agudas cada ciclo dura un poco más
   y la nota baja. El efecto crece con la frecuencia: casi nada en los graves,
   notable arriba.

**Parte que se mueve (control Drift).** Son los cambios mientras tocás:

4. **Temperatura:** una temperatura de todo el equipo que cambia muy despacio
   (unos 65 s) más una temperatura propia de cada voz (unos 8 s). Cada
   oscilador reacciona distinto (su coeficiente de temperatura), y el efecto
   crece cuanto más aguda es la nota, porque la temperatura cambia la escala
   del conversor exponencial.
5. **Deriva 1/f:** un movimiento lento y aleatorio propio de cada oscilador,
   en dos bandas (unos 0,08 Hz y 0,6 Hz).

**Escala por octava (#2).** Un ajuste de gusto, no parte del modelo físico:
multiplica todo por `2^(escala × octavas desde C4)`. Con −100% el batido entre
osciladores queda parejo en todo el teclado. Por defecto está en 0 (el modelo
tal cual).

**Límite:** el desvío total nunca pasa de ±50 cents.

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
| Temperatura del equipo | desvío típico 1 °C, unos 65 s | igual | Sin datos | supuesto |
| Temperatura de cada voz | desvío típico 0,5 °C, unos 8 s | igual | Sin datos | supuesto |
| Deriva 1/f | 0,9 c de desvío típico | 1,8 c | Profit-5 (1,5 y 3,0 c × su valor por defecto 0,6), forma en bandas de Profit-5 | estimación de otra emulación |

Dónde está cada fuente:

- **AS3340:** hoja de datos de Alfa RPAR, por ejemplo
  [alfatriode.lv](https://alfatriode.lv/eng/sc/AS3340.pdf) o la copia de
  [Synthrotek](https://store.synthrotek.com/assets/images/AS3340-datasheet.pdf).
  No la pude abrir completa desde esta sesión (red bloqueada); los valores
  vienen del resumen del buscador. Conviene verificarlos con el PDF.
- **Profit-5:** [sd88me/mpc-vst-profit5](https://github.com/sd88me/mpc-vst-profit5)
  (MIT), `docs/ENGINE.md` y `src/engine.c`. Es una emulación de un Prophet-5
  con SSM, que cita la hoja de datos del SSM2030 y el manual de servicio del
  Prophet-5 (secciones 3.3 y 3.4). Su autor dice que varias leyes son
  "estimaciones medidas", no una copia calibrada.
- **OB-Xf:** [surge-synthesizer/OB-Xf](https://github.com/surge-synthesizer/OB-Xf)
  (GPL-3). Varía por voz el filtro, las envolventes, el glide y el volumen
  (25 % por defecto), pero no modela el drift de los osciladores. Solo lo
  leímos; no se copió código.

No encontré una medición sistemática de un Prophet-5 o un Oberheim real. Para
llegar más cerca, el paso siguiente sería medir uno: grabar cada voz en varias
octavas durante 30–60 minutos y sacar estos mismos números. El banco de
pruebas de gipfel_mpe (`tools/hwrig`) ya mide la afinación de cada voz en cents
a partir del audio.

## Seguridad

Las cinco reglas, y cómo se cumplen:

1. **En 0, igual al original.** Con Diverge y Drift en 0 (o el parche
   apagado), el código hace la llamada original y nada más. El test compara
   96.000 afinaciones contra el original: todas iguales.
2. **Cero mensajes nuevos al chip de sonido.** Solo cambia la afinación de los
   osciladores, que el firmware ya manda cada 2 ms. El código no llama a
   ninguna función del chip de sonido (el script lo verifica).
3. **No toca el manejo de notas:** ni el reparto de voces, ni el glide, ni las
   envolventes.
4. **Todo con límites:** ±50 cents de desvío, el rango propio de `osc_pitch`,
   y un número de oscilador inesperado vuelve al original.
   `vintage_clamp_hits` cuenta cada vez que actúa un límite; en 30 minutos
   simulados a control 32 quedó en 0.
5. **No cambia cómo se guardan los sonidos ni los settings.**

Además: usa solo enteros, no usa memoria con valor inicial (el armador de
parches la rechaza), ocupa 1,3 KB de código y 1 KB de RAM (hay 64 KB libres
de cada uno). Estimo menos de 3 % del tiempo de cada ciclo de 1 ms.

Para no tocar los archivos del mod MPE, el parche envuelve las funciones del
MPE en vez de reemplazarlas: primero corre la afinación del MPE (con su
pitch bend por nota) y después suma el desvío del modelo.

## Tests

`tests/host/run.sh` compila el código del parche en la PC, con un reemplazo de
`osc_pitch` que sigue la fórmula documentada del firmware, y corre 25
chequeos. Resultado actual: todos pasan.

- Diverge y Drift en 0: idéntico al original (96.000 de 96.000).
- Parche apagado: idéntico al original.
- Los valores originales de Diverge y Drift se restauran después de cada llamada.
- Las voces 9 a 16 tienen su propio carácter.
- Las 16 voces se mueven cada una por su cuenta (correlación media 0,06).
- Drift 32 en C4 (CEM3340): 0,95 cents de desvío típico.
- El Diverge se abre más lejos de C4: 0,41 c en C4, 1,06 c en C7.
- A 8,4 kHz baja 0,32 c (CEM) y 2,06 c (SSM), cerca de Profit-5.
- Escala −100%: la mitad una octava arriba, el doble una octava abajo.
- Modo Multi: cada parte usa los controles de su propio sonido.
- Una nota nueva no adelanta la deriva y empieza con la misma afinación.
- Valores extremos: nunca pasa de ±50 c ni del rango de `osc_pitch`.
- 30 minutos simulados: temperatura y deriva estables, sin límites usados.

Con `GIPFEL=<carpeta de gipfel_mpe>` también compila para el Cortex-M4 con los
mismos flags del proyecto y verifica que no haya llamadas al chip de sonido,
ni funciones de punto flotante, ni librería de C, ni `.data`.

**Lo que todavía no se probó:** el armado contra el firmware real, el
simulador del Summit de gipfel_mpe y el equipo real.

## Filter Diverge

- El mapa del firmware de gipfel_mpe no lo cubre. El único Diverge mapeado es
  el de los osciladores (byte `+0x2B` del sonido, NRPN 0:9), que solo usa
  `osc_pitch`.
- Una guía de MusicRadar sobre el Peak (mismo motor) dice que hay un Diverge
  que le da a cada voz un cutoff un poco distinto, para imitar los filtros
  viejos. Si es así, es un desvío **fijo** por voz.
- La tabla de parámetros del Summit (420 nombres) está dentro del firmware;
  con el archivo oficial se puede confirmar en minutos cómo se llama, qué byte
  usa y si lo calcula el procesador principal o el chip de sonido.
- **¿Hace falta mejorarlo?** Probablemente no es prioridad. Las diferencias de
  cutoff se escuchan mucho menos que las de afinación. Profit-5 usa ±3 % de
  octava fijo (CEM) a ±6 % (SSM), más una deriva de 0,6–1,2 % de octava. Si el
  Filter Diverge ya da un desvío fijo de ese orden, lo único que faltaría es
  la deriva lenta del filtro.

## Base para las mejoras siguientes

El modelo ya genera, al arrancar, valores aleatorios por voz que todavía no
se usan, para que las próximas mejoras no cambien el carácter que ya existe
(`struct vintage_voice`: `env_u[3]`, `level_u`, `cutoff_u`). Los perfiles ya
tienen la dispersión de envolventes y de filtro de cada familia de chips.

- **#5 Voces únicas + error por octava:** ya quedó hecho como parte del
  Diverge (residuo del autotune + error de seguimiento, distinto en las 48
  combinaciones de voz y oscilador).
- **#3 Envolventes por voz.** Dato: dispersión de tiempos entre voces de 8 %
  en el Prophet-5 rev1/2 y 3 % en CEM (Profit-5, según el manual de servicio
  3.4). Falta encontrar cómo recibe el chip de sonido los tiempos de cada
  envolvente: hoy solo se sabe que al tocar una nota se mandan comandos de
  envolvente (`0x3F/0x42/0x45`) y que el reparto de voces lee el estado de las
  envolventes. Hace falta el firmware y Ghidra para ubicarlo. Riesgo alto
  hasta entenderlo.
- **#4 Volumen y brillo por voz.** La velocity se manda una vez por nota
  (`0x66`, valor `vel << 8`, observado). El plan seguro: en ese único envío,
  sumar un desvío chico por voz (`level_u`) y limitarlo siempre entre 1 y 127.
  Falta ubicar la dirección exacta de ese envío en `voice_alloc` (con el
  firmware) y probar en el equipo qué cambia. Solo se nota en sonidos que usan
  velocity.

## Próximos pasos

1. **Probarlo en el simulador del Summit de gipfel_mpe.** Hace falta permitir
   en esta sesión ejecutar el código de ese proyecto y habilitar la descarga
   del firmware oficial desde Novation (hoy la red de la sesión la bloquea).
   Ahí se arma el parche contra el firmware real y se escriben tests como los
   del MPE.
2. **Una página en Settings** para elegir el modelo (Original, CEM3340,
   SSM2030), la escala por octava y apagar el parche.
3. **Probarlo en el equipo** con el banco de pruebas, siguiendo las reglas de
   gipfel_mpe (`docs/hardware.md`), solo con una imagen armada y verificada
   por `scripts/build-image.sh`.
