/* The inner call for the vintage patch on its own: stock osc_pitch. */

#include "firmware.h"
#include "vintage.h"

void vintage_inner(uint8_t *osc, uint32_t part, int on_tick)
{
    (void)on_tick;
    osc_pitch(osc, part);
}
