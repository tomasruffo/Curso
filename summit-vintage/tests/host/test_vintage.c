/* Host tests for the vintage patch: the patch's own C (vintage_model.c,
 * vintage_hooks.c, vintage_inner_stock.c) against a stand-in firmware that
 * follows the documented code (gipfel_mpe docs/findings, "The osc_pitch
 * struct", and osc_drift_update at 0x08013844):
 *
 *   osc_drift[3p + o] = (walk >> 23) x drift_amount[p] >> 7      every tick
 *   sum = note + diverge_amount[p] x diverge_rand[3v + o] >> 5 + osc_drift[3p + o]
 *   out = (s16) sum x 0x5555 >> 14                              (4,096 per octave)
 *
 * One tick: stock's drift update, osc_pitch for every voice and oscillator,
 * then mod_update(1), which the patch hooks. Build and run: tests/host/run.sh
 */

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "firmware.h"
#include "../../patches/vintage/vintage.h"

/* ---- the stand-in firmware ------------------------------------------- */

volatile uint8_t multi_mode;
volatile uint8_t voice_loop_index;
volatile uint8_t voice_note[16];
uint8_t patches[3][0x201];
uint8_t diverge_amount[2];
uint16_t drift_amount[2];
int8_t osc_drift[6];
int8_t diverge_rand[48];
_Alignas(8) uint8_t osc1_pitch[0xC + 64], osc2_pitch[0xC + 64], osc3_pitch[0xC + 64];
static uint8_t *const OSC[3] = { osc1_pitch, osc2_pitch, osc3_pitch };
static int8_t STOCK_TABLE[48];
static int32_t note_sum[16];                 /* the note term, 8.8 semitones */
static int32_t stock_walk[6];                /* stock's drift walk (osc_drift_update's state) */
static int8_t table_played[48];              /* the table as this tick's osc_pitch read it */

static int32_t to_out(int32_t sum) { return ((int32_t)(int16_t)sum * 0x5555) >> 14; }

void osc_pitch(uint8_t *osc, uint32_t part)
{
    uint32_t v = voice_loop_index & 15, o = osc[0] % 3, p = part & 1;
    int32_t sum = note_sum[v] + ((diverge_amount[p] * diverge_rand[3 * v + o]) >> 5) + osc_drift[3 * p + o];
    int32_t out = to_out(sum);
    memcpy(osc + 0xC + 4 * v, &out, 4);
}

void mod_update(uint32_t part) { (void)part; }

static int32_t out_of(uint32_t v, uint32_t o)
{
    int32_t x;
    memcpy(&x, OSC[o] + 0xC + 4 * v, 4);
    return x;
}

static void set_note(uint32_t v, int midi)   /* C4 = 60: sum -1,983 */
{
    note_sum[v] = -1983 + (midi - 60) * 256;
    voice_note[v] = (uint8_t)midi;
}

static uint32_t part_of(uint32_t v) { return multi_mode && v >= 8 ? 1 : 0; }

/* As a knob or NRPN does: the patch byte, then patch_apply_osc's amounts. */
static void set_knobs(uint32_t part, int div, int drift)
{
    patches[(multi_mode ? 1 : 0) + part][0x2B] = (uint8_t)div;
    patches[(multi_mode ? 1 : 0) + part][0x2C] = (uint8_t)drift;
    diverge_amount[part] = (uint8_t)div;
    drift_amount[part] = (uint16_t)drift;
}

static unsigned stock_rng = 12345;
static void stock_drift_update(void)         /* moves on its own, as on the synth */
{
    for (int i = 0; i < 6; i++) {
        stock_rng = stock_rng * 1103515245u + 12345u;
        stock_walk[i] += ((int32_t)(stock_rng >> 1) - (1 << 30) - stock_walk[i]) >> 6;
        osc_drift[i] = (int8_t)(((stock_walk[i] >> 23) * drift_amount[i / 3]) >> 7);
    }
}

