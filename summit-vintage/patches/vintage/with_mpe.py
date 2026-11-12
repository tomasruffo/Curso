"""MPE (patches/mpe, unchanged) plus the vintage oscillator model.

Takes the MPE definition as it is and points its one mod_update(1) hook at
vintage_mod_update, which calls MPE's mpe_mod_update first and then does the
vintage work (vintage_inner_mpe.c). Every other MPE hook stays as it is.
Only the version labels change, to "MPV1", so the boot screen shows which
build is on the synth.
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

_RETARGET = {"mpe_mod_update": "vintage_mod_update"}
HOOKS = [(kind, site, expected, _RETARGET.get(sym, sym), why)
         for (kind, site, expected, sym, why) in _mpe.HOOKS]

# The MPE definition must still have exactly the one hook we take over.
assert sum(h[3] in _RETARGET.values() for h in HOOKS) == 1, "MPE's mod_update(1) hook changed"
assert sum(new != _LABELS.get(new, new) for (_, _, new, *_) in _mpe.PATCHES) == 2, "MPE's labels changed"
