package music_trainer

import "core:fmt"
import "core:math"

analyze_full_track :: proc(state: ^App_State) {
	if !state.audio_loaded do return
	clear(&state.detected_notes)

	frame_count := int(state.wave.frameCount)
	channels := int(state.channels)
	sample_rate := state.sample_rate

	mono_window := make([]f32, FFT_SIZE)
	defer delete(mono_window)

	windowed := make([]f32, FFT_SIZE)
	defer delete(windowed)

	fft_buf := make([]complex128, FFT_SIZE)
	defer delete(fft_buf)

	spectrum := make([]f64, FFT_SIZE / 2)
	defer delete(spectrum)

	min_bin := frequency_to_bin(MIN_FREQ, sample_rate, FFT_SIZE)
	max_bin := frequency_to_bin(MAX_FREQ, sample_rate, FFT_SIZE)
	max_bin = min(max_bin, FFT_SIZE / 2 - 1)

	for start := 0; start + FFT_SIZE <= frame_count; start += HOP_SIZE {
		extract_mono_window(state, start, mono_window[:])
		hann_window(mono_window[:], windowed[:])

		for i in 0 ..< FFT_SIZE {
			fft_buf[i] = complex(f64(windowed[i]), 0.0)
		}

		fft(fft_buf[:])
		magnitude_spectrum(fft_buf[:], spectrum[:])

		peak_bin := min_bin
		peak_mag: f64 = 0
		sum_mag: f64 = 0

		for i in min_bin ..= max_bin {
			sum_mag += spectrum[i]
			if spectrum[i] > peak_mag {
				peak_mag = spectrum[i]
				peak_bin = i
			}
		}

		avg_mag := sum_mag / f64(max_bin - min_bin + 1)
		confidence := f32(peak_mag / max(avg_mag, 1e-10))

		if confidence < CONFIDENCE_THRESHOLD do continue
		if peak_bin <= min_bin || peak_bin >= max_bin do continue

		// Parabolic interpolation for sub-bin accuracy
		alpha := spectrum[peak_bin - 1]
		beta := spectrum[peak_bin]
		gamma := spectrum[peak_bin + 1]
		denom := alpha - 2 * beta + gamma
		p: f64 = 0
		if abs(denom) > 1e-10 {
			p = 0.5 * (alpha - gamma) / denom
		}

		refined_bin := f64(peak_bin) + p
		freq := bin_to_frequency(refined_bin, sample_rate, FFT_SIZE)

		name, midi, octave, note_idx := frequency_to_note(freq)
		time := f32(start) / f32(sample_rate)

		append(&state.detected_notes, Detected_Note{
			time       = time,
			frequency  = f32(freq),
			note_name  = name,
			midi_num   = midi,
			confidence = confidence,
			octave     = octave,
			note_index = note_idx,
		})
	}

	fmt.printfln("Analyzed %d windows, detected %d notes", frame_count / HOP_SIZE, len(state.detected_notes))
}

extract_mono_window :: proc(state: ^App_State, start_frame: int, output: []f32) {
	channels := int(state.channels)
	for i in 0 ..< FFT_SIZE {
		frame := start_frame + i
		if channels == 1 {
			output[i] = state.samples[frame]
		} else {
			left := state.samples[frame * channels]
			right := state.samples[frame * channels + 1]
			output[i] = (left + right) * 0.5
		}
	}
}

frequency_to_note :: proc(freq: f64) -> (name: string, midi: int, octave: int, note_index: int) {
	midi_float := 12.0 * math.log2(freq / 440.0) + 69.0
	midi = int(math.round(midi_float))
	note_index = midi %% 12
	octave = midi / 12 - 1
	name = note_names[note_index]
	return
}

// Binary search for nearest note at given time
find_note_at_time :: proc(notes: []Detected_Note, time: f32) -> int {
	if len(notes) == 0 do return -1

	lo, hi := 0, len(notes) - 1
	for lo <= hi {
		mid := (lo + hi) / 2
		if notes[mid].time < time {
			lo = mid + 1
		} else if notes[mid].time > time {
			hi = mid - 1
		} else {
			return mid
		}
	}

	if lo >= len(notes) do return len(notes) - 1
	if hi < 0 do return 0

	if abs(notes[lo].time - time) < abs(notes[hi].time - time) {
		return lo
	}
	return hi
}
