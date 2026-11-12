"""The vintage oscillator model in the simulator (patches/vintage). Emulated.

The stock image and the patch get the same input. Diverge is NRPN 0:9 and
Drift NRPN 0:10 (patch +0x2B / +0x2C, 0-127, read from patch_param_desc);
stock applies a change about 20 ms after it arrives, so knobs() waits 40.

The patch writes the model's offsets into stock's own per-voice table
(diverge_rand) once per tick, with diverge_amount 32 and drift_amount 0 for
a part whose sound has Diverge or Drift above 0 (patches/vintage/
vintage_hooks.c). What is checked:

* Diverge and Drift at 0: every oscillator pitch exactly as stock.
* Diverge: the model replaces stock's table values (small, per oscillator).
* Drift: each voice moves on its own. (Stock's drift doesn't move at all in
  the simulator: its random source reads 0 here, so it can't be compared.)
* No FPGA write of its own; switched off, stock's table and amounts back.
* CPU: a fraction of a percent, and no tick lost at the synth's CPU rate,
  with MPE too, where the per-call design lost 44 of 300.
* Limits at the extremes, Multi mode, and MPE's per-note bend with the model.
"""

import collections
import struct

import pytest

from mpe_expr_sim import member_offset, osc
from mpe_sim import ROOT, Mpe, stock_image, stock_summit, summit  # also puts tools/ on sys.path

import patch  # noqa: E402
import patch_build  # noqa: E402

VINTAGE = ROOT / "patches" / "vintage" / "patch.py"
WITH_MPE = ROOT / "patches" / "vintage" / "with_mpe.py"
MPE = ROOT / "patches" / "mpe" / "patch.py"
CENT = 4096 / 1200
OSC_MIN, OSC_MAX = -43691, 43689
CHORD = (48, 55, 60, 64, 67, 72)
DIVERGE_AMOUNT, DRIFT_AMOUNT, DIVERGE_RAND = 0x20013898, 0x20014B04, 0x200007CC
TICK_PHASE, AFTER_MOD_UPDATE_1 = 0x2000577C, 0x08014582

_cache = {}


def booted(definition, tmp_path_factory):
    """A SimulatedSummit running the definition's build, reset."""
    if definition not in _cache:
        stock_image()
        if not patch_build.available():
            pytest.skip("arm-none-eabi-gcc not installed")
        b = patch.build_image(definition, build_dir=tmp_path_factory.mktemp(definition.parent.name + "-" + definition.stem))
        _cache[definition] = (summit(b.patched, flash_from=stock_image()), b.blob)
    s, blob = _cache[definition]
    s.reset()
    return s, blob


@pytest.fixture
def stock():
    s = stock_summit()
    s.reset()
    return s


@pytest.fixture
def vint(tmp_path_factory):
    return booted(VINTAGE, tmp_path_factory)[0]


def knobs(s, diverge, drift, channel=1):
    s.set_cc_nrpn_receive(True)
    s.nrpn(0, 9, diverge, channel=channel)
    s.nrpn(0, 10, drift, channel=channel)
    s.tick(40)


def chord(s, notes=CHORD, ms=40, channel=1):
    for n in notes:
        s.note_on(n, channel=channel)
    s.tick(ms)


def by_note(s, voices=None):
    """Note -> (Osc 1, Osc 2, Osc 3) pitch of each sounding voice."""
    return {s.voice_note(v): osc(s, v) for v in (voices if voices is not None else s.active_voices())}


def base(s, notes=CHORD):
    """The pitches with Diverge and Drift at 0, on this image."""
    s.reset()
    knobs(s, 0, 0)
    chord(s, notes)
    out = by_note(s)
    s.reset()
    return out


def table(s):
    return list(struct.unpack("<48b", s.board.read(DIVERGE_RAND, 48)))


# -- identity ---------------------------------------------------------------------------


def test_boot_screen_shows_the_build(vint, tmp_path_factory):
    assert vint.boot_screen()[3].strip().startswith("VNT1 Ver")
    s, _ = booted(WITH_MPE, tmp_path_factory)
    assert s.boot_screen()[3].strip().startswith("MPV1 Ver")


def test_knobs_at_zero_play_exactly_as_stock(stock, vint):
    for s in (stock, vint):
        knobs(s, 0, 0)
        chord(s)
    assert by_note(vint) == by_note(stock)
    assert table(vint) == table(stock)
    for s in (stock, vint):
        s.bend(6000)
        s.tick(60)
    assert by_note(vint) == by_note(stock)


# -- Diverge ------------------------------------------------------------------------------


