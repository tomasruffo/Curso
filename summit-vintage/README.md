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

**Estado:** armado y verificado contra el firmware oficial 2.2. Pasa 28 tests
en la PC, 11 en el simulador del Summit de gipfel_mpe, y los tests del propio
MPE contra MPE + vintage (156 pasan; las 3 diferencias son la etiqueta de
versión). No pierde ningún ciclo de modulación a la velocidad de procesador
calibrada como la del Summit real. **Nunca** se instaló en un equipo: no lo
instales todavía (ver "Próximos pasos" en [docs/modelo.md](docs/modelo.md)).

El modelo, los números con sus fuentes, cómo se aplica, las mediciones y la
base para las mejoras siguientes están en [docs/modelo.md](docs/modelo.md).

## Archivos

| Archivo | Qué es |
|---|---|
| `patches/vintage/vintage.h` | Interfaz y estructuras del modelo |
| `patches/vintage/vintage_model.c` | El modelo: carácter, deriva y desvío. No toca el firmware |
| `patches/vintage/vintage_hooks.c` | La tarea de cada milisegundo: escribe el modelo en la tabla de Diverge del firmware |
| `patches/vintage/vintage_inner_stock.c` | El enganche para el parche solo (llama a `mod_update`) |
| `patches/vintage/vintage_inner_mpe.c` | El enganche junto al MPE (llama a `mpe_mod_update`) |
| `patches/vintage/patch.py` | Definición del parche solo (etiqueta `VNT1`) |
| `patches/vintage/with_mpe.py` | Definición MPE + vintage (etiqueta `MPV1`) |
| `tests/host/` | Tests en la PC y chequeo de compilación para el Summit |
| `tests/sim/test_vintage.py` | Tests en el simulador de gipfel_mpe |
| `tests/sim/vintage_as_mpe.py` | Plugin para correr los tests del MPE contra MPE + vintage |

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

En el simulador: copiar `patches/vintage` a `gipfel_mpe/patches/vintage` y
`tests/sim/*.py` a `gipfel_mpe/tests/`, bajar el firmware oficial con
`scripts/fetch-firmware.sh` y, desde la carpeta de gipfel_mpe:

```bash
python3 -m pytest tests/test_vintage.py
```

```bash
PYTHONPATH=tests:. python3 -m pytest -p vintage_as_mpe tests/test_mpe_*.py
```
