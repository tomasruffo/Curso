"""Vintage oscillator model on its own, without MPE (summit-vintage/docs/modelo.md).

The sound's Diverge and Drift knobs drive a model of real analog VCOs
(Prophet-5 / OB-Xa class) instead of stock's fixed table and shared walk.
With both knobs at 0 a sound plays exactly as stock.

  bl hooks x6: osc_pitch calls in mod_tick and voice_alloc -> vintage wrappers
  byte patches: version labels "VNT1"

For MPE and the model together use with_mpe.py instead: both patches hook
the same six calls.
"""

SOURCE = "summit-firmware-2.2-build2121.syx"
NAME = "vintage"

PATCHES = [
    (0x0804C3B7, b" Version ", b"VNT1 Ver ", "boot screen label (.data initialiser of RAM 0x20000637)"),
    (0x0804B3E4, b"Version\x00", b"VNT1Ver\x00", "Settings 2/33 SYSTEM item name"),
]

SOURCES = ["vintage_model.c", "vintage_hooks.c", "vintage_inner_stock.c"]

OSC_PITCH = 0x08013A2C

# (kind, site, expected original, patch symbol, why); sites from patches/mpe/patch.py
HOOKS = [
    ("bl", 0x08014526, OSC_PITCH, "vintage_osc_pitch_tick", "mod_tick: osc_pitch(osc1)"),
    ("bl", 0x08014530, OSC_PITCH, "vintage_osc_pitch_tick", "mod_tick: osc_pitch(osc2)"),
    ("bl", 0x0801453A, OSC_PITCH, "vintage_osc_pitch_tick", "mod_tick: osc_pitch(osc3)"),
    ("bl", 0x08016F66, OSC_PITCH, "vintage_osc_pitch_alloc", "voice_alloc: osc_pitch(osc1)"),
    ("bl", 0x08016F72, OSC_PITCH, "vintage_osc_pitch_alloc", "voice_alloc: osc_pitch(osc2)"),
    ("bl", 0x08016F7C, OSC_PITCH, "vintage_osc_pitch_alloc", "voice_alloc: osc_pitch(osc3)"),
]
