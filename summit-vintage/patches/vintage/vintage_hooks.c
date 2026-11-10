/* Vintage model, firmware side: replaces osc_pitch at its six call sites
 * (mod_tick, every voice every tick; voice_alloc, at note-on).
 *
 * For a part whose sound has Diverge or Drift above 0, stock's own Diverge
 * and Drift terms are taken out of osc_pitch's sum for that one call (the
 * two inputs are set to 0 and put back right after), and the model's offset
 * is added to the result. Everything else stays stock:
 *   - Diverge and Drift at 0, the patch switched off, or an oscillator index
 *     we don't expect: the plain call, bit for bit.
 *   - Only the oscillator pitch changes, which stock already sends every
 *     2 ms: no FPGA write of our own, so the FPGA queue can't overflow
 *     because of this.
 *   - No note handling, glide, envelopes or stored data.
 *   - The result stays in osc_pitch's own range, counted in
 *     vintage_clamp_hits.
 */

#include "firmware.h"
#include "vintage.h"

/* osc_pitch reads both (observed, docs/findings "The osc_pitch struct",
 * 0x08013A2C-0x08013AC0); the names are inferred
 * (docs/symbols/summit-2.2-2121.csv). */
extern uint8_t diverge_amount[2];   /* 0x20013898: Diverge per part, x diverge_rand >> 5 */
extern int8_t osc_drift[6];         /* 0x20013EC8: stock's drift per part x oscillator */

#define PATCH_DIVERGE 0x2B          /* sound parameter bytes (NRPN 0:9 is Diverge) */
#define PATCH_DRIFT 0x2C
#define OSC_MIN (-43691)            /* what osc_pitch itself can return */
#define OSC_MAX 43689

static uint32_t knob(uint32_t part, uint32_t offset)
{
    uint32_t k = patches[(multi_mode ? 1 : 0) + (part & 1)][offset];
    return k > 127 ? 127 : k;
}

static void pitch(uint8_t *osc, uint32_t part, int on_tick)
{
    uint32_t v = voice_loop_index & 0x0F, o = osc[0], p = part & 1;

    if (vintage_off || o > 2) {
        vintage_inner(osc, part, on_tick);
        return;
    }
    if (on_tick && v == 0 && o == 0)
        vintage_tick();

    uint32_t div = knob(p, PATCH_DIVERGE), drift = knob(p, PATCH_DRIFT);
    if (div == 0 && drift == 0) {
        vintage_inner(osc, part, on_tick);
        return;
    }

    uint8_t keep_div = diverge_amount[p];
    int8_t keep_drift = osc_drift[3 * p + o];
    diverge_amount[p] = 0;
    osc_drift[3 * p + o] = 0;
    vintage_inner(osc, part, on_tick);
    diverge_amount[p] = keep_div;
    osc_drift[3 * p + o] = keep_drift;

    int32_t *out = (int32_t *)(osc + 0xC) + v;
    int32_t r = *out + vintage_offset(v, o, vintage_amount(div), vintage_amount(drift), *out);
    if (r < OSC_MIN || r > OSC_MAX) {
        r = r < OSC_MIN ? OSC_MIN : OSC_MAX;
        vintage_clamp_hits++;
    }
    *out = r;
}

/* mod_tick's three osc_pitch calls. */
void vintage_osc_pitch_tick(uint8_t *osc, uint32_t part)
{
    pitch(osc, part, 1);
}

/* voice_alloc's three osc_pitch calls. */
void vintage_osc_pitch_alloc(uint8_t *osc, uint32_t part)
{
    pitch(osc, part, 0);
}
