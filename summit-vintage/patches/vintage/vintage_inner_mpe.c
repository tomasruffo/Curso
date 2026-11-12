/* The tick hook for MPE + vintage: the MPE patch already hooks mod_tick's
 * mod_update(1) call (0x0801457E) with mpe_mod_update (patches/mpe/
 * mpe_slide.c). This takes that site and calls MPE's function first, so MPE
 * works as before; the vintage work follows. The MPE files stay unchanged. */

#include "firmware.h"
#include "vintage.h"

void mpe_mod_update(uint32_t part);

void vintage_mod_update(uint32_t part)
{
    mpe_mod_update(part);
    vintage_after_tick();
}
