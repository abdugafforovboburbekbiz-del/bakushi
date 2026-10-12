/*
 * Bakushi audio engine implementation.
 *
 * One miniaudio device (f32, stereo, 44100 Hz) mixes up to BA_MAX_VOICES
 * active voices. Voice scheduling happens in the device callback under a
 * CRITICAL_SECTION that is also taken by the public API.
 *
 * NOTE: BA_TRACE is DISABLED by default even in debug builds. fprintf from
 * the real-time audio thread - or from a public-API path that holds
 * g_lock - blocks when the console/pipe stalls (VS Code terminal with a
 * huge log), which deadlocks the mixer against the UI thread: the UI
 * freezes holding the lock and audio stops. Define BA_TRACE_ENABLED to
 * opt back in while debugging the engine itself.
 *
 * miniaudio is public domain / MIT-0: https://miniaudio.app
 */
#define MINIAUDIO_IMPLEMENTATION
#define MA_NO_DECODING
#define MA_NO_ENCODING
#define MA_NO_GENERATION
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_NODE_GRAPH
#define MA_NO_ENGINE
#define _CRT_SECURE_NO_WARNINGS

#include "bakushi_engine.h"

#include <math.h>
#include <stdio.h>
#include <windows.h>

#include <stdlib.h>
#include <string.h>

#include "miniaudio.h"

#ifdef BA_TRACE_ENABLED
#define BA_TRACE(...) fprintf(stderr, __VA_ARGS__)
#else
#define BA_TRACE(...)                                                                 \
    do {                                                                             \
    } while (0)
#endif

/* Ids: pads 0..15, stems 100..105, original 200 - keep headroom above all. */
#define BA_MAX_BUFFERS 256
#define BA_DEVICE_SAMPLE_RATE 44100

typedef struct {
    float *left;
    float *right;
    uint64_t frames;
    int loaded;
} ba_buffer_t;

typedef struct {
    int active;
    int32_t id;
    const ba_buffer_t *buf;
    double pos;      /* fractional frame position, always in [0, frames) */
    double rate;     /* playback rate (pitch) */
    double gain;     /* current live gain */
    int reverse;
    int loop;
    char choke[BA_CHOKE_LEN];
    double fade_in;          /* 0..1 multiplier */
    uint64_t fade_in_total;
    uint64_t fade_in_remain;
    int fading_out;
    uint64_t fade_out_total;
    uint64_t fade_out_remain;
} ba_voice_t;

static ba_buffer_t g_buffers[BA_MAX_BUFFERS];
static ba_voice_t g_voices[BA_MAX_VOICES];
static CRITICAL_SECTION g_lock;
static ma_device g_device;
static float g_master = 1.0f;
static int g_initialized = 0;
static ma_uint32 g_device_rate = BA_DEVICE_SAMPLE_RATE;

/* ----------------------------------------------------- master FX (Phase E)
 * One global low-pass filter + one feedback echo applied POST-MIX in the
 * device callback. When the filter and echo are both off the callback
 * returns immediately - wet=0/cutoff=0 is an EXACT passthrough (zero
 * regression for existing playback). State lives only on the audio
 * thread plus the ba_set_fx parameter write (guarded by g_lock).
 */
#define BA_FX_MAX_ECHO_MS 2000
#define BA_FX_MAX_DELAY (BA_FX_MAX_ECHO_MS * BA_DEVICE_SAMPLE_RATE / 1000)
#define BA_FX_ECHO_FEEDBACK 0.35

static double g_fx_cutoff_hz = 0.0;  /* <= 0 = filter off */
static double g_fx_echo_ms = 0.0;    /* <= 0 = echo off */
static double g_fx_wet = 0.0;        /* 0..1 */
static double g_fx_lp_l = 0.0;
static double g_fx_lp_r = 0.0;
static float g_fx_delay_l[BA_FX_MAX_DELAY];
static float g_fx_delay_r[BA_FX_MAX_DELAY];
static ma_uint32 g_fx_delay_pos = 0;
static ma_uint32 g_fx_delay_len = 0;

/* Post-mix FX: global one-pole low-pass + feedback echo, then a soft
 * clamp so the feedback can never run away. No-op when both are off. */
