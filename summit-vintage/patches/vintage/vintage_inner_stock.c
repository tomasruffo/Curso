/* The tick hook for the vintage patch on its own: mod_tick's mod_update(1)
 * call (0x0801457E), then the vintage work. */

#include "firmware.h"
#include "vintage.h"

void vintage_mod_update(uint32_t part)
{
    mod_update(part);
    vintage_after_tick();
}
