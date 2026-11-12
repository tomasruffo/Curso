/* Vintage oscillator model: character, wander and the pitch offset
 * (vintage.h; numbers and sources in docs/modelo.md). Pure: it touches no
 * firmware state, so tests run it on a PC as is. */

#include "vintage.h"

uint8_t vintage_off;
uint8_t vintage_profile;             /* VINTAGE_CEM3340 */
int8_t vintage_key_scale;
uint32_t vintage_clamp_hits;

/* At knob 32. CEM3340: Prophet-5 Rev 3, OB-Xa class. SSM2030: Prophet-5 Rev 1/2.
 * docs/modelo.md, "Valores y fuentes", gives each number's source. */
static const struct vintage_profile PROFILES[VINTAGE_PROFILES] = {
    [VINTAGE_CEM3340] = {
        .bias_q8 = 166,            /* +-0.65 c: half the Prophet-5 autotune step (1.3 c) */
        .scale_q8 = 192,           /* +-0.75 c/oct bell (sd 0.3): AS3340 trimmed scale error */
        .reset_ns = 20,            /* 0.2 us x 10 % left after the HF trim */
        .tempco_q8 = 46,           /* +-0.18 c/oct/degC: AS3340 tempco, +-150 ppm/degC */
        .noise_q8 = 230,           /* 0.9 c sd */
        .env_spread_q12 = 123,     /* 3 % */
        .cutoff_spread_q8 = 9216,  /* 3 % of an octave = 36 c */
    },
    [VINTAGE_SSM2030] = {
        .bias_q8 = 166,            /* same autotune */
        .scale_q8 = 384,           /* +-1.5 c/oct bell (sd 0.6): assumed 2x CEM */
        .reset_ns = 150,           /* 500 ns (2030 datasheet) x 30 % left after the HF trim */
        .tempco_q8 = 92,           /* assumed 2x CEM */
        .noise_q8 = 461,           /* 1.8 c sd */
        .env_spread_q12 = 328,     /* 8 % */
        .cutoff_spread_q8 = 18432, /* 6 % of an octave = 72 c */
    },
};

/* The wander: one-pole filtered noise, each oscillator stepped once every
 * VINTAGE_N steps (48 ms when vintage_step runs once per 1 ms tick, so
 * 20.8 Hz). Gains give the standard deviation in the comment. Temperatures
 * are assumed (no measurement found): docs/modelo.md. */
#define BAND0_SHIFT 5           /* ~1.5 s, ~0.10 Hz */
#define BAND0_GAIN 39           /* sd 1.0 (Q16) */
#define BAND1_SHIFT 3           /* ~0.38 s, ~0.4 Hz */
#define BAND1_GAIN 19           /* sd 1.0 */
#define TEMP_VOICE_SHIFT 7      /* ~6 s */
#define TEMP_VOICE_GAIN 39      /* sd 0.5 degC */
#define TEMP_GLOBAL_SHIFT 10    /* ~49 s */
#define TEMP_GLOBAL_GAIN 222    /* sd 1.0 degC */

static struct vintage_osc oscs[VINTAGE_N];
static struct vintage_voice voices[VINTAGE_VOICES];
static int32_t global_temp;
static uint32_t rng;
static uint8_t inited;

/* ---- random numbers -------------------------------------------------- */

static uint32_t rnd(void)                  /* xorshift32 */
{
    rng ^= rng << 13;
    rng ^= rng >> 17;
    rng ^= rng << 5;
    return rng;
}

static int32_t rnd_uniform(void)           /* -32768..32767, even */
{
    return (int16_t)(rnd() >> 16);
}

static int32_t rnd_bell(void)              /* -32768..32767, triangular, sd 13,378 */
{
    uint32_t r = rnd();                    /* both halves of one draw */
    return ((int32_t)(int16_t)(r >> 16) + (int32_t)(int16_t)r) >> 1;
}

/* ---- character -------------------------------------------------------- */

