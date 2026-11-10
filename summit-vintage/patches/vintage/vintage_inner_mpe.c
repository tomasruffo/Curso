/* The inner call for MPE + vintage: the MPE patch's own osc_pitch wrappers
 * (patches/mpe/mpe_expr.c), so per-note bend and the rest of MPE work as
 * before and the vintage offset goes on top. The MPE files stay unchanged. */

#include "firmware.h"
#include "vintage.h"

void mpe_osc_pitch_tick(uint8_t *osc, uint32_t part);
void mpe_osc_pitch_alloc(uint8_t *osc, uint32_t part);

void vintage_inner(uint8_t *osc, uint32_t part, int on_tick)
{
    if (on_tick)
        mpe_osc_pitch_tick(osc, part);
    else
        mpe_osc_pitch_alloc(osc, part);
}
