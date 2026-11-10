/* Host tests for the vintage patch: the patch's own C (vintage_model.c,
 * vintage_hooks.c, vintage_inner_stock.c) against a stand-in osc_pitch that
 * follows the documented formula (gipfel_mpe docs/findings,
 * "The osc_pitch struct"):
 *
 *   sum = note + diverge_amount[p] * diverge_rand[3v + o] >> 5 + osc_drift[3p + o]
 *   out = (s16) sum * 0x5555 >> 14            (4,096 per octave)
 *
 * Build and run: tests/host/run.sh
 */

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "firmware.h"
#include "../../patches/vintage/vintage.h"

void vintage_osc_pitch_tick(uint8_t *osc, uint32_t part);
void vintage_osc_pitch_alloc(uint8_t *osc, uint32_t part);

/* ---- the stand-in firmware ------------------------------------------- */

volatile uint8_t multi_mode;
volatile uint8_t voice_loop_index;
uint8_t patches[3][0x201];
uint8_t diverge_amount[2];
int8_t osc_drift[6];
static int8_t diverge_rand[64];
static int32_t note_sum[16];                 /* the note term, 8.8 semitones */

void osc_pitch(uint8_t *osc, uint32_t part)
{
    uint32_t v = voice_loop_index & 15, o = osc[0], p = part & 1;
    int32_t sum = note_sum[v] + ((diverge_amount[p] * diverge_rand[(3 * v + o) & 63]) >> 5)
                + osc_drift[(3 * p + o) % 6];
    int32_t out = ((int32_t)(int16_t)sum * 0x5555) >> 14;
    memcpy(osc + 0xC + 4 * v, &out, 4);
}

static _Alignas(4) uint8_t osc_mem[3][0xC + 64];
static _Alignas(4) uint8_t ref_mem[3][0xC + 64];

static int32_t out_of(uint8_t *mem, uint32_t v)
{
    int32_t x;
    memcpy(&x, mem + 0xC + 4 * v, 4);
    return x;
}

static void set_note(uint32_t v, int midi)   /* C4 = 60: sum -1,983 */
{
    note_sum[v] = -1983 + (midi - 60) * 256;
}

static uint32_t part_of(uint32_t v)
{
    return multi_mode && v >= 8 ? 1 : 0;
}

static void set_knobs(int which, int div, int drift)
{
    patches[which][0x2B] = (uint8_t)div;
    patches[which][0x2C] = (uint8_t)drift;
}

static unsigned stock_rng = 12345;
static void stock_walk(void)                 /* stock's drift moves under us */
{
    for (int i = 0; i < 6; i++) {
        stock_rng = stock_rng * 1103515245u + 12345u;
        osc_drift[i] = (int8_t)((stock_rng >> 16) % 41 - 20);
    }
}

/* One mod_tick: every voice, three oscillators. */
static void tick(void)
{
    for (uint32_t v = 0; v < 16; v++) {
        voice_loop_index = (uint8_t)v;
        for (uint32_t o = 0; o < 3; o++)
            vintage_osc_pitch_tick(osc_mem[o], part_of(v));
    }
}

/* What plain osc_pitch gives now (with or without stock's own terms). */
static int32_t reference(uint32_t v, uint32_t o, int stock_terms)
{
    uint32_t p = part_of(v);
    uint8_t keep_div = diverge_amount[p];
    int8_t keep_drift = osc_drift[3 * p + o];
    if (!stock_terms) {
        diverge_amount[p] = 0;
        osc_drift[3 * p + o] = 0;
    }
    voice_loop_index = (uint8_t)v;
    osc_pitch(ref_mem[o], p);
    diverge_amount[p] = keep_div;
    osc_drift[3 * p + o] = keep_drift;
    return out_of(ref_mem[o], v);
}

static double cents(int32_t units) { return units / 3.41333; }

/* ---- reporting -------------------------------------------------------- */