void vintage_init(void)
{
    if (inited)
        return;
    inited = 1;
    rng = 0x9E3779B9u;
    for (uint32_t i = 0; i < VINTAGE_N; i++) {
        struct vintage_osc *c = &oscs[i];
        c->bias_u = (int16_t)rnd_uniform();
        c->scale_u = (int16_t)rnd_bell();
        c->tempco_u = (int16_t)rnd_uniform();
        c->reset_u = (int16_t)rnd_uniform();
        /* Start the wander already spread (about sd 1), not at 0. */
        c->band[0] = rnd_bell() * 5;
        c->band[1] = rnd_bell() * 5;
    }
    for (uint32_t v = 0; v < VINTAGE_VOICES; v++) {
        struct vintage_voice *w = &voices[v];
        w->temp = rnd_bell() * 5 / 2;          /* about sd 0.5 degC */
        for (uint32_t e = 0; e < 3; e++)
            w->env_u[e] = (int16_t)rnd_bell();
        w->level_u = (int16_t)rnd_bell();
        w->cutoff_u = (int16_t)rnd_bell();
    }
    global_temp = rnd_bell() * 5;              /* about sd 1 degC */
}

/* ---- wander ----------------------------------------------------------- */

static void lowpass(int32_t *s, int32_t gain, int shift)
{
    *s += (rnd_bell() * gain - *s) >> shift;
}

void vintage_step(uint32_t i)
{
    vintage_init();
    i %= VINTAGE_N;
    lowpass(&oscs[i].band[0], BAND0_GAIN, BAND0_SHIFT);
    lowpass(&oscs[i].band[1], BAND1_GAIN, BAND1_SHIFT);
    if (i % 3 == 0)
        lowpass(&voices[i / 3].temp, TEMP_VOICE_GAIN, TEMP_VOICE_SHIFT);
    if (i == 0)
        lowpass(&global_temp, TEMP_GLOBAL_GAIN, TEMP_GLOBAL_SHIFT);
}

/* ---- the offset ------------------------------------------------------- */

/* 2^(x / 4096) in Q12, x clamped to +-12 octaves: a 1/16-octave table,
 * interpolated. */
static int32_t exp2_q12(int32_t x)
{
    static const uint16_t frac[17] = {
        4096, 4277, 4467, 4664, 4871, 5087, 5312, 5547,
        5793, 6049, 6317, 6597, 6889, 7194, 7512, 7845, 8192 };
    if (x > 12 * 4096)
        x = 12 * 4096;
    if (x < -12 * 4096)
        x = -12 * 4096;
    int32_t oct = x >> 12;
    int32_t k = (x >> 8) & 15, t = x & 255;
    int32_t f = frac[k] + (((frac[k + 1] - frac[k]) * t) >> 8);
    return oct >= 0 ? f << oct : f >> -oct;
}

uint32_t vintage_amount(uint32_t knob)
{
    if (knob > 127)
        knob = 127;
    uint32_t over = knob > 64 ? knob - 64 : 0;
    return knob + ((over * over) >> 3);        /* 32 -> 32, 64 -> 64, 127 -> 623 */
}

/* The top end goes flat: each period is longer by the reset time t, so
 * f' = f / (1 + f t), about -1731 f t cents. f from octaves above C0. */
static int32_t droop_q8(int32_t oct0_q12, uint32_t reset_ns)
{
    int32_t e2 = exp2_q12(oct0_q12);                   /* 2^octaves, Q12 */
    int32_t hz = ((e2 >> 6) * 1046) >> 12;             /* x 16.35 Hz (C0) */
    return -(int32_t)(((uint32_t)hz * reset_ns * 29u) >> 16);  /* 1731 x 256 / 1e9 = 29 / 2^16 */
}

static const struct vintage_profile *profile(void)
{
    return &PROFILES[vintage_profile < VINTAGE_PROFILES ? vintage_profile : 0];
}

static int32_t octaves_above_c0(int32_t pitch)       /* Q12, 0 below C0 */
{
    int32_t oct0 = pitch - VINTAGE_C0;
    return oct0 < 0 ? 0 : oct0;
}

