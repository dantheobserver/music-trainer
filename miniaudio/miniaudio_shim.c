/* miniaudio capture shim for Music Trainer.
 *
 * A thin C wrapper around miniaudio that exposes just enough to record
 * system/loopback audio on Linux (PulseAudio monitor sources) and macOS
 * (BlackHole or the microphone):
 *
 *   shim_capture_enumerate()   refresh the capture-device list
 *   shim_capture_start(index)  open a device, s16 stereo @48 kHz
 *   shim_capture_poll(buf, n)  drain captured bytes from the internal ring
 *   shim_capture_stop()        stop and release the device
 *
 * The miniaudio data callback runs on its own audio thread and copies raw
 * samples into a single-producer/single-consumer ring buffer; the main
 * thread drains it every frame, mirroring the previous parec-pipe design.
 *
 * Build (Odin links the object directly):
 *   cc -O2 -c miniaudio_shim.c -o miniaudio.o
 * Self-test (enumerate devices, capture 1.5 s, print peak level):
 *   clang -DSHIM_SELFTEST miniaudio_shim.c -o ma_selftest && ./ma_selftest
 *
 * NOTE: the shim deliberately does NOT compile miniaudio's implementation.
 * raylib's raudio.o already embeds miniaudio 0.11.24 (same header version
 * as this file) and exports its ma_* symbols, so the shim's references bind
 * to raylib's copy at link time — two full implementations would collide.
 * The self-test defines the implementation itself to run standalone.
 */
#ifdef SHIM_SELFTEST
#define MINIAUDIO_IMPLEMENTATION
#endif
#include "miniaudio.h"

#include <string.h>
#include <stdio.h>

#define SHIM_MAX_DEVICES 64
/* 2 MiB ≈ 10.9 s of s16 stereo at 48 kHz — ample headroom for one frame's
   worth of polling at 60 fps (~3.2 KB/frame). */
#define SHIM_RING_BYTES (1u << 21)

static ma_context g_ctx;
static int g_ctx_ok;

static ma_device g_dev;
static int g_active;

static ma_device_info g_capture[SHIM_MAX_DEVICES];
static int g_capture_count;

static unsigned int g_rate = 48000;
static unsigned int g_channels = 2;

/* Monotonic byte cursors into the ring (wrapping via modulo). The writer is
   the audio callback, the reader is shim_capture_poll on the main thread. */
static unsigned char g_ring[SHIM_RING_BYTES];
static unsigned long long g_ring_w, g_ring_r;

static void
data_cb(ma_device *pDevice, void *pOutput, const void *pInput, ma_uint32 frameCount)
{
	(void)pDevice;
	(void)pOutput;
	if (pInput == NULL || frameCount == 0) {
		return;
	}

	size_t bytes = (size_t)frameCount * g_channels * sizeof(short);
	const unsigned char *src = (const unsigned char *)pInput;

	/* Drop oldest data if the reader has fallen too far behind. */
	if (g_ring_w - g_ring_r + bytes > SHIM_RING_BYTES) {
		g_ring_r = g_ring_w + bytes - SHIM_RING_BYTES;
	}

	while (bytes > 0) {
		size_t pos = (size_t)(g_ring_w % SHIM_RING_BYTES);
		size_t contiguous = SHIM_RING_BYTES - pos;
		if (contiguous > bytes) {
			contiguous = bytes;
		}
		memcpy(g_ring + pos, src, contiguous);
		g_ring_w += contiguous;
		src += contiguous;
		bytes -= contiguous;
	}
}

int
shim_capture_enumerate(void)
{
	if (g_ctx_ok) {
		ma_context_uninit(&g_ctx);
		g_ctx_ok = 0;
	}
	if (ma_context_init(NULL, 0, NULL, &g_ctx) != MA_SUCCESS) {
		return -1;
	}
	g_ctx_ok = 1;

	ma_device_info *playback;
	ma_uint32 playback_count;
	ma_device_info *capture;
	ma_uint32 capture_count;
	if (ma_context_get_devices(&g_ctx, &playback, &playback_count, &capture,
	                           &capture_count) != MA_SUCCESS) {
		return -1;
	}

	g_capture_count = 0;
	for (ma_uint32 i = 0; i < capture_count && g_capture_count < SHIM_MAX_DEVICES; i++) {
		g_capture[g_capture_count++] = capture[i];
	}
	return g_capture_count;
}

int
shim_capture_device_count(void)
{
	return g_capture_count;
}

const char *
shim_capture_device_name(int index)
{
	if (index < 0 || index >= g_capture_count) {
		return "";
	}
	return g_capture[index].name;
}

int
shim_capture_device_is_default(int index)
{
	if (index < 0 || index >= g_capture_count) {
		return 0;
	}
	return g_capture[index].isDefault ? 1 : 0;
}