def test_diverge_is_the_model_not_stocks_table(stock, vint):
    ref = base(stock)
    assert base(vint) == ref
    offsets = {}
    for name, s in (("stock", stock), ("vintage", vint)):
        knobs(s, 32, 0)
        chord(s)
        got = by_note(s)
        offsets[name] = {n: tuple(a - b for a, b in zip(got[n], ref[n])) for n in CHORD}
    assert vint.board.read(DIVERGE_AMOUNT, 1)[0] == 32
    model = [x for o in offsets["vintage"].values() for x in o]
    assert offsets["vintage"] != offsets["stock"]
    assert all(abs(x) <= 10 * CENT for x in model)          # a real instrument: cents, not tens
    assert sum(x != 0 for x in model) >= len(model) // 2   # but it moves them
    # The three oscillators of a voice differ (a step is 0.39 c, so two can round alike).
    assert sum(len(set(o)) > 1 for o in offsets["vintage"].values()) >= len(CHORD) - 2


# -- Drift --------------------------------------------------------------------------------


def osc1_deltas(s, notes=(48, 55, 60, 64), hold_ms=800):
    chord(s, notes)
    v = {s.voice_note(x): x for x in s.active_voices()}
    first = {n: osc(s, v[n])[0] for n in notes}
    s.tick(hold_ms)
    return [osc(s, v[n])[0] - first[n] for n in notes]


def test_drift_moves_each_voice_on_its_own(stock, vint):
    knobs(stock, 0, 64)
    knobs(vint, 0, 64)
    assert struct.unpack("<H", vint.board.read(DRIFT_AMOUNT, 2))[0] == 0   # stock's shared drift off
    d_stock = osc1_deltas(stock)
    d_vint = osc1_deltas(vint)
    assert d_stock == [0, 0, 0, 0]                 # stock's drift: no random source in the simulator
    assert max(d_vint) - min(d_vint) >= 3, d_vint  # the model: each voice its own way


# -- the FPGA bus, switching off ---------------------------------------------------------


def writes(s, since):
    return [e for e in s.fpga_events() if e.time_ms >= since]


