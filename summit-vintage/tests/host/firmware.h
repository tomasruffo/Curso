/* Host stand-in for patches/common/firmware.h: only what the vintage patch
 * uses. The test (test_vintage.c) defines these. */
#ifndef SUMMIT_FIRMWARE_H
#define SUMMIT_FIRMWARE_H

#include <stdint.h>

void osc_pitch(uint8_t *osc, uint32_t part);
extern volatile uint8_t multi_mode;
extern volatile uint8_t voice_loop_index;
extern uint8_t patches[3][0x201];

#endif
