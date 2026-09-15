// Thin Odin bindings for the miniaudio capture shim (miniaudio_shim.c).
//
// The shim enumerates capture devices (PulseAudio monitor sources on Linux,
// BlackHole / microphone on macOS) and streams s16 interleaved stereo at a
// fixed sample rate into an internal ring buffer, which the main thread
// drains with shim_capture_poll once per frame.
package miniaudio

import "core:c"

foreign import lib {"miniaudio.o"}

foreign lib {
	// Re-scan capture devices. Returns the device count, or -1 on failure.
	// Names and default flags stay valid until the next call.
	shim_capture_enumerate :: proc() -> c.int ---

	shim_capture_device_count :: proc() -> c.int ---

	// Device name, e.g. "Monitor of Built-in Audio Analog Stereo" (Linux,
	// PulseAudio) or "BlackHole 2ch" (macOS). Empty string if out of range.
	shim_capture_device_name :: proc(index: c.int) -> cstring ---

	// Nonzero when the device is the backend's default capture device.
	shim_capture_device_is_default :: proc(index: c.int) -> c.int ---

	// Start capturing from the given device (or the backend default when
	// index < 0). Samples arrive as interleaved s16 stereo at sample_rate.
	// Returns 0 on success, -1 on failure.
	shim_capture_start :: proc(index: c.int, sample_rate: c.uint, channels: c.uint) -> c.int ---

	shim_capture_stop :: proc() ---

	// Copy captured bytes (interleaved s16 stereo) into dst. Returns the
	// byte count drained, which may be 0.
	shim_capture_poll :: proc(dst: rawptr, max_bytes: c.int) -> c.int ---

	// The sample rate the capture stream actually runs at (equals the
	// requested rate — miniaudio converts internally).
	shim_capture_sample_rate :: proc() -> c.uint ---

	shim_capture_channels :: proc() -> c.uint ---
}