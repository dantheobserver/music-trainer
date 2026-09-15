package music_trainer

import "core:c"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:time"

import ma "miniaudio"
import rl "vendor:raylib"

// Set a persistent status-bar message. fmt.ctprintf allocates from the temp
// allocator, which main resets every frame — the message must live on the
// heap instead. The previous heap-backed message is freed on replace.
set_statusf :: proc(state: ^App_State, format: string, args: ..any) {
	if state.status_owned != nil {
		delete(state.status_owned, context.allocator)
	}
	state.status_owned = strings.clone_to_cstring(fmt.tprintf(format, args), context.allocator)
	state.download_status = state.status_owned
}

// Records system audio through miniaudio capture devices. On Linux the
// capture list contains PulseAudio monitor sources, so the app grabs
// whatever is playing system-wide; on macOS it captures the microphone, or
// BlackHole when the user has installed it (see README). Samples arrive as
// interleaved s16 stereo in a ring buffer inside the C shim, drained by
// poll_recording every frame. On stop, the accumulated samples are written
// as a WAV and the file is loaded immediately.

// Package-private so main.odin's temporary self-test hook can report it.
@(private = "package")
record_path: string

// Live capture buffer — mono f32 samples normalized to -1..1, appended by
// poll_recording as data arrives from the capture ring.
@(private = "package")
record_samples: [dynamic]f32

@(private = "package")
record_sample_rate: u32

// Live preview is a scrolling level strip: each fixed-size chunk's min/max is
// stored exactly once in a ring buffer as its samples arrive, and the strip
// scrolls at a constant rate — cost is flat and the motion never rescales.
RECORD_CHUNK_FRAMES :: 1024 // mono frames per chunk (~21ms at 48kHz)
RECORD_LEVEL_CAP :: 2048  // strip history capacity (~43s at 2px per chunk)

@(private = "package")
record_strip: [RECORD_LEVEL_CAP]Waveform_Column // min/max per chunk, wraps

@(private = "package")
record_strip_count: int // chunks ever recorded (indexes wrap into the ring)

@(private = "package")
record_chunk_partial: Waveform_Column // running min/max of the unfinished chunk

@(private = "package")
record_chunk_fill: int // mono samples in the unfinished chunk

// Capture devices, refreshed from miniaudio on demand. Names are heap
// copies owned here (deleted on the next refresh).
MAX_RECORD_DEVICES :: 64

@(private = "package")
record_device_names: [MAX_RECORD_DEVICES]string

@(private = "package")
record_device_count: int

// Index of the device to record from; -1 until the first auto-selection.
@(private = "package")
record_device_selected: int = -1

@(private = "package")
record_devices_scanned: bool

// Re-enumerate capture devices, preserving the user's selection when the
// device is still present; otherwise auto-select a system-audio source.
refresh_record_devices :: proc() {
	for i in 0 ..< MAX_RECORD_DEVICES {
		if len(record_device_names[i]) > 0 do delete(record_device_names[i])
		record_device_names[i] = ""
	}
	record_devices_scanned = true

	n := ma.shim_capture_enumerate()
	if n < 0 do return
	count := min(n, c.int(MAX_RECORD_DEVICES))
	for i in 0 ..< count {
		record_device_names[i] = strings.clone_from_cstring(ma.shim_capture_device_name(i))
	}
	record_device_count = int(count)

	// Keep the previous selection if the device survived the rescan.
	if record_device_selected >= 0 && record_device_selected < record_device_count {
		return
	}
	record_device_selected = auto_select_device()
}