static int failures;
static void check(int ok, const char *what, const char *fmt, double a, double b)
{
    printf("%s  %s", ok ? "ok  " : "FAIL", what);
    if (fmt)
        printf(fmt, a, b);
    printf("\n");
    if (!ok)
        failures++;
}

static void reset_world(void)
{
    multi_mode = 0;
    memset(patches, 0, sizeof patches);
    vintage_off = 0;
    vintage_profile = VINTAGE_CEM3340;
    vintage_key_scale = 0;
    vintage_clamp_hits = 0;
    diverge_amount[0] = diverge_amount[1] = 50;
    for (int i = 0; i < 64; i++)
        diverge_rand[i] = (int8_t)((i * 7) % 23 - 11);   /* stock-like +-11 */
    for (uint32_t v = 0; v < 16; v++)
        set_note(v, 60);
    for (uint8_t o = 0; o < 3; o++)          /* +0: the oscillator index */
        osc_mem[o][0] = ref_mem[o][0] = o;
}

/* ---- tests ------------------------------------------------------------ */

/* Knobs at 0, or the patch off: every pitch exactly as plain osc_pitch,
 * stock's own Diverge and Drift included. */
static void test_off_is_stock(void)
{
    reset_world();
    long diff = 0;
    for (int t = 0; t < 2000; t++) {
        stock_walk();
        for (uint32_t v = 0; v < 16; v++)
            set_note(v, 36 + (int)((v * 5 + t) % 48));
        tick();
        for (uint32_t v = 0; v < 16; v++)
            for (uint32_t o = 0; o < 3; o++)
                diff += out_of(osc_mem[o], v) != reference(v, o, 1);
    }
    check(diff == 0, "Diverge 0 + Drift 0: identical to stock", " (%g of %g pitches differ)", (double)diff, 2000.0 * 48);

    set_knobs(0, 64, 64);
    vintage_off = 1;
    diff = 0;
    for (int t = 0; t < 2000; t++) {
        stock_walk();
        tick();
        for (uint32_t v = 0; v < 16; v++)
            for (uint32_t o = 0; o < 3; o++)
                diff += out_of(osc_mem[o], v) != reference(v, o, 1);
    }
    check(diff == 0, "patch switched off: identical to stock", " (%g of %g differ)", (double)diff, 2000.0 * 48);

    /* An oscillator index we don't expect: plain call. */
    vintage_off = 0;
    static _Alignas(4) uint8_t odd[0xC + 64];
    odd[0] = 5;
    voice_loop_index = 3;
    vintage_osc_pitch_tick(odd, 0);
    int32_t got = out_of(odd, 3);
    odd[0] = 5;
    osc_pitch(odd, 0);
    check(got == out_of(odd, 3), "unexpected oscillator index: plain call", NULL, 0, 0);
}

/* With the knobs up, stock's own terms are out of the sum, put back after
 * the call, and the offset stays within +-50 cents. */
static void test_stock_terms_replaced(void)
{
    reset_world();
    set_knobs(0, 32, 32);
    int restored = 1, in_range = 1, moved = 0;
    for (int t = 0; t < 500; t++) {
        stock_walk();
        int8_t want[6];
        memcpy(want, osc_drift, 6);
        tick();
        restored &= memcmp(want, osc_drift, 6) == 0 && diverge_amount[0] == 50;
        for (uint32_t v = 0; v < 16; v++)
            for (uint32_t o = 0; o < 3; o++) {
                double c = cents(out_of(osc_mem[o], v) - reference(v, o, 0));
                in_range &= fabs(c) <= 50.0;
                moved += fabs(c) > 0.05;
            }
    }
    check(restored, "stock's Diverge and Drift inputs put back after each call", NULL, 0, 0);
    check(in_range, "offset within +-50 cents of stock without its own terms", NULL, 0, 0);
    check(moved > 500 * 48 / 2, "the model moves the pitches", " (%g of %g moved)", (double)moved, 500.0 * 48);
}