static void ba_apply_fx(float *out, ma_uint32 frameCount, ma_uint32 rate) {
    int lp_on = (g_fx_cutoff_hz >= 20.0 && g_fx_cutoff_hz <= 20000.0);
    int echo_on = (g_fx_echo_ms >= 1.0 && g_fx_echo_ms <= BA_FX_MAX_ECHO_MS &&
                   g_fx_wet > 0.0001);
    double c;
    ma_uint32 i;
    if (!lp_on && !echo_on) {
        return;
    }
    c = 1.0 - exp(-2.0 * 3.14159265358979323846 *
                  (lp_on ? g_fx_cutoff_hz : 20000.0) / (double)rate);
    if (echo_on) {
        g_fx_delay_len = (ma_uint32)(g_fx_echo_ms / 1000.0 * (double)rate);
        if (g_fx_delay_len < 1) {
            g_fx_delay_len = 1;
        }
        if (g_fx_delay_len > BA_FX_MAX_DELAY) {
            g_fx_delay_len = BA_FX_MAX_DELAY;
        }
        if (g_fx_delay_pos >= g_fx_delay_len) {
            g_fx_delay_pos = 0;
        }
    }
    for (i = 0; i < frameCount; i++) {
        double l = (double)out[i * 2 + 0];
        double r = (double)out[i * 2 + 1];
        if (lp_on) {
            g_fx_lp_l += c * (l - g_fx_lp_l);
            g_fx_lp_r += c * (r - g_fx_lp_r);
            l = g_fx_lp_l;
            r = g_fx_lp_r;
        }
        if (echo_on) {
            /* The slot at g_fx_delay_pos was written exactly g_fx_delay_len
             * frames ago - reading before overwriting gives the echo tap. */
            ma_uint32 ridx = g_fx_delay_pos;
            float dl = g_fx_delay_l[ridx];
            float dr = g_fx_delay_r[ridx];
            l += g_fx_wet * (double)dl;
            r += g_fx_wet * (double)dr;
            g_fx_delay_l[g_fx_delay_pos] =
                (float)(l + BA_FX_ECHO_FEEDBACK * (double)dl);
            g_fx_delay_r[g_fx_delay_pos] =
                (float)(r + BA_FX_ECHO_FEEDBACK * (double)dr);
            g_fx_delay_pos = (g_fx_delay_pos + 1) % g_fx_delay_len;
        }
        /* Soft clamp: 1.5 tanh keeps a hot master bus musical. */
        out[i * 2 + 0] = (float)(tanh(l * 1.5) / tanh(1.5));
        out[i * 2 + 1] = (float)(tanh(r * 1.5) / tanh(1.5));
    }
}

/* ---------------------------------------------------------------- helpers */

static ba_buffer_t *find_buffer(int32_t id) {
    int i;
    for (i = 0; i < BA_MAX_BUFFERS; i++) {
        if (g_buffers[i].loaded && i == id) {
            return &g_buffers[i];
        }
    }
    return NULL;
}

static int find_voice_slot(int32_t id) {
    int i;
    for (i = 0; i < BA_MAX_VOICES; i++) {
        if (g_voices[i].active && g_voices[i].id == id) {
            return i;
        }
    }
    return -1;
}

static int find_free_slot(void) {
    int i;
    for (i = 0; i < BA_MAX_VOICES; i++) {
        if (!g_voices[i].active) {
            return i;
        }
    }
    return -1;
}

static void stop_voice_quick(ba_voice_t *v) {
    BA_TRACE("[ENGINE] voice stopped id=%d pos=%.0f frames=%llu\n", v->id,
             v->pos, (unsigned long long)(v->buf ? v->buf->frames : 0));
    v->active = 0;
    v->fading_out = 0;
}

/* ------------------------------------------------------ device callback */

