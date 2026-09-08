package music_trainer

import "core:math"

import rl "vendor:raylib"

STRETCH_WINDOW :: 2048
STRETCH_HOP :: 512
STRETCHED_PATH : cstring : "/tmp/music_trainer_stretched.wav"

// OLA time-stretch: factor > 1.0 = slower, factor < 1.0 = faster
// Preserves pitch by windowing and repositioning grains
time_stretch_ola :: proc(
	input: [^]f32,
	frame_count: int,
	channels: int,
	factor: f64,
) -> (output: []i16, out_frames: int) {
	if factor <= 0 || factor > 10 do return nil, 0

	analysis_hop := STRETCH_HOP
	synthesis_hop := max(1, int(f64(analysis_hop) * factor))
	window_size := STRETCH_WINDOW

	num_grains := max(1, (frame_count - window_size) / analysis_hop)
	out_frames = num_grains * synthesis_hop + window_size

	accum := make([]f32, out_frames * channels)
	defer delete(accum)

	norm := make([]f32, out_frames)
	defer delete(norm)

	window := make([]f32, window_size, context.temp_allocator)
	for i in 0 ..< window_size {
		window[i] = 0.5 * (1.0 - math.cos(2.0 * math.PI * f32(i) / f32(window_size - 1)))
	}

	for grain in 0 ..< num_grains {
		in_start := grain * analysis_hop
		out_start := grain * synthesis_hop

		if in_start + window_size > frame_count do break
		if out_start + window_size > out_frames do break

		for i in 0 ..< window_size {
			w := window[i]
			for c in 0 ..< channels {
				accum[(out_start + i) * channels + c] += input[(in_start + i) * channels + c] * w
			}
			norm[out_start + i] += w * w
		}
	}

	output = make([]i16, out_frames * channels)
	for frame in 0 ..< out_frames {
		n := norm[frame]
		if n < 0.001 do n = 1.0
		for c in 0 ..< channels {
			s := accum[frame * channels + c] / n
			s = math.clamp(s, -1.0, 1.0)
			output[frame * channels + c] = i16(s * 32767.0)
		}
	}

	return output, out_frames
}

prepare_stretched_audio :: proc(state: ^App_State) {
	cleanup_stretched(state)

	if !state.audio_loaded do return
	if state.playback_speed == 1.0 do return

	factor := 1.0 / f64(state.playback_speed)

	stretched, out_frames := time_stretch_ola(
		state.samples,
		int(state.wave.frameCount),
		int(state.channels),
		factor,
	)
	if stretched == nil do return
	defer delete(stretched)

	temp_wave: rl.Wave
	temp_wave.frameCount = u32(out_frames)
	temp_wave.sampleRate = state.sample_rate
	temp_wave.sampleSize = 16
	temp_wave.channels = u32(state.channels)
	temp_wave.data = raw_data(stretched)

	rl.ExportWave(temp_wave, STRETCHED_PATH)

	state.stretched_music = rl.LoadMusicStream(STRETCHED_PATH)
	if state.stretched_music.stream.sampleRate == 0 {
		state.has_stretched = false
		return
	}
	state.has_stretched = true
	state.stretched_speed = state.playback_speed
}

cleanup_stretched :: proc(state: ^App_State) {
	if state.has_stretched {
		rl.StopMusicStream(state.stretched_music)
		rl.UnloadMusicStream(state.stretched_music)
		state.has_stretched = false
		state.stretched_speed = 0
	}
}

// Convert original-audio time to stretched-audio time
to_stretched_time :: proc(original_time: f32, speed: f32) -> f32 {
	if speed <= 0 do return 0
	return original_time / speed
}

// Convert stretched-audio time to original-audio time
to_original_time :: proc(stretched_time: f32, speed: f32) -> f32 {
	return stretched_time * speed
}