/* One mod_tick. */
static void tick(void)
{
    stock_drift_update();
    for (uint32_t v = 0; v < 16; v++) {
        voice_loop_index = (uint8_t)v;
        for (uint32_t o = 0; o < 3; o++)
            osc_pitch(OSC[o], part_of(v));
    }
    memcpy(table_played, diverge_rand, 48);
    vintage_mod_update(1);
}

/* What stock would play now: its own table and its amounts from the knobs. */
static int32_t stock_out(uint32_t v, uint32_t o)
{
    uint32_t p = part_of(v);
    const uint8_t *patch = patches[(multi_mode ? 1 : 0) + p];
    int8_t drift = (int8_t)(((stock_walk[3 * p + o] >> 23) * patch[0x2C]) >> 7);
    return to_out(note_sum[v] + ((patch[0x2B] * STOCK_TABLE[3 * v + o]) >> 5) + drift);
}

/* The pitch without any Diverge or Drift. */
static int32_t clean_out(uint32_t v) { return to_out(note_sum[v]); }

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
    diverge_amount[0] = diverge_amount[1] = 0;
    drift_amount[0] = drift_amount[1] = 0;
    vintage_off = 0;
    vintage_profile = VINTAGE_CEM3340;
    vintage_key_scale = 0;
    vintage_clamp_hits = 0;
    memcpy(diverge_rand, STOCK_TABLE, 48);
    for (uint32_t v = 0; v < 16; v++)
        set_note(v, 60);
    for (uint8_t o = 0; o < 3; o++)          /* +0: the oscillator index */
        OSC[o][0] = o;
    tick();                                  /* settle: knobs 0, nothing applied */
}

/* ---- tests ------------------------------------------------------------ */

/* Knobs at 0: the patch touches nothing and every pitch is stock's. With
 * the patch off, the same even with the knobs up, stock's Diverge and
 * Drift included. */
static void test_off_is_stock(void)
{
    reset_world();
    long diff = 0;
    for (int t = 0; t < 2000; t++) {
        for (uint32_t v = 0; v < 16; v++)
            set_note(v, 36 + (int)((v * 5 + t / 20) % 48));
        tick();
        for (uint32_t v = 0; v < 16; v++)
            for (uint32_t o = 0; o < 3; o++)
                diff += out_of(v, o) != stock_out(v, o);
    }
    check(diff == 0 && !memcmp(diverge_rand, STOCK_TABLE, 48) && !diverge_amount[0] && !drift_amount[0],
          "Diverge 0 + Drift 0: nothing touched, identical to stock", " (%g of %g pitches differ)", (double)diff, 2000.0 * 48);

    vintage_off = 1;
    set_knobs(0, 64, 100);
    diff = 0;
    for (int t = 0; t < 2000; t++) {
        tick();
        for (uint32_t v = 0; v < 16; v++)
            for (uint32_t o = 0; o < 3; o++)
                diff += out_of(v, o) != stock_out(v, o);
    }
    check(diff == 0 && !memcmp(diverge_rand, STOCK_TABLE, 48), "patch switched off: identical to stock, knobs up",
          " (%g of %g differ)", (double)diff, 2000.0 * 48);

    /* On, then switched off at run time: stock's table and amounts come back. */
    vintage_off = 0;
    for (int t = 0; t < 50; t++)
        tick();
    int was_on = memcmp(diverge_rand, STOCK_TABLE, 48) != 0 && diverge_amount[0] == 32 && drift_amount[0] == 0;
    vintage_off = 1;
    tick();
    check(was_on && !memcmp(diverge_rand, STOCK_TABLE, 48) && diverge_amount[0] == 64 && drift_amount[0] == 100,
          "switched off while on: stock's table and amounts back", NULL, 0, 0);
}

/* Knobs up: stock's shared drift is off, each pitch is the note plus its own
 * table entry, within +-50 cents. */