def test_no_fpga_writes_of_its_own(stock, vint):
    seen = {}
    for name, s in (("stock", stock), ("vintage", vint)):
        knobs(s, 32, 32)
        t = s.time_ms
        chord(s, ms=300)
        w = writes(s, t)
        seen[name] = (len(w), {(e.target, e.param) for e in w}, sum(e.target < 0x10 for e in w))
    (n_stock, kinds_stock, voice_stock), (n_vint, kinds_vint, voice_vint) = seen["stock"], seen["vintage"]
    assert kinds_vint == kinds_stock
    assert abs(voice_vint - voice_stock) <= max(3, voice_stock // 200), (voice_vint, voice_stock)
    assert abs(n_vint - n_stock) <= max(3, n_stock // 100), (n_vint, n_stock)


def test_switched_off_puts_stock_back(stock, tmp_path_factory):
    s, blob = booted(VINTAGE, tmp_path_factory)
    stock_table = table(stock)
    knobs(s, 32, 32)
    chord(s)
    assert table(s) != stock_table
    s.board.write(blob.address("vintage_off"), b"\x01")
    s.tick(5)
    assert table(s) == stock_table
    assert s.board.read(DIVERGE_AMOUNT, 1)[0] == 32                      # the knob's own value
    assert struct.unpack("<H", s.board.read(DRIFT_AMOUNT, 2))[0] == 32


# -- CPU ----------------------------------------------------------------------------------


def blob_instructions_per_ms(s, blob, bend=False, ms=200):
    """Instructions executed inside the patch blob, per millisecond (the
    simulator's budget is 120,000 per millisecond)."""
    from unicorn import UC_HOOK_CODE

    count = [0]

    def hook(uc, address, size, data):
        count[0] += 1

    lo = blob.origin
    h = s.board.uc.hook_add(UC_HOOK_CODE, hook, begin=lo, end=lo + len(blob.data) - 1)
    try:
        t = s.time_ms
        for k in range(ms // 10):
            if bend:
                s.bend(8191 if k % 2 else -8192)
            s.tick(10)
        return count[0] / (s.time_ms - t)
    finally:
        s.board.uc.hook_del(h)


def test_cpu_is_a_fraction_of_a_percent(tmp_path_factory):
    s, blob = booted(VINTAGE, tmp_path_factory)
    chord(s)
    idle = blob_instructions_per_ms(s, blob)
    s.reset()
    knobs(s, 32, 32)
    chord(s)
    held = blob_instructions_per_ms(s, blob)
    bending = blob_instructions_per_ms(s, blob, bend=True)
    # Measured 2026-11-12: 0.12 %, 0.47 %, about the same bending.
    assert idle < 0.005 * 120000, idle
    assert held < 0.01 * 120000, held
    assert bending < 0.01 * 120000, bending


def ticks_and_phases(s, ms=300):
    """mod_tick runs in ms simulated, and the tick phase after mod_update(1)."""
    from unicorn import UC_HOOK_CODE

    seen = collections.Counter()

    def hit(uc, _a, _s, _u):
        seen[uc.mem_read(TICK_PHASE, 1)[0]] += 1

    h = s.board.uc.hook_add(UC_HOOK_CODE, hit, begin=AFTER_MOD_UPDATE_1, end=AFTER_MOD_UPDATE_1)
    try:
        t = s.time_ms
        s.tick(ms)
        return sum(seen.values()), round(s.time_ms - t), seen
    finally:
        s.board.uc.hook_del(h)


@pytest.mark.slow
def test_no_tick_lost_at_the_synths_cpu_rate_with_mpe(tmp_path_factory):
    """At the CPU rate that reproduces the synth (0.3 with the SPI cost,
    tests/test_mpe_slide_timing.py), MPE + vintage with both knobs up keeps
    every 1 kHz tick, as MPE alone does."""
    for definition in (MPE, WITH_MPE):
        s, _ = booted(definition, tmp_path_factory)
        s.set_timing(0.3, spi_cost=True)
        knobs(s, 32, 32)
        chord(s, ms=20)
        ticks, ms, phases = ticks_and_phases(s)
        s.set_timing(1.0)
        assert ticks >= ms - 1, (definition.name, ticks, ms, dict(phases))
        assert max(phases) <= 9 and min(phases) >= 5, (definition.name, dict(phases))  # no tick runs late into the next


# -- limits -------------------------------------------------------------------------------


def test_extreme_settings_stay_within_50_cents_and_range(vint):
    notes = (24, 36, 96, 108)
    ref = base(vint, notes)
    knobs(vint, 127, 127)
    chord(vint, notes, ms=300)
    got = by_note(vint)
    for n in notes:
        for a, b in zip(got[n], ref[n]):
            assert OSC_MIN <= a <= OSC_MAX
            assert abs(a - b) <= 50 * CENT + 1, (n, a - b)


# -- Multi mode ---------------------------------------------------------------------------


def test_multi_each_part_reads_its_own_knobs(stock, vint):
    out = {}
    for name, s in (("stock", stock), ("vintage", vint)):
        s.set_mode("multi")
        _, ch_a, ch_b = s.channels
        knobs(s, 0, 0, channel=ch_a)
        knobs(s, 32, 32, channel=ch_b)
        s.note_on(60, channel=ch_a)
        s.note_on(64, channel=ch_a)
        s.note_on(60, channel=ch_b)
        s.tick(60)
        part_a = [v for v in s.active_voices() if v < 8]
        part_b = [v for v in s.active_voices() if v >= 8]
        out[name] = (by_note(s, part_a), by_note(s, part_b), table(s)[:24])
    assert out["vintage"][0] == out["stock"][0]   # Part A, knobs 0: as stock
    assert out["vintage"][2] == out["stock"][2]   # and its table entries untouched
    assert out["vintage"][1] != out["stock"][1]   # Part B, knobs 32: the model


# -- with MPE -----------------------------------------------------------------------------


def test_mpe_member_bend_still_lands_with_the_model(tmp_path_factory):
    s, blob = booted(WITH_MPE, tmp_path_factory)
    knobs(s, 32, 0)
    m = Mpe(s, blob)
    m.zone_setting(1, 5)   # Lower zone, members 2-6
    m.flag()
    for ch, n in ((2, 60), (3, 64), (4, 67)):
        m.on(n, ch)
    s.tick(20)
    v = {ch: m.bound(ch)[0] for ch in (2, 3, 4)}
    before = {ch: osc(s, x) for ch, x in v.items()}
    s.bend(683, channel=3)  # +4 semitones at the default 48
    s.tick(50)
    shift = member_offset(683)
    after = osc(s, v[3])
    # The bend lands; the model's entry may move a step (0.39 c) with the new octave.
    assert all(abs((a - b) - shift) <= 3 for a, b in zip(after, before[3])), (after, before[3], shift)
    assert osc(s, v[2]) == before[2] and osc(s, v[4]) == before[4]
    m.all_off()