/* Diverge: every one of the 16 voices has its own character (stock's
 * voices 8-15 copy 0-7). */
static void test_voices_unique(void)
{
    reset_world();
    tick();
    int same = 0;
    for (uint32_t i = 0; i < 24; i++) {
        const struct vintage_osc *a = vintage_osc_state(i), *b = vintage_osc_state(i + 24);
        same += a->bias_u == b->bias_u || a->scale_u == b->scale_u || a->tempco_u == b->tempco_u;
    }
    check(same == 0, "voices 9-16 have their own character, not a copy of 1-8", " (%g of %g oscillators share a value)", same, 24);

    /* And the three oscillators of a voice differ from each other. */
    same = 0;
    for (uint32_t v = 0; v < 16; v++)
        for (uint32_t o = 1; o < 3; o++)
            same += vintage_osc_state(3 * v)->bias_u == vintage_osc_state(3 * v + o)->bias_u;
    check(same == 0, "the three oscillators of a voice differ", " (%g of %g equal)", same, 32);
}

/* Drift: each voice wanders on its own (stock: one walk for all voices). */
static void test_drift_independent(void)
{
    reset_world();
    set_knobs(0, 0, 32);
    enum { SECONDS = 300, EVERY = 20 };
    static double s[16][SECONDS * 1000 / EVERY];
    int n = 0;
    for (int t = 0; t < SECONDS * 1000; t++) {
        tick();
        if (t % EVERY == 0) {
            for (uint32_t v = 0; v < 16; v++)
                s[v][n] = cents(out_of(osc_mem[0], v) - reference(v, 0, 0));
            n++;
        }
    }
    double mean[16], sd[16], sd_min = 1e9, sd_avg = 0;
    for (int v = 0; v < 16; v++) {
        double m = 0, q = 0;
        for (int i = 0; i < n; i++)
            m += s[v][i];
        m /= n;
        for (int i = 0; i < n; i++)
            q += (s[v][i] - m) * (s[v][i] - m);
        mean[v] = m;
        sd[v] = sqrt(q / n);
        sd_avg += sd[v] / 16;
        if (sd[v] < sd_min)
            sd_min = sd[v];
    }
    double corr_abs = 0;
    int pairs = 0;
    for (int a = 0; a < 16; a++)
        for (int b = a + 1; b < 16; b++) {
            double c = 0;
            for (int i = 0; i < n; i++)
                c += (s[a][i] - mean[a]) * (s[b][i] - mean[b]);
            corr_abs += fabs(c / n / (sd[a] * sd[b]));
            pairs++;
        }
    corr_abs /= pairs;
    check(sd_min > 0.3, "all 16 voices wander", " (smallest sd %.2f c, mean %.2f c)", sd_min, sd_avg);
    check(sd_avg > 0.6 && sd_avg < 1.6, "Drift 32 at C4 (CEM3340): about 1 cent sd", " (%.2f c, want %.1f-1.6)", sd_avg, 0.6);
    check(corr_abs < 0.4, "voices move independently", " (mean |correlation| %.2f, want < %.1f)", corr_abs, 0.4);
}

/* The knobs scale the offset linearly up to 64; the octave dependence of
 * tracking and the flat top end; key scale. Deterministic: same state. */