int
shim_capture_start(int device_index, unsigned int sample_rate, unsigned int channels)
{
	if (g_active) {
		return 0; /* already capturing */
	}
	if (!g_ctx_ok && shim_capture_enumerate() < 0) {
		return -1;
	}

	ma_device_config config = ma_device_config_init(ma_device_type_capture);
	config.capture.format = ma_format_s16;
	config.capture.channels = channels;
	config.sampleRate = sample_rate;
	config.dataCallback = data_cb;
	config.periodSizeInFrames = 960; /* ~20 ms at 48 kHz */
	if (device_index >= 0 && device_index < g_capture_count) {
		config.capture.pDeviceID = &g_capture[device_index].id;
	} /* else: backend default device */

	if (ma_device_init(&g_ctx, &config, &g_dev) != MA_SUCCESS) {
		return -1;
	}
	/* miniaudio's device layer converts to the requested format, so these
	   reflect what the callback will deliver. */
	g_rate = g_dev.sampleRate;
	g_channels = g_dev.capture.channels;
	g_ring_w = g_ring_r = 0;

	if (ma_device_start(&g_dev) != MA_SUCCESS) {
		ma_device_uninit(&g_dev);
		return -1;
	}
	g_active = 1;
	return 0;
}

void
shim_capture_stop(void)
{
	if (!g_active) {
		return;
	}
	ma_device_stop(&g_dev);
	ma_device_uninit(&g_dev);
	g_active = 0;
}

unsigned int
shim_capture_sample_rate(void)
{
	return g_rate;
}

unsigned int
shim_capture_channels(void)
{
	return g_channels;
}

/* Copy whatever has accumulated since the last call. Returns bytes copied. */
int
shim_capture_poll(unsigned char *dst, int max_bytes)
{
	int total = 0;
	while (total < max_bytes) {
		unsigned long long w = g_ring_w;
		unsigned long long r = g_ring_r;
		if (w == r) {
			break;
		}
		unsigned long long avail = w - r;
		if (avail > (unsigned long long)(max_bytes - total)) {
			avail = (unsigned long long)(max_bytes - total);
		}
		size_t pos = (size_t)(r % SHIM_RING_BYTES);
		size_t contiguous = SHIM_RING_BYTES - (size_t)pos;
		if ((unsigned long long)contiguous > avail) {
			contiguous = (size_t)avail;
		}
		memcpy(dst + total, g_ring + pos, contiguous);
		g_ring_r = r + contiguous;
		total += (int)contiguous;
	}
	return total;
}

#ifdef SHIM_SELFTEST
static int
contains_ci(const char *hay, const char *needle)
{
	for (const char *h = hay; *h; h++) {
		const char *a = h, *b = needle;
		while (*a && *b &&
		       (*a == *b || (*a >= 'A' && *a <= 'Z' && *a - *b == 'A' - 'a') ||
		        (*b >= 'A' && *b <= 'Z' && *b - *a == 'A' - 'a'))) {
			a++;
			b++;
		}
		if (*b == 0) {
			return 1;
		}
	}
	return 0;
}

int
main(int argc, char **argv)
{
	int n = shim_capture_enumerate();
	printf("capture devices: %d\n", n);
	for (int i = 0; i < n; i++) {
		printf("  [%d]%s %s\n", i,
		       shim_capture_device_is_default(i) ? "*" : " ",
		       shim_capture_device_name(i));
	}

	/* Auto-select: monitor first (Linux system audio), then BlackHole (macOS),
	   then the marked default. */
	/* argv[1] (optional): force a device index for testing. */
	int sel = -1;
	if (argc > 1) {
		sel = atoi(argv[1]);
	}
	for (int i = 0; i < n && sel < 0; i++) {
		if (contains_ci(shim_capture_device_name(i), "monitor")) {
			sel = i;
		}
	}
	for (int i = 0; i < n && sel < 0; i++) {
		if (contains_ci(shim_capture_device_name(i), "blackhole")) {
			sel = i;
		}
	}
	for (int i = 0; i < n && sel < 0; i++) {
		if (shim_capture_device_is_default(i)) {
			sel = i;
		}
	}
	if (sel < 0) {
		sel = 0;
	}
	printf("selected: [%d] %s\n", sel, n > 0 ? shim_capture_device_name(sel) : "(none)");
	if (n == 0 || shim_capture_start(sel, 48000, 2) != 0) {
		printf("capture failed to start\n");
		return 1;
	}
	printf("capturing at %u Hz, %u ch...\n", shim_capture_sample_rate(),
	       shim_capture_channels());

	double peak = 0.0;
	int total_bytes = 0;
	for (int iter = 0; iter < 30; iter++) { /* ~1.5 s at 50 ms */
		unsigned char buf[16384];
		int nsleep;
		int got;
		do {
			got = shim_capture_poll(buf, (int)sizeof(buf));
			for (int i = 0; i < got; i += 2) {
				short s = (short)((unsigned)buf[i] | ((unsigned)buf[i + 1] << 8));
				double f = (double)s / 32768.0;
				if (f < 0) {
					f = -f;
				}
				if (f > peak) {
					peak = f;
				}
			}
			total_bytes += got;
		} while (got > 0);
		for (nsleep = 0; nsleep < 50; nsleep++) {
			struct timespec ts = {0, 10000000}; /* 10 ms */
			nanosleep(&ts, NULL);
		}
	}
	shim_capture_stop();
	printf("captured %d bytes, peak amplitude %.4f\n", total_bytes, peak);
	return total_bytes > 0 ? 0 : 2;
}
#endif