/* Static part (Diverge), cents Q8 at amount 32: calibration residuals. */
static int32_t static_part(uint32_t i, int32_t pitch)
{
    const struct vintage_profile *pr = profile();
    const struct vintage_osc *c = &oscs[i];
    int32_t bias = (c->bias_u * pr->bias_q8) >> 15;
    int32_t track = ((((int32_t)c->scale_u * pr->scale_q8) >> 15) * (pitch - VINTAGE_C4)) >> 12;
    uint32_t reset = (pr->reset_ns * (uint32_t)(2048 + (c->reset_u >> 5))) >> 11;  /* +-50 % */
    return bias + track + droop_q8(octaves_above_c0(pitch), reset);
}

/* Moving part (Drift), cents Q8 at amount 32: temperature and wander. */
static int32_t moving_part(uint32_t i, int32_t pitch)
{
    const struct vintage_profile *pr = profile();
    const struct vintage_osc *c = &oscs[i];
    int32_t temp = global_temp + voices[i / 3].temp;               /* Q16 degC */
    int32_t tc = (c->tempco_u * pr->tempco_q8) >> 15;              /* Q8 c/oct/degC */
    int32_t thermal = ((((temp >> 8) * tc) >> 8) * octaves_above_c0(pitch)) >> 12;
    int32_t u = c->band[0] + (c->band[1] >> 1);                    /* sd 1.118 */
    int32_t noise = ((((u >> 4) * 229) >> 8) * pr->noise_q8) >> 12;
    return thermal + noise;
}

int32_t vintage_cents_q8(uint32_t i, uint32_t div_amount, uint32_t drift_amount, int32_t pitch)
{
    vintage_init();
    i %= VINTAGE_N;
    int32_t stat = div_amount ? static_part(i, pitch) : 0;
    int32_t moving = drift_amount ? moving_part(i, pitch) : 0;
    int32_t cents_q8 = (stat * (int32_t)div_amount + moving * (int32_t)drift_amount) >> 5;

    /* Key scale: a taste control, 2^(scale x octaves from C4). */
    if (vintage_key_scale) {
        if (cents_q8 > 4 * VINTAGE_MAX_Q8)
            cents_q8 = 4 * VINTAGE_MAX_Q8;
        if (cents_q8 < -4 * VINTAGE_MAX_Q8)
            cents_q8 = -4 * VINTAGE_MAX_Q8;
        int32_t x = (vintage_key_scale * (pitch - VINTAGE_C4)) >> 7;
        if (x > 3 * 4096)
            x = 3 * 4096;
        if (x < -3 * 4096)
            x = -3 * 4096;
        cents_q8 = (cents_q8 * exp2_q12(x)) >> 12;
    }

    if (cents_q8 > VINTAGE_MAX_Q8 || cents_q8 < -VINTAGE_MAX_Q8) {
        cents_q8 = cents_q8 > 0 ? VINTAGE_MAX_Q8 : -VINTAGE_MAX_Q8;
        vintage_clamp_hits++;
    }
    return cents_q8;
}

int8_t vintage_entry(int32_t cents_q8)
{
    /* 1/256 semitone = 100/256 cents: entry = cents x 2.56 = cents_q8 / 100,
     * rounded to the nearest (a constant divisor: no library call). */
    int32_t e = (cents_q8 + (cents_q8 >= 0 ? 50 : -50)) / 100;
    return (int8_t)(e > 127 ? 127 : e < -127 ? -127 : e);
}

int32_t vintage_offset(uint32_t v, uint32_t o, uint32_t div_amount,
                       uint32_t drift_amount, int32_t pitch)
{
    if (o > 2)
        return 0;
    return (vintage_cents_q8(3 * (v & 15) + o, div_amount, drift_amount, pitch) * 437) >> 15;
}

const struct vintage_osc *vintage_osc_state(uint32_t i) { return &oscs[i % VINTAGE_N]; }
const struct vintage_voice *vintage_voice_state(uint32_t v) { return &voices[v & 15]; }
int32_t vintage_global_temp(void) { return global_temp; }