static void test_model_through_the_table(void)
{
    reset_world();
    set_knobs(0, 32, 32);
    int amounts = 1, drift_off = 1, exact = 1, in_range = 1, moved = 0;
    for (int t = 0; t < 1000; t++) {
        tick();
        if (t == 0)
            continue;   /* this tick's osc_pitch ran before the patch saw the knobs */
        amounts &= diverge_amount[0] == 32 && drift_amount[0] == 0;
        for (int i = 0; i < 3; i++)
            drift_off &= osc_drift[i] == 0;
        for (uint32_t v = 0; v < 16; v++)
            for (uint32_t o = 0; o < 3; o++) {
                int32_t x = out_of(v, o);
                exact &= x == to_out(note_sum[v] + table_played[3 * v + o]);
                double c = cents(x - clean_out(v));
                in_range &= fabs(c) <= 50.0;
                moved += fabs(c) > 0.05;
            }
    }
    check(amounts, "diverge_amount 32 and drift_amount 0 while on", NULL, 0, 0);
    check(drift_off, "stock's shared drift is 0", NULL, 0, 0);
    check(exact, "each pitch = note + its own table entry", NULL, 0, 0);
    check(in_range, "offset within +-50 cents", NULL, 0, 0);
    check(moved > 999 * 48 / 2, "the model moves the pitches", " (%g of %g moved)", (double)moved, 999.0 * 48);
}

/* Every one of the 16 voices has its own character (stock's voices 8-15
 * copy 0-7), and the three oscillators of a voice differ. */