static void on_device_data(ma_device *pDevice, void *pOutput,
                           const void *pInput, ma_uint32 frameCount) {
    float *out = (float *)pOutput;
    ma_uint32 i;
    int v;
    (void)pInput;
    (void)pDevice;

    memset(out, 0, sizeof(float) * 2 * (size_t)frameCount);

    EnterCriticalSection(&g_lock);
    for (v = 0; v < BA_MAX_VOICES; v++) {
        ba_voice_t *vo = &g_voices[v];
        const ba_buffer_t *buf;
        if (!vo->active) {
            continue;
        }
        buf = vo->buf;
        if (buf == NULL || buf->frames == 0) {
            vo->active = 0;
            continue;
        }

        for (i = 0; i < frameCount; i++) {
            double pos = vo->pos;
            uint64_t idx;
            float sl, sr, frac;
            double fade;

            /* End-of-buffer handling. */
            if (pos >= (double)buf->frames) {
                if (vo->loop) {
                    vo->pos = pos - (double)buf->frames;
                    pos = vo->pos;
                    /* Re-arm the fade-in on every wrap: the short ramp
                       smooths the loop seam so sustained loops don't click
                       at the splice point. */
                    if (vo->fade_in_total > 0) {
                        vo->fade_in_remain = vo->fade_in_total;
                    }
                } else {
                    stop_voice_quick(vo);
                    break;
                }
            }

            idx = (uint64_t)pos;
            frac = (float)(pos - (double)idx);

            if (vo->reverse) {
                double p = (double)(buf->frames - 1) - pos;
                uint64_t i0 = (uint64_t)p;
                uint64_t i1 = (i0 > 0) ? (i0 - 1) : i0;
                float f = (float)(p - (double)i0);
                sl = buf->left[i0] * (1.0f - f) + buf->left[i1] * f;
                sr = buf->right[i0] * (1.0f - f) + buf->right[i1] * f;
            } else {
                uint64_t i0 = idx;
                uint64_t i1 = (idx + 1 < buf->frames) ? (idx + 1) : idx;
                sl = buf->left[i0] * (1.0f - frac) + buf->left[i1] * frac;
                sr = buf->right[i0] * (1.0f - frac) + buf->right[i1] * frac;
            }

            /* Fades. */
            fade = 1.0;
            if (vo->fade_in_remain > 0 && vo->fade_in_total > 0) {
                fade *= 1.0 - (double)vo->fade_in_remain /
                                  (double)vo->fade_in_total;
                vo->fade_in_remain--;
            }
            if (vo->fading_out) {
                if (vo->fade_out_remain == 0 || vo->fade_out_total == 0) {
                    stop_voice_quick(vo);
                    break;
                }
                fade *= (double)vo->fade_out_remain / (double)vo->fade_out_total;
                vo->fade_out_remain--;
                if (vo->fade_out_remain == 0) {
                    stop_voice_quick(vo);
                    /* Write the final (near-silent) sample anyway to avoid a
                       hard discontinuity at the exact end. */
                    {
                        double g = (double)(float)(vo->gain * fade *
                                                   (float)g_master);
                        out[i * 2 + 0] += (float)(sl * g);
                        out[i * 2 + 1] += (float)(sr * g);
                    }
                    break;
                }
            }

            {
                double g = vo->gain * fade * (double)g_master;
                out[i * 2 + 0] += (float)(sl * g);
                out[i * 2 + 1] += (float)(sr * g);
            }

            vo->pos += vo->rate;
            if (vo->pos < 0.0) {
                vo->pos = 0.0;
            }
        }
    }
    LeaveCriticalSection(&g_lock);

    /* Master FX after the mix (audio thread only state). */
    ba_apply_fx(out, frameCount, (ma_uint32)pDevice->sampleRate);
}

/* ----------------------------------------------------------- public API */

BA_API int ba_init(void) {
    ma_device_config cfg;

    if (g_initialized) {
        return 0;
    }
    memset(g_buffers, 0, sizeof(g_buffers));
    memset(g_voices, 0, sizeof(g_voices));
    InitializeCriticalSection(&g_lock);

    cfg = ma_device_config_init(ma_device_type_playback);
    cfg.playback.format = ma_format_f32;
    cfg.playback.channels = 2;
    cfg.sampleRate = BA_DEVICE_SAMPLE_RATE;
    cfg.dataCallback = on_device_data;
    cfg.pUserData = NULL;

    if (ma_device_init(NULL, &cfg, &g_device) != MA_SUCCESS) {
        DeleteCriticalSection(&g_lock);
        return -1;
    }
    g_device_rate = g_device.sampleRate;
    if (ma_device_start(&g_device) != MA_SUCCESS) {
        ma_device_uninit(&g_device);
        DeleteCriticalSection(&g_lock);
        return -2;
    }
    g_initialized = 1;
    return 0;
}

BA_API void ba_shutdown(void) {
    if (!g_initialized) {
        return;
    }
    ma_device_uninit(&g_device);
    EnterCriticalSection(&g_lock);
    {
        int i;
        for (i = 0; i < BA_MAX_BUFFERS; i++) {
            if (g_buffers[i].loaded) {
                free(g_buffers[i].left);
                free(g_buffers[i].right);
                g_buffers[i].left = NULL;
                g_buffers[i].right = NULL;
                g_buffers[i].loaded = 0;
            }
        }
        memset(g_voices, 0, sizeof(g_voices));
    }
    LeaveCriticalSection(&g_lock);
    DeleteCriticalSection(&g_lock);
    g_initialized = 0;
}

