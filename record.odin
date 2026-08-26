package music_trainer

import "core:c"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:time"

import rl "vendor:raylib"

RECORD_CHANNELS :: 2
RECORD_SAMPLE_RATE :: 44100
// ~10 minutes max at stereo 44100
RECORD_MAX_SAMPLES :: RECORD_SAMPLE_RATE * RECORD_CHANNELS * 60 * 10

@(private = "file")
record_buffer: [RECORD_MAX_SAMPLES]f32

@(private = "file")
record_pos: int

@(private = "file")
recording_active: bool

record_callback :: proc "c" (buffer_data: rawptr, frames: c.uint) {
	if !recording_active do return

	sample_count := int(frames) * RECORD_CHANNELS
	remaining := RECORD_MAX_SAMPLES - record_pos
	to_copy := min(sample_count, remaining)
	if to_copy <= 0 do return

	src := cast([^]f32)buffer_data
	for i in 0 ..< to_copy {
		record_buffer[record_pos + i] = src[i]
	}
	record_pos += to_copy
}

start_recording :: proc(state: ^App_State) {
	if state.is_recording do return

	record_pos = 0
	recording_active = true
	state.is_recording = true

	rl.AttachAudioMixedProcessor(record_callback)
	state.download_status = "Recording..."
}

stop_recording :: proc(state: ^App_State) {
	if !state.is_recording do return

	recording_active = false
	state.is_recording = false
	rl.DetachAudioMixedProcessor(record_callback)

	if record_pos == 0 {
		state.download_status = "Nothing recorded"
		return
	}

	path := save_recording(state)
	if len(path) > 0 {
		state.download_status = rl.TextFormat("Saved recording: %s", strings.clone_to_cstring(path, context.temp_allocator))
		scan_library(state)
	} else {
		state.download_status = "Failed to save recording"
	}
}

save_recording :: proc(state: ^App_State) -> string {
	dir := get_download_dir()

	now := time.now()
	y, mon, d := time.date(now)
	h, m, s := time.clock(now)
	filename := fmt.tprintf("recording_%04d%02d%02d_%02d%02d%02d.wav", y, int(mon), d, h, m, s)
	path := strings.concatenate({dir, "/", filename})

	total_samples := record_pos
	total_frames := total_samples / RECORD_CHANNELS
	data_size := total_samples * size_of(f32)

	// WAV uses 16-bit PCM for compatibility — convert from f32
	pcm_data_size := total_samples * 2
	pcm := make([]i16, total_samples)
	defer delete(pcm)

	for i in 0 ..< total_samples {
		sample := record_buffer[i]
		if sample > 1.0 do sample = 1.0
		if sample < -1.0 do sample = -1.0
		pcm[i] = i16(sample * 32767.0)
	}

	fd, open_err := os.open(path, {.Write, .Create, .Trunc})
	if open_err != nil {
		fmt.eprintfln("Failed to create recording file: %v", open_err)
		return ""
	}
	defer os.close(fd)

	write_u32_le :: proc(fd: ^os.File, val: u32) {
		bytes := transmute([4]u8)val
		os.write(fd, bytes[:])
	}
	write_u16_le :: proc(fd: ^os.File, val: u16) {
		bytes := transmute([2]u8)val
		os.write(fd, bytes[:])
	}

	// RIFF header
	os.write_string(fd, "RIFF")
	write_u32_le(fd, u32(36 + pcm_data_size))
	os.write_string(fd, "WAVE")

	// fmt chunk
	os.write_string(fd, "fmt ")
	write_u32_le(fd, 16) // chunk size
	write_u16_le(fd, 1)  // PCM format
	write_u16_le(fd, RECORD_CHANNELS)
	write_u32_le(fd, RECORD_SAMPLE_RATE)
	byte_rate := u32(RECORD_SAMPLE_RATE * RECORD_CHANNELS * 2)
	write_u32_le(fd, byte_rate)
	write_u16_le(fd, RECORD_CHANNELS * 2) // block align
	write_u16_le(fd, 16) // bits per sample

	// data chunk
	os.write_string(fd, "data")
	write_u32_le(fd, u32(pcm_data_size))
	pcm_bytes := mem.slice_to_bytes(pcm)
	os.write(fd, pcm_bytes)

	return path
}