auto_select_device :: proc() -> int {
	if record_device_count == 0 do return -1

	// Prefer system-audio loopback: PulseAudio monitor sources (Linux) or
	// BlackHole (macOS), then the backend's default, then the first device.

	// On Linux, target the monitor of the *default* output sink so the
	// recording captures what is actually audible (the first monitor on the
	// list may belong to an unused digital output). pactl reports the sink's
	// description, which PulseAudio surfaces as "Monitor of <description>".
	sink_desc := default_sink_description()
	if len(sink_desc) > 0 {
		desc_lower := strings.to_lower(sink_desc)
		for i in 0 ..< record_device_count {
			name_lower := strings.to_lower(record_device_names[i])
			if strings.contains(name_lower, "monitor") && strings.contains(name_lower, desc_lower) do return i
		}
	}
	for i in 0 ..< record_device_count {
		if strings.contains(strings.to_lower(record_device_names[i]), "monitor") do return i
	}
	for i in 0 ..< record_device_count {
		if strings.contains(strings.to_lower(record_device_names[i]), "blackhole") do return i
	}
	for i in 0 ..< record_device_count {
		if ma.shim_capture_device_is_default(c.int(i)) != 0 do return i
	}
	return 0
}

// Description of the default output sink (Linux only; needs pactl, which
// works against PipeWire too). Empty when unavailable — the caller falls
// back to the first monitor.
default_sink_description :: proc() -> string {
	sink_res, sink_out, _, sink_err := os.process_exec(
		os.Process_Desc{command = {"pactl", "get-default-sink"}},
		context.temp_allocator,
	)
	if sink_err != nil || sink_res.exit_code != 0 do return ""
	sink_name := strings.trim_space(string(sink_out))
	if len(sink_name) == 0 do return ""

	list_res, list_out, _, list_err := os.process_exec(
		os.Process_Desc{command = {"pactl", "list", "sinks"}},
		context.temp_allocator,
	)
	if list_err != nil || list_res.exit_code != 0 do return ""

	sinks_text := string(list_out)
	marker := strings.concatenate({"Name: ", sink_name}, context.temp_allocator)
	idx := strings.index(sinks_text, marker)
	if idx < 0 do return ""
	block := sinks_text[idx:]
	desc_idx := strings.index(block, "Description:")
	if desc_idx < 0 do return ""
	line := block[desc_idx + len("Description:"):]
	if eol := strings.index(line, "\n"); eol >= 0 {
		line = line[:eol]
	}
	return strings.trim_space(line)
}

// Record-source dropdown state; the menu itself is drawn by ui's
// draw_record_menu (after the waveform, so it floats on top).
@(private = "package")
record_menu_open: bool

@(private = "package")
record_menu_just_opened: bool

select_record_device :: proc(state: ^App_State, index: int) {
	if index < 0 || index >= record_device_count do return
	record_device_selected = index
	set_statusf(state, "Recording source: %s", record_device_names[index])
}

start_recording :: proc(state: ^App_State) {
	if state.is_recording do return

	if !record_devices_scanned {
		refresh_record_devices()
	}
	if record_device_count == 0 {
		state.download_status = "No audio input devices found"
		return
	}
	device_index := record_device_selected >= 0 ? record_device_selected : 0

	dir := get_download_dir()
	now := time.now()
	y, mon, d := time.date(now)
	h, m, s := time.clock(now)
	filename := fmt.tprintf("recording_%04d%02d%02d_%02d%02d%02d.wav", y, int(mon), d, h, m, s)

	record_path = strings.concatenate({dir, "/", filename})
	clear(&record_samples)
	record_strip_count = 0
	record_chunk_partial = Waveform_Column{0, 0}
	record_chunk_fill = 0

	if ma.shim_capture_start(c.int(device_index), 48000, 2) != 0 {
		state.download_status = "Failed to start recording"
		fmt.eprintfln("capture start failed: %s", record_device_names[device_index])
		return
	}
	record_sample_rate = ma.shim_capture_sample_rate()

	// The recording becomes the active view — release any previously loaded
	// track so the UI is consistent (stops playback, clears selection/notes).
	if state.audio_loaded {
		unload_audio(state)
	}

	state.is_recording = true
	state.record_file = record_path
	record_menu_open = false
	set_statusf(state, "Recording system audio via: %s", record_device_names[device_index])
}