static void test_voices_unique(void)
{
    reset_world();
    set_knobs(0, 32, 0);
    tick();
    int same = 0;
    for (uint32_t i = 0; i < 24; i++) {
        const struct vintage_osc *a = vintage_osc_state(i), *b = vintage_osc_state(i + 24);
        same += a->bias_u == b->bias_u || a->scale_u == b->scale_u || a->tempco_u == b->tempco_u;
    }
    check(same == 0, "voices 9-16 have their own character, not a copy of 1-8", " (%g of %g share a value)", same, 24);
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
    enum { SECONDS = 600, EVERY = 50 };
    static double s[16][SECONDS * 1000 / EVERY];
    int n = 0;
    for (int t = 0; t < SECONDS * 1000; t++) {
        tick();
        if (t % EVERY == 0) {
            for (uint32_t v = 0; v < 16; v++)
                s[v][n] = cents(out_of(v, 0) - clean_out(v));
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

/* The model's shape, on its pure functions. */
static void test_shape(void)
{
    reset_world();
    int32_t c4 = VINTAGE_C4;
    int lin = 1;
    for (uint32_t i = 0; i < 48; i++) {
        int32_t a = vintage_offset(i / 3, i % 3, 32, 32, c4);
        int32_t b = vintage_offset(i / 3, i % 3, 64, 64, c4);
        lin &= abs(b - 2 * a) <= 2;
    }
    check(lin, "knob 64 = twice knob 32", NULL, 0, 0);
    check(vintage_amount(127) > 8 * 32, "knob 127 = a neglected instrument (amount)", " (%.0f / 32 = %.1fx)", vintage_amount(127), vintage_amount(127) / 32.0);

    double sd4 = 0, sd7 = 0;
    for (uint32_t i = 0; i < 48; i++) {
        double a = cents(vintage_offset(i / 3, i % 3, 32, 0, c4));
        double b = cents(vintage_offset(i / 3, i % 3, 32, 0, c4 + 3 * 4096));
        sd4 += a * a / 48;
        sd7 += b * b / 48;
    }
    check(sqrt(sd7) > 1.5 * sqrt(sd4), "Diverge spreads more three octaves up (tracking)", " (C4 %.2f c, C7 %.2f c rms)", sqrt(sd4), sqrt(sd7));

    /* Flat top end near 8.4 kHz: the offset at hi + at the mirror note
     * below C4 - 2 x at C4 cancels the residual and the linear tracking. */
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

    int round_ok = 1;
    for (int32_t q8 = -VINTAGE_MAX_Q8; q8 <= VINTAGE_MAX_Q8; q8 += 7) {
        int32_t want = q8 > 12700 ? 12700 : q8 < -12700 ? -12700 : q8;   /* +-127 = +-49.6 c */
        round_ok &= abs(vintage_entry(q8) * 100 - want) <= 50;          /* within half a step (0.2 c) */
    }
    check(round_ok, "table entry = the offset in 1/256 semitone, rounded, +-127", NULL, 0, 0);
}

/* A new note gets its entries in the same tick, at the new note's pitch;
 * knobs turned up give every entry at once. */
static void test_new_note_and_start(void)
{
    reset_world();
    for (uint32_t v = 0; v < 16; v++)
        set_note(v, 36);
    tick();
    set_knobs(0, 64, 0);
    tick();
    int all = 1;
    for (uint32_t i = 0; i < 48; i++)
        all &= diverge_rand[i] == vintage_entry(vintage_cents_q8(i, 64, 0, out_of(i / 3, i % 3)));
    check(all, "knobs turned up: every entry written in the first tick", NULL, 0, 0);

    for (int t = 0; t < 10; t++)
        tick();
    set_note(5, 96);                          /* C2 -> C7 */
    tick();
    int ok = 1;
    for (uint32_t o = 0; o < 3; o++) {
        int8_t want = vintage_entry(vintage_cents_q8(15 + o, 64, 0, to_out(note_sum[5])));
        ok &= abs(diverge_rand[15 + o] - want) <= 1;
    }
    check(ok, "a new note's entries follow in the same tick", NULL, 0, 0);
}

/* Multi mode: each part reads its own sound's knobs; Part A at 0 is not touched. */
static void test_multi(void)
{
    reset_world();
    multi_mode = 1;
    set_knobs(0, 0, 0);     /* Part A: as stock */
    set_knobs(1, 32, 32);   /* Part B: the model */
    long a_diff = 0, b_diff = 0, a_table = 0;
    for (int t = 0; t < 200; t++) {
        tick();
        for (uint32_t v = 0; v < 16; v++)
            for (uint32_t o = 0; o < 3; o++) {
                int d = out_of(v, o) != stock_out(v, o);
                if (v < 8) {
                    a_diff += d;
                    a_table += diverge_rand[3 * v + o] != STOCK_TABLE[3 * v + o];
                } else {
                    b_diff += d;
                }
            }
    }
    check(a_diff == 0 && a_table == 0 && diverge_amount[0] == 0, "Multi: Part A (knobs 0) not touched, plays as stock", " (%g differ)", (double)a_diff, 0);
    check(b_diff > 200 * 24 / 2, "Multi: Part B (knobs 32) uses the model", " (%g of %g differ)", (double)b_diff, 200.0 * 24);
}

/* Limits, and 30 minutes at normal settings. */
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
        if (t == 0)
            continue;
        for (uint32_t v = 0; v < 16; v++)
            for (uint32_t o = 0; o < 3; o++) {
                int32_t x = out_of(v, o);
                ok &= x >= -43691 && x <= 43689 && fabs(cents(x - clean_out(v))) <= 50.0;
            }
    }
    check(ok, "extreme settings: within +-50 c and osc_pitch's range", " (limit used %g times, as expected%.0s)", vintage_clamp_hits, 0);

    reset_world();
    set_knobs(0, 32, 32);
    double g2 = 0, b2 = 0;
    int32_t gmax = 0, bmax = 0;
    long n = 0;
    for (int t = 0; t < 30 * 60 * 1000; t++) {
        if (t % 1000 == 0)
            for (uint32_t v = 0; v < 16; v++)
                set_note(v, 24 + (int)((v * 7 + t / 1000) % 72));   /* C1..B6, a new note every second */
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
    for (int i = 0; i < 48; i++)
        STOCK_TABLE[i] = (int8_t)((i * 7) % 23 - 11);       /* stock-like +-11 */
    for (int i = 0; i < 6; i++)
        stock_walk[i] = (i - 3) * (1 << 28);
    memcpy(diverge_rand, STOCK_TABLE, 48);
    test_off_is_stock();
    test_model_through_the_table();
    test_voices_unique();
    test_drift_independent();
    test_shape();
    test_new_note_and_start();
    test_multi();
    test_limits_and_long_run();
    printf("%s: %d failure(s)\n", failures ? "FAILED" : "PASSED", failures);
    return failures ? 1 : 0;
}
