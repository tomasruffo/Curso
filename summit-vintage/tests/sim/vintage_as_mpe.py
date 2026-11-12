"""pytest plugin: run the MPE tests against MPE + vintage (patches/vintage/with_mpe.py).

    python -m pytest -p vintage_as_mpe tests/test_mpe_*.py

With Diverge and Drift at 0 (the Init Patch) the vintage wrappers pass every
call through, so every MPE test should pass as on MPE alone, except the ones
that read the version label (MPV1 instead of MPE3).
"""

import mpe_sim

mpe_sim.MPE = mpe_sim.ROOT / "patches" / "vintage" / "with_mpe.py"