// Drain whatever PCM has arrived since the last frame into the live buffer.
// Called once per frame from the main loop while recording.
poll_recording :: proc(state: ^App_State) {
	if !state.is_recording do return

	buf: [8192]u8
	for {
		n := ma.shim_capture_poll(raw_data(&buf), c.int(len(buf)))
		if n <= 0 do break
		append_pcm(buf[:n])
	}
}

// Convert interleaved s16le bytes to mono f32 samples and append, updating
// the fixed-size preview chunks as the samples land.
append_pcm :: proc(bytes: []u8) {
	frame_count := len(bytes) / 4 // 2 channels * 2 bytes
	start := len(record_samples)
	resize(&record_samples, start + frame_count)

	pcm := cast([^]i16)raw_data(bytes)
	for i in 0 ..< frame_count {
		sample := (f32(pcm[i * 2]) + f32(pcm[i * 2 + 1])) * 0.5 / 32768.0
		record_samples[start + i] = sample

		if record_chunk_fill == 0 {
			record_chunk_partial = Waveform_Column{sample, sample}
		} else {
			if sample < record_chunk_partial.min_val do record_chunk_partial.min_val = sample
			if sample > record_chunk_partial.max_val do record_chunk_partial.max_val = sample
		}
		record_chunk_fill += 1
		if record_chunk_fill == RECORD_CHUNK_FRAMES {
			record_strip[record_strip_count %% RECORD_LEVEL_CAP] = record_chunk_partial
			record_strip_count += 1
			record_chunk_fill = 0
		}
	}
}

// Total recorded duration in seconds.
recording_duration :: proc() -> f32 {
	return f32(len(record_samples)) / f32(record_sample_rate)
}

stop_recording :: proc(state: ^App_State) {
	if !state.is_recording do return

	state.is_recording = false

	// Stop capture, then drain whatever is still sitting in the shim's ring.
	ma.shim_capture_stop()
	buf: [8192]u8
	for {
		n := ma.shim_capture_poll(raw_data(&buf), c.int(len(buf)))
		if n <= 0 do break
		append_pcm(buf[:n])
	}

	sample_count := len(record_samples)
	if sample_count == 0 {
		state.download_status = "Recording was empty"
		clear(&record_samples)
		record_strip_count = 0
		record_chunk_partial = Waveform_Column{0, 0}
		record_chunk_fill = 0
		return
	}

	if write_recording_wav(state) {
		set_statusf(state, "Saved: %s", record_path)
		scan_library(state)

		// Open the fresh recording right away.
		cpath := strings.clone_to_cstring(record_path, context.temp_allocator)
		if load_audio_file(state, cpath) {
			set_statusf(state, "Loaded: %s", record_path)
		} else {
			set_statusf(state, "Saved (failed to load): %s", record_path)
		}
	} else {
		state.download_status = "Failed to save recording"
	}

	clear(&record_samples)
	record_strip_count = 0
	record_chunk_partial = Waveform_Column{0, 0}
	record_chunk_fill = 0
}

// Encode the captured mono samples as a 16-bit stereo WAV.
write_recording_wav :: proc(state: ^App_State) -> bool {
	frame_count := len(record_samples)

	stereo := make([]i16, frame_count * 2)
	defer delete(stereo)
	for i in 0 ..< frame_count {
		s := math.clamp(record_samples[i], -1.0, 1.0)
		v := i16(s * 32767.0)
		stereo[i * 2] = v
		stereo[i * 2 + 1] = v
	}

	wave: rl.Wave
	wave.frameCount = u32(frame_count)
	wave.sampleRate = record_sample_rate
	wave.sampleSize = 16
	wave.channels = 2
	wave.data = raw_data(stereo)

	cpath := strings.clone_to_cstring(record_path, context.temp_allocator)
	return rl.ExportWave(wave, cpath)
}