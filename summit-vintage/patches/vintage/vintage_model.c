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

/* Temperatures, Q16 degC. Assumed (no measurement found): docs/modelo.md. */
#define TEMP_GLOBAL_GAIN 887   /* sd 1.0 degC, ~65 s time constant */
#define TEMP_VOICE_GAIN 157    /* sd 0.5 degC, ~8 s */
#define BAND0_GAIN 157         /* sd 1.0, ~2 s (0.08 Hz) */
#define BAND1_GAIN 55          /* sd 1.0, ~0.26 s (0.6 Hz) */

static struct vintage_osc oscs[VINTAGE_N];
static struct vintage_voice voices[VINTAGE_VOICES];
static int32_t global_temp;
static uint32_t rng;
static uint8_t phase, inited;

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
    return (rnd_uniform() + rnd_uniform()) >> 1;
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

/* ---- wander: one-pole filtered noise, a quarter of it per tick -------- */

static void lowpass(int32_t *s, int32_t gain, int shift)
{
    *s += (rnd_bell() * gain - *s) >> shift;
}

void vintage_tick(void)
{
    vintage_init();
    uint32_t ph = phase++ & 3;                 /* each part updates at 250 Hz */
    if (ph == 0)
        lowpass(&global_temp, TEMP_GLOBAL_GAIN, 14);
    for (uint32_t v = ph; v < VINTAGE_VOICES; v += 4)
        lowpass(&voices[v].temp, TEMP_VOICE_GAIN, 11);
    for (uint32_t i = ph; i < VINTAGE_N; i += 4) {
        lowpass(&oscs[i].band[0], BAND0_GAIN, 9);
        lowpass(&oscs[i].band[1], BAND1_GAIN, 6);
    }
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

int32_t vintage_offset(uint32_t v, uint32_t o, uint32_t div_amount,
                       uint32_t drift_amount, int32_t pitch)
{
    vintage_init();
    const struct vintage_profile *pr = &PROFILES[vintage_profile < VINTAGE_PROFILES ? vintage_profile : 0];
    const struct vintage_osc *c = &oscs[(3 * (v & 15) + o) % VINTAGE_N];
    int32_t oct4 = pitch - VINTAGE_C4;                 /* octaves from C4, Q12 */
    int32_t oct0 = pitch - VINTAGE_C0;                 /* octaves above C0, Q12 */
    if (oct0 < 0)
        oct0 = 0;

    /* Static: calibration residuals (Diverge). */
    int32_t stat = 0;
    if (div_amount) {
        int32_t bias = (c->bias_u * pr->bias_q8) >> 15;
        int32_t track = ((((int32_t)c->scale_u * pr->scale_q8) >> 15) * oct4) >> 12;
        uint32_t reset = (pr->reset_ns * (uint32_t)(2048 + (c->reset_u >> 5))) >> 11;  /* +-50 % */
        stat = bias + track + droop_q8(oct0, reset);
    }

    /* Moving: temperature and wander (Drift). */
    int32_t moving = 0;
    if (drift_amount) {
        int32_t temp = global_temp + voices[v & 15].temp;          /* Q16 degC */
        int32_t tc = (c->tempco_u * pr->tempco_q8) >> 15;          /* Q8 c/oct/degC */
        int32_t thermal = ((((temp >> 8) * tc) >> 8) * oct0) >> 12;
        int32_t u = c->band[0] + (c->band[1] >> 1);                /* sd 1.118 */
        int32_t noise = ((((u >> 4) * 229) >> 8) * pr->noise_q8) >> 12;
        moving = thermal + noise;
    }

    int32_t cents_q8 = (stat * (int32_t)div_amount + moving * (int32_t)drift_amount) >> 5;

    /* Key scale: a taste control, 2^(scale x octaves from C4). */
    if (vintage_key_scale) {
        if (cents_q8 > 4 * VINTAGE_MAX_Q8)
            cents_q8 = 4 * VINTAGE_MAX_Q8;
        if (cents_q8 < -4 * VINTAGE_MAX_Q8)
            cents_q8 = -4 * VINTAGE_MAX_Q8;
        int32_t x = (vintage_key_scale * oct4) >> 7;
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
    return (cents_q8 * 437) >> 15;                     /* cents Q8 -> 3.413 per cent */
}

const struct vintage_osc *vintage_osc_state(uint32_t i) { return &oscs[i % VINTAGE_N]; }
const struct vintage_voice *vintage_voice_state(uint32_t v) { return &voices[v & 15]; }
int32_t vintage_global_temp(void) { return global_temp; }
