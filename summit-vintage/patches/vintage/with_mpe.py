"""MPE (patches/mpe, unchanged) plus the vintage oscillator model.

Takes the MPE definition as it is and points its six osc_pitch hooks at the
vintage wrappers, which call MPE's own wrappers inside (vintage_inner_mpe.c):
per-note bend and the rest of MPE work as before, the model's offset goes on
top. Only the version labels change, to "MPV1", so the boot screen shows
which build is on the synth.
"""

import importlib.util
from pathlib import Path

_path = Path(__file__).resolve().parent.parent / "mpe" / "patch.py"
_spec = importlib.util.spec_from_file_location("patchdef_mpe_for_vintage", _path)
_mpe = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_mpe)

SOURCE = _mpe.SOURCE
NAME = "mpe-vintage"

_LABELS = {b"MPE3 Ver ": b"MPV1 Ver ", b"MPE3Ver\x00": b"MPV1Ver\x00"}
PATCHES = [(site, old, _LABELS.get(new, new), *rest) for (site, old, new, *rest) in _mpe.PATCHES]

SOURCES = [f"../mpe/{s}" for s in _mpe.SOURCES] + [
    "vintage_model.c", "vintage_hooks.c", "vintage_inner_mpe.c"]

_RETARGET = {"mpe_osc_pitch_tick": "vintage_osc_pitch_tick",
             "mpe_osc_pitch_alloc": "vintage_osc_pitch_alloc"}
HOOKS = [(kind, site, expected, _RETARGET.get(sym, sym), why)
         for (kind, site, expected, sym, why) in _mpe.HOOKS]

# The MPE definition must still have exactly the six osc_pitch hooks we take over.
assert sum(h[3] in _RETARGET.values() for h in HOOKS) == 6, "MPE's osc_pitch hooks changed"
assert sum(new != _LABELS.get(new, new) for (_, _, new, *_) in _mpe.PATCHES) == 2, "MPE's labels changed"
