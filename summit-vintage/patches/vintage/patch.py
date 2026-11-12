"""Vintage oscillator model on its own, without MPE (summit-vintage/docs/modelo.md).

The sound's Diverge and Drift knobs drive a model of real analog VCOs
(Prophet-5 / OB-Xa class) instead of stock's fixed table and shared walk.
With both knobs at 0 a sound plays exactly as stock.

  bl hook:     mod_tick's mod_update(1) -> vintage_mod_update: mod_update(1),
               then once per tick the model's offsets into stock's own
               per-voice table (diverge_rand), vintage_hooks.c
  byte patches: version labels "VNT1"

For MPE and the model together use with_mpe.py instead: MPE hooks the same
mod_update(1) call.
"""

SOURCE = "summit-firmware-2.2-build2121.syx"
NAME = "vintage"

PATCHES = [
    (0x0804C3B7, b" Version ", b"VNT1 Ver ", "boot screen label (.data initialiser of RAM 0x20000637)"),
    (0x0804B3E4, b"Version\x00", b"VNT1Ver\x00", "Settings 2/33 SYSTEM item name"),
]

SOURCES = ["vintage_model.c", "vintage_hooks.c", "vintage_inner_stock.c"]

MOD_UPDATE = 0x080140C4

# (kind, site, expected original, patch symbol, why); the site is the one
# patches/mpe/patch.py hooks with mpe_mod_update.
HOOKS = [
    ("bl", 0x0801457E, MOD_UPDATE, "vintage_mod_update", "mod_tick -> mod_update(1), last part update of the tick"),
]
