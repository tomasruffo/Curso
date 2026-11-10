/* Vintage oscillator model for the Novation Summit (firmware 2.2, build 2121):
 * the sound's Diverge and Drift knobs drive a model of real analog VCOs
 * instead of stock's fixed table and shared random walk.
 *
 * Model and sources: docs/modelo.md. Short version, per voice v and
 * oscillator o, in cents:
 *
 *   static (Diverge)  autotune residual + tracking error x octaves from C4
 *                     + flat top end from the reset time (cents grow with f)
 *   moving (Drift)    temperature (whole synth + this voice) x tempco
 *                     x octaves above C0, + slow 1/f wander of the oscillator
 *
 *   total = (static x Diverge + moving x Drift) / 32, x key scale, +-50 cents
 *
 * Knob 32 is a typical real instrument, 64 twice that; above 64 it grows
 * fast (a neglected instrument). Knobs at 0 leave the sound as stock.
 *
 * Integer only, no FPGA writes, no note handling: vintage_hooks.c only
 * changes the oscillator pitch stock already sends every 2 ms.
 */
#ifndef VINTAGE_H
#define VINTAGE_H

#include <stdint.h>

#define VINTAGE_VOICES 16
#define VINTAGE_OSCS 3
#define VINTAGE_N (VINTAGE_VOICES * VINTAGE_OSCS)

/* osc_pitch's result: 4,096 per octave, C4 at -2,644 with the default tune
 * (docs/findings, "The osc_pitch struct": the sum is -1,983 at C4, x 4/3). */
#define VINTAGE_C4 (-2644)
#define VINTAGE_C0 (VINTAGE_C4 - 4 * 4096)
#define VINTAGE_MAX_Q8 (50 * 256)            /* the most it may move a pitch */

/* Oscillator chip families. */
enum { VINTAGE_CEM3340, VINTAGE_SSM2030, VINTAGE_PROFILES };

/* One chip family at knob 32. Every number and its source is in docs/modelo.md. */
struct vintage_profile {
    uint16_t bias_q8;           /* autotune residual, uniform +-, cents Q8 */
    uint16_t scale_q8;          /* tracking error, bell within +-, cents per octave Q8 */
    uint16_t reset_ns;          /* reset time the high-frequency trim leaves, ns */
    uint16_t tempco_q8;         /* scale tempco residual, uniform +-, cents/octave/degC Q8 */
    uint16_t noise_q8;          /* 1/f wander, standard deviation, cents Q8 */
    /* Reserved for later steps (drawn, not applied yet): */
    uint16_t env_spread_q12;    /* #3: per-voice envelope time spread, fraction Q12 */
    uint16_t cutoff_spread_q8;  /* filter: per-voice cutoff spread, cents Q8 */
};

/* Character of one oscillator: random numbers drawn once, -1..+1 in Q15,
 * scaled by the profile when used (so a profile change needs no redraw). */
struct vintage_osc {
    int16_t bias_u, scale_u, tempco_u, reset_u;
    int32_t band[2];            /* 1/f wander: ~0.08 Hz and ~0.6 Hz bands, Q16, sd 1 */
};

/* Character of one voice. Only temp is used now; the rest is drawn at
 * start-up so steps #3/#4 and the filter can use it later without changing
 * the random sequence (and so the character) of what's already there. */
struct vintage_voice {
    int32_t temp;               /* this voice's temperature offset, Q16 degC */
    int16_t env_u[3];           /* #3: envelope time factors, -1..+1 Q15 (reserved) */
    int16_t level_u;            /* #4: level offset, -1..+1 Q15 (reserved) */
    int16_t cutoff_u;           /* filter: cutoff offset, -1..+1 Q15 (reserved) */
};

/* Settings (a Settings page later). All default to 0: patch RAM starts
 * zeroed and the patch builder refuses initialised data. */
extern uint8_t vintage_off;          /* nonzero: every pitch exactly as without this patch */
extern uint8_t vintage_profile;      /* VINTAGE_CEM3340 (0, default) or VINTAGE_SSM2030 */
extern int8_t vintage_key_scale;     /* -128..127 = -1..+1; 0 = the model as is */
extern uint32_t vintage_clamp_hits;  /* times a limit kicked in (tests expect 0) */

void vintage_init(void);             /* draws the character; runs once */
void vintage_tick(void);             /* once per 1 ms tick */

/* Knob 0..127 -> amount, 32 = 1.0 (Q5): linear to 64, then steeper. */
uint32_t vintage_amount(uint32_t knob);

/* Offset in osc_pitch units for voice v, oscillator o, given the amounts
 * (vintage_amount) and the pitch stock computed without its own Diverge and
 * Drift. Counts and applies the +-50 cent limit. */
int32_t vintage_offset(uint32_t v, uint32_t o, uint32_t div_amount,
                       uint32_t drift_amount, int32_t pitch);

/* The model's state, read-only, for tests and later steps. */
const struct vintage_osc *vintage_osc_state(uint32_t i);
const struct vintage_voice *vintage_voice_state(uint32_t v);
int32_t vintage_global_temp(void);

/* The osc_pitch call the wrappers make once stock's own Diverge and Drift
 * are out of the way: vintage_inner_stock.c (osc_pitch) or
 * vintage_inner_mpe.c (the MPE patch's wrappers, so both work together). */
void vintage_inner(uint8_t *osc, uint32_t part, int on_tick);

#endif
