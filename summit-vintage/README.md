# summit-vintage

Un parche para el firmware del Novation Summit, pensado para usarse junto al
mod [gipfel_mpe](https://github.com/michaelkollmann/gipfel_mpe). Hace que los
controles **Diverge** y **Drift** de cada sonido manejen un modelo de
osciladores analógicos reales (clase Prophet-5 / OB-Xa), en vez de la tabla
fija y la deriva compartida del firmware original:

- **Drift independiente por voz (#1):** cada voz y cada oscilador se mueven
  por su cuenta, por temperatura y por una deriva lenta propia.
- **Escala por octava (#2):** un ajuste para emparejar el batido en todo el
  teclado (por defecto apagado).
- **Voces únicas y error por octava (#5):** las 16 voces tienen su propio
  carácter, y el error crece al alejarse de C4, como en un oscilador real.

Con Diverge y Drift en 0, un sonido queda exactamente como en el original.

**Estado:** el código compila para el Summit y pasa 25 tests propios en la PC.
**No** se armó todavía contra el firmware real, **no** se probó en el
simulador de gipfel_mpe y **nunca** se instaló en un equipo. No lo instales
hasta que pase esas pruebas.

El modelo, los números con sus fuentes, lo que es supuesto y la base para las
mejoras siguientes están en [docs/modelo.md](docs/modelo.md).

## Archivos

| Archivo | Qué es |
|---|---|
| `patches/vintage/vintage.h` | Interfaz y estructuras del modelo |
| `patches/vintage/vintage_model.c` | El modelo: carácter, deriva y desvío. No toca el firmware |
| `patches/vintage/vintage_hooks.c` | El enganche en las 6 llamadas a `osc_pitch` |
| `patches/vintage/vintage_inner_stock.c` | Llamada interna para usar el parche solo |
| `patches/vintage/vintage_inner_mpe.c` | Llamada interna para usarlo junto al MPE |
| `patches/vintage/patch.py` | Definición del parche solo (etiqueta `VNT1`) |
| `patches/vintage/with_mpe.py` | Definición MPE + vintage (etiqueta `MPV1`) |
| `tests/host/` | Tests en la PC y chequeo de compilación para el Summit |

## Cómo probarlo

Tests en la PC (necesita `gcc`):

```bash
tests/host/run.sh
```

Además, compilar para el Summit con los flags del proyecto (necesita
`arm-none-eabi-gcc` y una copia de gipfel_mpe):

```bash
GIPFEL=/ruta/a/gipfel_mpe tests/host/run.sh
```

Para armarlo dentro de gipfel_mpe, copiar `patches/vintage` a
`gipfel_mpe/patches/vintage` y usar sus herramientas, por ejemplo:

```bash
scripts/build-image.sh patches/vintage/with_mpe.py
```
