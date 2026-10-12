/*
 * Bakushi audio engine - public C API.
 *
 * A small low-latency mixer built on miniaudio (WASAPI on Windows).
 * The device runs at 44100 Hz stereo float32. Any number of PCM buffers
 * can be loaded and played as voices with gain, pitch (playback rate),
 * reverse playback, looping and choke groups.
 *
 * License: MIT (this file). miniaudio.h is public domain / MIT-0.
 */
#ifndef BAKUSHI_ENGINE_H
#define BAKUSHI_ENGINE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32)
#if defined(BA_BUILD)
#define BA_API __declspec(dllexport)
#else
#define BA_API __declspec(dllimport)
#endif
#else
#define BA_API
#endif

#define BA_MAX_VOICES 32
#define BA_CHOKE_LEN 32

/*
 * Initialize the audio device. Returns 0 on success.
 * Safe to call once at app startup.
 */
BA_API int ba_init(void);

/* Shut down the device and release all buffers/voices. */
BA_API void ba_shutdown(void);

/*
 * Load a stereo PCM buffer under an integer id (copies the data).
 * `sample_rate` is informational; playback always runs at the device rate
 * (44100). Returns 0 on success.
 */
BA_API int ba_load_buffer(int32_t id, const float *left, const float *right,
                          uint64_t frames);

/* Free a loaded buffer and stop its voice. */
BA_API void ba_unload_buffer(int32_t id);

/*
 * Trigger a voice.
 *   gain        : linear gain (1.0 = unity)
 *   pitch       : playback rate multiplier (2^(semitones/12))
 *   reverse     : play backwards when non-zero
 *   loop        : repeat until stopped when non-zero
 *   choke_group : optional group name; starting a voice stops (with fade)
 *                 other active voices in the same group
 *   fade_frames : length of the click-avoiding fade in/out (0 = none)
 * Returns 0 on success. Retriggering an already-playing id restarts it.
 */
BA_API int ba_play(int32_t id, double gain, double pitch, int reverse, int loop,
                   const char *choke_group, uint32_t fade_frames);

/* Same as ba_play but starts at an explicit frame offset (transport resume). */
BA_API int ba_play_at(int32_t id, uint64_t start_frame, double gain,
                      double pitch, int reverse, int loop,
                      const char *choke_group, uint32_t fade_frames);

/* Stop one voice (with fade when fade_frames > 0 is set at play time). */
BA_API void ba_stop(int32_t id);

/* Stop all voices whose choke group matches. */
BA_API void ba_stop_group(const char *choke_group);

/* Stop everything. */
BA_API void ba_stop_all(void);

/* Live gain update for a voice (mixer mute/solo). */
BA_API void ba_set_voice_gain(int32_t id, double gain);

/* Master gain applied to every voice. */
BA_API void ba_set_master_gain(double gain);

/* Phase E: global master FX (low-pass + feedback echo, post-mix).
 * cutoff_hz <= 0 disables the filter; echo_ms <= 0 or wet <= 0
 * disables the echo. All zero = exact passthrough. */
BA_API void ba_set_fx(double cutoff_hz, double echo_ms, double wet);

/* Current playhead frame of the voice, or -1 when inactive. */
BA_API int64_t ba_get_position(int32_t id);

/* Non-zero when the voice is currently active. */
BA_API int ba_is_playing(int32_t id);

/* Actual device sample rate (expected 44100). */
BA_API int ba_device_sample_rate(void);

#ifdef __cplusplus
}
#endif

#endif /* BAKUSHI_ENGINE_H */