BA_API int ba_load_buffer(int32_t id, const float *left, const float *right,
                          uint64_t frames) {
    BA_TRACE("[ENGINE] ba_load_buffer id=%d frames=%llu\n", id,
             (unsigned long long)frames);
    float *lc = NULL;
    float *rc = NULL;
    if (id < 0 || id >= BA_MAX_BUFFERS) {
        return -1;
    }
    if (frames > 0) {
        size_t bytes = (size_t)frames * sizeof(float);
        lc = (float *)malloc(bytes);
        rc = (float *)malloc(bytes);
        if (lc == NULL || rc == NULL) {
            free(lc);
            free(rc);
            fprintf(stderr,
                    "[ENGINE] ba_load_buffer id=%d FAILED malloc "
                    "frames=%llu bytes=%llu\n",
                    id, (unsigned long long)frames,
                    (unsigned long long)bytes);
            return -2;
        }
        memcpy(lc, left, bytes);
        memcpy(rc, right, bytes);
    }
    EnterCriticalSection(&g_lock);
    {
        int slot = find_voice_slot(id);
        if (slot >= 0) {
            g_voices[slot].active = 0; /* silence old voice while swapping */
        }
        if (g_buffers[id].loaded) {
            free(g_buffers[id].left);
            free(g_buffers[id].right);
        }
        g_buffers[id].left = lc;
        g_buffers[id].right = rc;
        g_buffers[id].frames = frames;
        g_buffers[id].loaded = 1;
    }
    LeaveCriticalSection(&g_lock);
    BA_TRACE("[ENGINE] ba_load_buffer id=%d rc=0 frames=%llu\n", id,
             (unsigned long long)frames);
    return 0;
}

BA_API void ba_unload_buffer(int32_t id) {
    if (id < 0 || id >= BA_MAX_BUFFERS) {
        return;
    }
    EnterCriticalSection(&g_lock);
    {
        int slot = find_voice_slot(id);
        if (slot >= 0) {
            g_voices[slot].active = 0;
        }
        if (g_buffers[id].loaded) {
            free(g_buffers[id].left);
            free(g_buffers[id].right);
            g_buffers[id].left = NULL;
            g_buffers[id].right = NULL;
            g_buffers[id].loaded = 0;
        }
    }
    LeaveCriticalSection(&g_lock);
}

BA_API int ba_play_at(int32_t id, uint64_t start_frame, double gain,
                      double pitch, int reverse, int loop,
                      const char *choke_group, uint32_t fade_frames) {
    ba_buffer_t *buf;
    ba_voice_t *vo = NULL;
    int result = 0;
    int i;

    if (!g_initialized) {
        return -10;
    }
    if (pitch <= 0.0) {
        pitch = 1.0;
    }

    EnterCriticalSection(&g_lock);
    buf = find_buffer(id);
    if (buf == NULL || buf->frames == 0) {
        LeaveCriticalSection(&g_lock);
        return -3;
    }

    {
        int slot = find_voice_slot(id);
        if (slot >= 0) {
            vo = &g_voices[slot];
        } else {
            int free_slot = find_free_slot();
            if (free_slot < 0) {
                LeaveCriticalSection(&g_lock);
                return -4;
            }
            vo = &g_voices[free_slot];
            memset(vo, 0, sizeof(*vo));
            vo->gain = gain;
        }
    }

    /* Retrigger restarts the voice but keeps the live gain. */
    vo->id = id;
    vo->buf = buf;
    vo->rate = pitch;
    vo->reverse = reverse ? 1 : 0;
    vo->loop = loop ? 1 : 0;
    vo->fade_in_total = fade_frames;
    vo->fade_in_remain = fade_frames;
    vo->fading_out = 0;
    vo->fade_out_total = fade_frames;
    vo->fade_out_remain = 0;
    vo->choke[0] = '\0';
    if (choke_group != NULL) {
        strncpy(vo->choke, choke_group, BA_CHOKE_LEN - 1);
        vo->choke[BA_CHOKE_LEN - 1] = '\0';
    }
    if (start_frame >= buf->frames) {
        if (loop) {
            start_frame %= buf->frames;
        } else {
            vo->active = 0;
            LeaveCriticalSection(&g_lock);
            return 0; /* nothing to play */
        }
    }
    vo->pos = (double)start_frame;
    vo->active = 1;
    BA_TRACE("[ENGINE] ba_play_at id=%d frames=%llu active=%d rate=%.4f\n", id,
             (unsigned long long)buf->frames, vo->active, vo->rate);

    /* Choke: stop other voices in the same group. */
    if (vo->choke[0] != '\0') {
        for (i = 0; i < BA_MAX_VOICES; i++) {
            ba_voice_t *other = &g_voices[i];
            if (!other->active || other == vo) {
                continue;
            }
            if (strcmp(other->choke, vo->choke) == 0) {
                if (fade_frames > 0) {
                    other->fading_out = 1;
                    other->fade_out_total = fade_frames;
                    other->fade_out_remain = fade_frames;
                } else {
                    other->active = 0;
                }
            }
        }
    }
    LeaveCriticalSection(&g_lock);
    return result;
}

