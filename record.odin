package music_trainer

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:time"

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

// Records system audio via parec streaming raw PCM through a pipe so the
// live level strip can be rendered while capturing. On stop, the accumulated
// samples are written as a WAV and the file is loaded immediately.

@(private = "file")
record_process: os.Process

@(private = "file")
record_path: string

// Pipe read end — parec writes raw s16le stereo PCM to the write end.
@(private = "package")
record_pipe: ^os.File

// Live capture buffer — mono f32 samples normalized to -1..1, appended by
// poll_recording as data arrives from the pipe.
@(private = "package")
record_samples: [dynamic]f32

@(private = "package")
record_sample_rate: u32

// Live preview is a scrolling level strip: each fixed-size chunk's min/max is
// stored exactly once in a ring buffer as its samples arrive, and the strip
// scrolls at a constant rate — cost is flat and the motion never rescales.
RECORD_CHUNK_FRAMES :: 1024 // mono frames per chunk (~21ms at 48kHz)
RECORD_LEVEL_CAP :: 2048   // strip history capacity (~43s at 2px per chunk)

@(private = "package")
record_strip: [RECORD_LEVEL_CAP]Waveform_Column // min/max per chunk, wraps

@(private = "package")
record_strip_count: int // chunks ever recorded (indexes wrap into the ring)

@(private = "package")
record_chunk_partial: Waveform_Column // running min/max of the unfinished chunk

@(private = "package")
record_chunk_fill: int // mono samples in the unfinished chunk

get_monitor_source :: proc() -> string {
	result, stdout, _, err := os.process_exec(
		os.Process_Desc{
			command = {"pactl", "get-default-sink"},
		},
		context.temp_allocator,
	)
	if err != nil || result.exit_code != 0 do return ""
	sink := strings.trim_space(string(stdout))
	if len(sink) == 0 do return ""
	return strings.concatenate({sink, ".monitor"}, context.temp_allocator)
}

start_recording :: proc(state: ^App_State) {
	if state.is_recording do return

	monitor := get_monitor_source()
	if len(monitor) == 0 {
		state.download_status = "No audio monitor source found"
		return
	}

	dir := get_download_dir()
	now := time.now()
	y, mon, d := time.date(now)
	h, m, s := time.clock(now)
	filename := fmt.tprintf("recording_%04d%02d%02d_%02d%02d%02d.wav", y, int(mon), d, h, m, s)

	record_path = strings.concatenate({dir, "/", filename})
	record_sample_rate = 48000
	clear(&record_samples)
	record_strip_count = 0
	record_chunk_partial = Waveform_Column{0, 0}
	record_chunk_fill = 0

	// Pipe parec's stdout so samples can be drained while it records.
	pipe_r, pipe_w, pipe_err := os.pipe()
	if pipe_err != nil {
		state.download_status = "Failed to start recording (pipe)"
		fmt.eprintfln("pipe error: %v", pipe_err)
		return
	}

	device_arg := strings.concatenate({"--device=", monitor})

	proc_or_err, start_err := os.process_start({
		command = {
			"parec",
			device_arg,
			"--format=s16le",
			"--rate=48000",
			"--channels=2",
			// ~20ms fragments — without this parec batches ~340ms of audio into
			// one pipe write, which makes the live strip jump instead of scroll
			"--latency-msec=20",
		},
		stdout = pipe_w,
	})

	// The child owns the write end now; closing our copy lets the read end
	// see EOF once parec exits. On failure both ends must be released.
	os.close(pipe_w)

	if start_err != nil {
		os.close(pipe_r)
		state.download_status = "Failed to start recording"
		fmt.eprintfln("parec start error: %v", start_err)
		return
	}

	record_process = proc_or_err
	record_pipe = pipe_r

	// The recording becomes the active view — release any previously loaded
	// track so the UI is consistent (stops playback, clears selection/notes).
	if state.audio_loaded {
		unload_audio(state)
	}

	state.is_recording = true
	state.record_file = record_path
	state.download_status = "Recording system audio..."
}

// Drain whatever PCM has arrived since the last frame into the live buffer.
// Called once per frame from the main loop while recording.
poll_recording :: proc(state: ^App_State) {
	if !state.is_recording || record_pipe == nil do return

	buf: [8192]u8
	for {
		has_data, pipe_err := os.pipe_has_data(record_pipe)
		if pipe_err != nil do break // Broken_Pipe: parec is gone, buffer drained
		if !has_data do break

		n, read_err := os.read(record_pipe, buf[:])
		if n > 0 {
			append_pcm(buf[:n])
		}
		if read_err != nil || n == 0 do break
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

	term_err := os.process_terminate(record_process)
	if term_err != nil {
		fmt.eprintfln("Failed to stop parec: %v", term_err)
		_ = os.process_kill(record_process)
	}
	_, _ = os.process_wait(record_process)

	// parec is gone — drain any bytes still sitting in the pipe buffer.
	buf: [8192]u8
	for {
		n, read_err := os.read(record_pipe, buf[:])
		if n > 0 {
			append_pcm(buf[:n])
		}
		if read_err != nil || n == 0 do break
	}
	os.close(record_pipe)
	record_pipe = nil

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
