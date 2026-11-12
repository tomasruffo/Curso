/* Vintage model, firmware side: once per tick, after mod_tick's
 * mod_update(1) and before its FPGA writes.
 *
 * Stock osc_pitch adds, per voice v and oscillator o (observed, docs/findings
 * "The osc_pitch struct"):
 *     diverge_amount[p] x diverge_rand[3v + o] >> 5     (8.8 semitones)
 *     + osc_drift[3p + o]                                (stock's shared drift)
 * and osc_drift_update (0x08013844) sets osc_drift from its walk times
 * drift_amount[p] (the multiply at 0x08013876, observed).
 *
 * For a part whose sound has Diverge or Drift above 0, every tick:
 *   - diverge_amount[p] = 32: a diverge_rand entry is then the offset itself
 *     (1/256 semitone, +-127 = +-49.6 cents);
 *   - drift_amount[p] = 0: stock's shared drift becomes 0;
 *   - one oscillator in turn (each every 48 ms) steps its wander and gets its
 *     entry, and a voice that starts a new note gets its three entries now.
 * The next tick's osc_pitch calls, and voice_alloc's at note-on, play them.
 *
 * Nothing else changes: no osc_pitch wrapper, no FPGA write, no note
 * handling. A part with both knobs at 0 is not touched. vintage_off puts
 * stock's table and amounts back.
 *
 * Known edge: turning Diverge or Drift while notes sound, stock's own
 * amounts come back for the tick in between (patch_apply_osc sets them from
 * the knob), until this runs again 1 ms later.
 */

#include "firmware.h"
#include "vintage.h"

/* Names from docs/symbols/summit-2.2-2121.csv. */
extern uint8_t diverge_amount[2];   /* 0x20013898, inferred name; osc_pitch reads it (observed) */
extern uint16_t drift_amount[2];    /* 0x20014B04, inferred name; osc_drift_update multiplies by it */
extern int8_t diverge_rand[48];     /* 0x200007CC: s8 per 3v + o (observed) */
extern uint8_t osc1_pitch[], osc2_pitch[], osc3_pitch[];   /* results at +0xC + 4v (observed) */

#define PATCH_DIVERGE 0x2B          /* sound parameter bytes (NRPN 0:9, 0:10) */
#define PATCH_DRIFT 0x2C
#define TABLE_AMOUNT 32

static int8_t stock_table[48];
static uint8_t have_stock, applied[2], next, notes[16];
static uint16_t amount_div[2], amount_drift[2];

static uint32_t knob(uint32_t part, uint32_t offset)
{
    uint32_t k = patches[(multi_mode ? 1 : 0) + (part & 1)][offset];
    return k > 127 ? 127 : k;
}

static uint32_t part_of(uint32_t v)
{
    return multi_mode && v >= 8 ? 1 : 0;
}

/* The pitch osc_pitch gave oscillator i last tick (its octave is all we need). */
static int32_t last_pitch(uint32_t i)
{
    uint8_t *osc = i % 3 == 0 ? osc1_pitch : i % 3 == 1 ? osc2_pitch : osc3_pitch;
    return *(volatile int32_t *)(osc + 0xC + 4 * (i / 3));
}

static void write_entry(uint32_t i, uint32_t p)
{
    int32_t c = vintage_cents_q8(i, amount_div[p], amount_drift[p], last_pitch(i));
    diverge_rand[i] = vintage_entry(c);
}

static void restore_stock(void)
{
    for (uint32_t i = 0; i < 48; i++)
        diverge_rand[i] = stock_table[i];
    for (uint32_t p = 0; p < 2; p++) {
        if (applied[p]) {
            diverge_amount[p] = (uint8_t)knob(p, PATCH_DIVERGE);
            drift_amount[p] = (uint16_t)knob(p, PATCH_DRIFT);
        }
        applied[p] = 0;
    }
}

void vintage_after_tick(void)
{
    if (!have_stock) {                     /* stock's table, as booted */
        for (uint32_t i = 0; i < 48; i++)
            stock_table[i] = diverge_rand[i];
        have_stock = 1;
    }
    if (vintage_off) {
        if (applied[0] | applied[1])
            restore_stock();
        return;
    }

    uint32_t any = 0, started = 0;
    for (uint32_t p = 0; p < 2; p++) {
        amount_div[p] = (uint16_t)vintage_amount(knob(p, PATCH_DIVERGE));
        amount_drift[p] = (uint16_t)vintage_amount(knob(p, PATCH_DRIFT));
        if (amount_div[p] | amount_drift[p]) {
            diverge_amount[p] = TABLE_AMOUNT;
            drift_amount[p] = 0;
            started |= (uint32_t)!applied[p] << p;
            applied[p] = 1;
            any = 1;
        } else {
            applied[p] = 0;                /* knobs at 0: stock's own values are 0 too */
        }
    }
    if (!any)
        return;

    /* A part that just started: all its entries now, not over the next 48 ms. */
    if (started)
        for (uint32_t i = 0; i < 48; i++)
            if (started & (1u << part_of(i / 3)))
                write_entry(i, part_of(i / 3));

    /* A voice that starts a new note: its entries for that note now. */
    for (uint32_t v = 0; v < 16; v++) {
        uint8_t n = voice_note[v];
        if (n != notes[v]) {
            notes[v] = n;
            uint32_t p = part_of(v);
            if (applied[p])
                for (uint32_t o = 0; o < 3; o++)
                    write_entry(3 * v + o, p);
        }
    }

    /* One oscillator in turn: its wander moves, its entry follows. */
    uint32_t i = next;
    next = (uint8_t)(i + 1 < 48 ? i + 1 : 0);
    vintage_step(i);
    uint32_t p = part_of(i / 3);
    if (applied[p])
        write_entry(i, p);
}