static void test_shape(void)
{
    reset_world();
    tick();
    int32_t c4 = VINTAGE_C4;
    int lin = 1;
    for (uint32_t i = 0; i < 48; i++) {
        int32_t a = vintage_offset(i / 3, i % 3, 32, 32, c4);
        int32_t b = vintage_offset(i / 3, i % 3, 64, 64, c4);
        lin &= abs(b - 2 * a) <= 2;
    }
    check(lin, "knob 64 = twice knob 32", NULL, 0, 0);
    check(vintage_amount(127) > 8 * 32, "knob 127 = a neglected instrument (amount)", " (%.0f / 32 = %.1fx)", vintage_amount(127), vintage_amount(127) / 32.0);

    /* Tracking: the spread of Diverge grows away from C4. */
    double sd4 = 0, sd7 = 0;
    for (uint32_t i = 0; i < 48; i++) {
        double a = cents(vintage_offset(i / 3, i % 3, 32, 0, c4));
        double b = cents(vintage_offset(i / 3, i % 3, 32, 0, c4 + 3 * 4096));
        sd4 += a * a / 48;
        sd7 += b * b / 48;
    }
    check(sqrt(sd7) > 1.5 * sqrt(sd4), "Diverge spreads more three octaves up (tracking)", " (C4 %.2f c, C7 %.2f c rms)", sqrt(sd4), sqrt(sd7));

    /* Flat top end near 8.4 kHz, averaged over the 48 oscillators. The
     * offset at hi + the offset at the mirror note below C4 - 2 x the offset
     * at C4 cancels the autotune residual and the (linear) tracking error and
     * leaves the reset error, which is ~0 at the low note. */
    int32_t hi = VINTAGE_C0 + (int32_t)(log2(8400.0 / 16.3516) * 4096);
    int32_t lo = 2 * c4 - hi;
    for (int prof = 0; prof < 2; prof++) {
        vintage_profile = (uint8_t)prof;
        double droop = 0;
        for (uint32_t i = 0; i < 48; i++)
            droop += cents(vintage_offset(i / 3, i % 3, 32, 0, hi) + vintage_offset(i / 3, i % 3, 32, 0, lo)
                           - 2 * vintage_offset(i / 3, i % 3, 32, 0, c4)) / 48;
        if (prof == VINTAGE_SSM2030)
            check(droop < -1.0 && droop > -3.5, "SSM2030: 8.4 kHz goes flat ~2 cents (2030 reset time)", " (%.2f c, Profit-5: %.1f)", droop, -1.8);
        else
            check(droop < -0.1 && droop > -0.8, "CEM3340: 8.4 kHz goes flat a little", " (%.2f c, Profit-5: %.1f)", droop, -0.2);
    }
    vintage_profile = VINTAGE_CEM3340;

    /* Key scale -1: an octave up halves the offset, an octave down doubles it. */
    int ok = 1;
    for (uint32_t i = 0; i < 48; i++) {
        int32_t up = c4 + 4096, down = c4 - 4096;
        vintage_key_scale = 0;
        int32_t a = vintage_offset(i / 3, i % 3, 32, 32, up), b = vintage_offset(i / 3, i % 3, 32, 32, down);
        vintage_key_scale = -128;
        int32_t a2 = vintage_offset(i / 3, i % 3, 32, 32, up), b2 = vintage_offset(i / 3, i % 3, 32, 32, down);
        ok &= abs(2 * a2 - a) <= 2 && abs(b2 - 2 * b) <= 2;
    }
    vintage_key_scale = 0;
    check(ok, "key scale -100%: half an octave up, double an octave down", NULL, 0, 0);
}

/* Multi mode: each part reads its own sound's knobs. */
static void test_multi(void)
{
    reset_world();
    multi_mode = 1;
    set_knobs(1, 0, 0);     /* Part A: as stock */
    set_knobs(2, 32, 32);   /* Part B: the model */
    long a_diff = 0, b_diff = 0;
    for (int t = 0; t < 200; t++) {
        stock_walk();
        tick();
        for (uint32_t v = 0; v < 16; v++)
            for (uint32_t o = 0; o < 3; o++) {
                int d = out_of(osc_mem[o], v) != reference(v, o, 1);
                if (v < 8)
                    a_diff += d;
                else
                    b_diff += d;
            }
    }
    check(a_diff == 0, "Multi: Part A (knobs 0) plays as stock", " (%g differ)", (double)a_diff, 0);
    check(b_diff > 200 * 24 / 2, "Multi: Part B (knobs 32) uses the model", " (%g of %g differ)", (double)b_diff, 200.0 * 24);
}