BA_API int ba_play(int32_t id, double gain, double pitch, int reverse, int loop,
                   const char *choke_group, uint32_t fade_frames) {
    return ba_play_at(id, 0, gain, pitch, reverse, loop, choke_group,
                      fade_frames);
}

BA_API void ba_stop(int32_t id) {
    BA_TRACE("[ENGINE] ba_stop id=%d\n", id);
    if (!g_initialized) {
        return;
    }
    EnterCriticalSection(&g_lock);
    {
        int slot = find_voice_slot(id);
        if (slot >= 0) {
            ba_voice_t *vo = &g_voices[slot];
            if (vo->fade_out_total > 0) {
                vo->fading_out = 1;
                vo->fade_out_remain = vo->fade_out_total;
            } else {
                vo->active = 0;
            }
        }
    }
    LeaveCriticalSection(&g_lock);
}

BA_API void ba_stop_group(const char *choke_group) {
    int i;
    if (!g_initialized || choke_group == NULL) {
        return;
    }
    EnterCriticalSection(&g_lock);
    for (i = 0; i < BA_MAX_VOICES; i++) {
        ba_voice_t *vo = &g_voices[i];
        if (!vo->active) {
            continue;
        }
        if (strcmp(vo->choke, choke_group) == 0) {
            if (vo->fade_out_total > 0) {
                vo->fading_out = 1;
                vo->fade_out_remain = vo->fade_out_total;
            } else {
                vo->active = 0;
            }
        }
    }
    LeaveCriticalSection(&g_lock);
}

BA_API void ba_stop_all(void) {
    int i;
    if (!g_initialized) {
        return;
    }
    EnterCriticalSection(&g_lock);
    for (i = 0; i < BA_MAX_VOICES; i++) {
        g_voices[i].active = 0;
        g_voices[i].fading_out = 0;
    }
    LeaveCriticalSection(&g_lock);
}

BA_API void ba_set_voice_gain(int32_t id, double gain) {
    if (!g_initialized) {
        return;
    }
    EnterCriticalSection(&g_lock);
    {
        int slot = find_voice_slot(id);
        if (slot >= 0) {
            g_voices[slot].gain = gain;
        }
    }
    LeaveCriticalSection(&g_lock);
}

BA_API void ba_set_master_gain(double gain) {
    g_master = (float)gain;
}

/* Phase E: global master FX. cutoff_hz <= 0 disables the low-pass;
 * echo_ms <= 0 or wet <= 0 disables the echo. All zero = EXACT
 * passthrough (zero regression). */
BA_API void ba_set_fx(double cutoff_hz, double echo_ms, double wet) {
    EnterCriticalSection(&g_lock);
    g_fx_cutoff_hz = cutoff_hz;
    g_fx_echo_ms = echo_ms;
    g_fx_wet = wet;
    if (g_fx_wet < 0.0) {
        g_fx_wet = 0.0;
    }
    if (g_fx_wet > 1.0) {
        g_fx_wet = 1.0;
    }
    LeaveCriticalSection(&g_lock);
}

BA_API int64_t ba_get_position(int32_t id) {
    static int trace_counter = 0;
    int64_t pos = -1;
    if (!g_initialized) {
        return -1;
    }
    EnterCriticalSection(&g_lock);
    {
        int slot = find_voice_slot(id);
        if (slot >= 0) {
            pos = (int64_t)g_voices[slot].pos;
        }
    }
    LeaveCriticalSection(&g_lock);
    if ((trace_counter++ % 30) == 0) {
        BA_TRACE("[ENGINE] ba_get_position id=%d -> %lld\n", id,
                 (long long)pos);
    }
    return pos;
}

BA_API int ba_is_playing(int32_t id) {
    static int trace_counter = 0;
    int playing = 0;
    if (!g_initialized) {
        return 0;
    }
    EnterCriticalSection(&g_lock);
    {
        int slot = find_voice_slot(id);
        /* A voice that received ba_stop is fading out but no longer
         * "playing" from the caller's perspective: it will not sound
         * again and its slot is about to be freed. */
        if (slot >= 0 && !g_voices[slot].fading_out) {
            playing = 1;
        }
    }
    LeaveCriticalSection(&g_lock);
    if ((trace_counter++ % 480) == 0) {
        BA_TRACE("[ENGINE] ba_is_playing id=%d -> %d\n", id, playing);
    }
    return playing;
}

BA_API int ba_device_sample_rate(void) {
    return (int)g_device_rate;
}