/* Note-on (voice_alloc) gives the same offset as the tick and doesn't
 * advance the wander. */
static void test_alloc(void)
{
    reset_world();
    set_knobs(0, 32, 32);
    tick();
    int32_t before = vintage_global_temp();
    struct vintage_osc o0 = *vintage_osc_state(0);
    voice_loop_index = 0;
    vintage_osc_pitch_alloc(osc_mem[0], 0);
    int32_t from_alloc = out_of(osc_mem[0], 0);
    vintage_osc_pitch_alloc(osc_mem[0], 0);
    check(memcmp(&o0, vintage_osc_state(0), sizeof o0) == 0 && before == vintage_global_temp(),
          "note-on doesn't advance the wander", NULL, 0, 0);
    voice_loop_index = 0;
    vintage_osc_pitch_tick(osc_mem[0], 0);   /* v 0, o 0: also advances one tick */
    check(abs(out_of(osc_mem[0], 0) - from_alloc) <= 1, "note-on pitch = tick pitch", NULL, 0, 0);
}

/* Limits: extreme settings stay within +-50 c and osc_pitch's range; at
 * normal settings, 30 minutes without a single limit. */
static void test_limits_and_long_run(void)
{
    reset_world();
    set_knobs(0, 127, 127);
    vintage_key_scale = 127;
    vintage_profile = VINTAGE_SSM2030;
    int ok = 1;
    for (int t = 0; t < 60000; t++) {
        for (uint32_t v = 0; v < 16; v++)
            set_note(v, v & 1 ? 0 : 120);
        tick();
        for (uint32_t v = 0; v < 16; v++)
            for (uint32_t o = 0; o < 3; o++) {
                int32_t x = out_of(osc_mem[o], v);
                ok &= x >= -43691 && x <= 43689 && fabs(cents(x - reference(v, o, 0))) <= 50.1;
            }
    }
    check(ok, "extreme settings: within +-50 c and osc_pitch's range", " (limit used %g times, as expected%.0s)", vintage_clamp_hits, 0);

    reset_world();
    set_knobs(0, 32, 32);
    double g2 = 0, b2 = 0;
    int32_t gmax = 0, bmax = 0;
    long n = 0;
    for (int t = 0; t < 30 * 60 * 1000; t++) {
        for (uint32_t v = 0; v < 16; v++)
            set_note(v, 24 + (int)((v * 7 + t / 1000) % 72));   /* C1..B6, changing */
        tick();
        if (t % 100 == 0) {
            int32_t g = vintage_global_temp(), b = vintage_osc_state(t / 100 % 48)->band[0];
            g2 += (double)g * g;
            b2 += (double)b * b;
            if (abs(g) > gmax) gmax = abs(g);
            if (abs(b) > bmax) bmax = abs(b);
            n++;
        }
    }
    check(vintage_clamp_hits == 0, "30 minutes at knobs 32, C1-B6: limit never used", " (%g hits%.0s)", vintage_clamp_hits, 0);
    double gsd = sqrt(g2 / n) / 65536, bsd = sqrt(b2 / n) / 65536;
    check(gsd > 0.4 && gsd < 1.8 && gmax < 6 * 65536, "temperature stays bounded, about 1 degC sd", " (sd %.2f, max %.2f degC)", gsd, gmax / 65536.0);
    check(bsd > 0.7 && bsd < 1.3 && bmax < 6 * 65536, "1/f wander stays bounded, sd about 1", " (sd %.2f, max %.2f)", bsd, bmax / 65536.0);
}

int main(void)
{
    test_off_is_stock();
    test_stock_terms_replaced();
    test_voices_unique();
    test_drift_independent();
    test_shape();
    test_multi();
    test_alloc();
    test_limits_and_long_run();
    printf("%s: %d failure(s)\n", failures ? "FAILED" : "PASSED", failures);
    return failures ? 1 : 0;
}
