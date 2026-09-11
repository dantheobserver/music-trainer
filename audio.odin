package music_trainer

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"

import rl "vendor:raylib"

load_audio_file :: proc(state: ^App_State, path: cstring) -> bool {
	if state.audio_loaded {
		unload_audio(state)
	}

	wave := rl.LoadWave(path)
	if wave.data == nil {
		state.download_status = "Failed to load audio file"
		return false
	}

	music := rl.LoadMusicStream(path)
	if music.stream.sampleRate == 0 {
		rl.UnloadWave(wave)
		state.download_status = "Failed to load music stream"
		return false
	}

	samples := rl.LoadWaveSamples(wave)
	if samples == nil {
		rl.UnloadWave(wave)
		rl.UnloadMusicStream(music)
		state.download_status = "Failed to load wave samples"
		return false
	}

	state.wave = wave
	state.music = music
	state.samples = samples
	state.sample_count = int(wave.frameCount) * int(wave.channels)
	state.sample_rate = wave.sampleRate
	state.channels = u32(wave.channels)
	state.duration = rl.GetMusicTimeLength(music)
	state.audio_loaded = true
	state.file_name = string(path)

	state.view_start = 0
	state.view_duration = state.duration
	state.has_selection = false
	state.is_playing = false
	state.current_time = 0
	state.cache_dirty = true

	state.download_status = "Loaded"

	analyze_full_track(state)

	return true
}

unload_audio :: proc(state: ^App_State) {
	if !state.audio_loaded do return

	cleanup_stretched(state)

	rl.StopMusicStream(state.music)
	rl.UnloadWaveSamples(state.samples)
	rl.UnloadWave(state.wave)
	rl.UnloadMusicStream(state.music)

	clear(&state.waveform_cache)
	clear(&state.detected_notes)

	state.audio_loaded = false
	state.is_playing = false
	state.has_selection = false
	state.current_time = 0
}

// Active loop region for the current playback state.
//
// Isolation is its own state: freshly isolated, the whole region loops;
// once a new selection is made inside the isolated view, that selection
// becomes the loop. Without isolation, the loop is the current selection
// and only when Loop is enabled.
active_loop_bounds :: proc(state: ^App_State) -> (start, end: f32, loops: bool) {
	if is_isolated(state) {
		if state.has_selection {
			return state.selection_start, state.selection_end, true
		}
		top := state.isolation_stack[len(state.isolation_stack) - 1]
		return top.selection_start, top.selection_end, true
	}
	return state.selection_start, state.selection_end, state.loop_enabled && state.has_selection
}

update_audio :: proc(state: ^App_State) {
	if !state.audio_loaded || !state.is_playing do return

	loop_start, loop_end, should_loop := active_loop_bounds(state)

	if state.pitch_correct && state.has_stretched {
		rl.UpdateMusicStream(state.stretched_music)
		stretched_time := rl.GetMusicTimePlayed(state.stretched_music)
		state.current_time = to_original_time(stretched_time, state.stretched_speed)

		if should_loop && state.current_time >= loop_end {
			seek_pos := to_stretched_time(loop_start, state.stretched_speed)
			rl.SeekMusicStream(state.stretched_music, seek_pos)
		}
	} else {
		rl.UpdateMusicStream(state.music)
		state.current_time = rl.GetMusicTimePlayed(state.music)

		if should_loop && state.current_time >= loop_end {
			rl.SeekMusicStream(state.music, loop_start)
		}
	}
}

toggle_playback :: proc(state: ^App_State) {
	if !state.audio_loaded do return

	if state.is_playing {
		if state.pitch_correct && state.has_stretched {
			rl.PauseMusicStream(state.stretched_music)
		} else {
			rl.PauseMusicStream(state.music)
		}
		state.is_playing = false
	} else {
		if state.pitch_correct && state.playback_speed != 1.0 {
			start_stretched_playback(state)
		} else {
			start_normal_playback(state)
		}
		state.is_playing = true
	}
}

start_normal_playback :: proc(state: ^App_State) {
	// Stop any stretched stream
	if state.has_stretched {
		rl.StopMusicStream(state.stretched_music)
	}

	if !rl.IsMusicStreamPlaying(state.music) {
		rl.PlayMusicStream(state.music)
		if is_isolated(state) {
			// Isolated view: playback must live inside the region — resume the
			// playhead if it is inside, otherwise start at the region start.
			loop_start, loop_end, _ := active_loop_bounds(state)
			if state.current_time < loop_start || state.current_time >= loop_end {
				rl.SeekMusicStream(state.music, loop_start)
			} else {
				rl.SeekMusicStream(state.music, state.current_time)
			}
		} else if state.loop_enabled && state.has_selection {
			rl.SeekMusicStream(state.music, state.selection_start)
		} else if state.current_time > 0 && state.current_time < state.duration {
			rl.SeekMusicStream(state.music, state.current_time)
		}
	} else {
		rl.ResumeMusicStream(state.music)
	}
	rl.SetMusicPitch(state.music, state.playback_speed)
	rl.SetMusicVolume(state.music, state.volume)
}

start_stretched_playback :: proc(state: ^App_State) {
	// Stop normal stream
	rl.PauseMusicStream(state.music)

	if !state.has_stretched || state.stretched_speed != state.playback_speed {
		prepare_stretched_audio(state)
	}
	if !state.has_stretched do return

	seek_time: f32
	if is_isolated(state) {
		// Isolated view: resume inside the region, or start at the region start
		// if the playhead is outside it.
		loop_start, loop_end, _ := active_loop_bounds(state)
		if state.current_time < loop_start || state.current_time >= loop_end {
			seek_time = to_stretched_time(loop_start, state.stretched_speed)
		} else {
			seek_time = to_stretched_time(state.current_time, state.stretched_speed)
		}
	} else if state.loop_enabled && state.has_selection {
		seek_time = to_stretched_time(state.selection_start, state.stretched_speed)
	} else if state.current_time > 0 && state.current_time < state.duration {
		seek_time = to_stretched_time(state.current_time, state.stretched_speed)
	}

	rl.PlayMusicStream(state.stretched_music)
	rl.SetMusicPitch(state.stretched_music, 1.0)
	rl.SetMusicVolume(state.stretched_music, state.volume)
	if seek_time > 0 {
		rl.SeekMusicStream(state.stretched_music, seek_time)
	}
}

stop_playback :: proc(state: ^App_State) {
	if !state.audio_loaded do return
	rl.StopMusicStream(state.music)
	if state.has_stretched {
		rl.StopMusicStream(state.stretched_music)
	}
	state.is_playing = false
	state.current_time = 0
}

set_playback_speed :: proc(state: ^App_State, speed: f32) {
	old_speed := state.playback_speed
	state.playback_speed = math.clamp(speed, 0.25, 2.0)

	if !state.is_playing do return

	if state.pitch_correct && state.playback_speed != 1.0 {
		if state.playback_speed != old_speed {
			current := state.current_time
			prepare_stretched_audio(state)
			if state.has_stretched {
				rl.PauseMusicStream(state.music)
				rl.PlayMusicStream(state.stretched_music)
				rl.SetMusicVolume(state.stretched_music, state.volume)
				seek_pos := to_stretched_time(current, state.stretched_speed)
				rl.SeekMusicStream(state.stretched_music, seek_pos)
			}
		}
	} else {
		rl.SetMusicPitch(state.music, state.playback_speed)
	}
}

seek_to_time :: proc(state: ^App_State, time: f32) {
	if !state.audio_loaded do return
	target: f32
	if is_isolated(state) {
		top := state.isolation_stack[len(state.isolation_stack) - 1]
		target = math.clamp(time, top.selection_start, top.selection_end)
	} else {
		target = math.clamp(time, 0, state.duration)
	}
	state.current_time = target

	if state.pitch_correct && state.has_stretched {
		stretched_pos := to_stretched_time(target, state.stretched_speed)
		rl.SeekMusicStream(state.stretched_music, stretched_pos)
	} else {
		rl.SeekMusicStream(state.music, target)
	}
}

seek_relative :: proc(state: ^App_State, offset: f32) {
	seek_to_time(state, state.current_time + offset)
}

reset_speed :: proc(state: ^App_State) {
	was_playing := state.is_playing
	if was_playing {
		if state.pitch_correct && state.has_stretched {
			rl.StopMusicStream(state.stretched_music)
		} else {
			rl.PauseMusicStream(state.music)
		}
	}

	cleanup_stretched(state)
	state.playback_speed = 1.0
	state.pitch_correct = false

	if was_playing {
		start_normal_playback(state)
		state.is_playing = true
	}
}

get_download_dir :: proc() -> string {
	home := os.get_env("HOME", context.temp_allocator)
	dir := strings.concatenate({home, "/Music/music_trainer"}, context.temp_allocator)
	os.make_directory_all(dir)
	return dir
}

download_from_url :: proc(state: ^App_State, url: string) {
	if len(url) == 0 do return

	state.is_downloading = true
	state.download_status = "Downloading..."

	dir := get_download_dir()
	output_template := strings.concatenate({dir, "/%(title)s.%(ext)s"}, context.temp_allocator)

	// First get the filename yt-dlp will produce
	title_result, title_stdout, title_stderr, title_err := os.process_exec(
		os.Process_Desc{
			command = {"yt-dlp", "--print", "filename", "--extract-audio", "--audio-format", "wav",
				"--js-runtimes", "node", "--cookies-from-browser", "chromium",
				"-o", output_template, url},
		},
		context.allocator,
	)
	defer delete(title_stdout)
	defer delete(title_stderr)

	if title_err != nil || title_result.exit_code != 0 {
		state.is_downloading = false
		state.download_status = "Download failed - could not resolve URL"
		fmt.eprintfln("yt-dlp error: %s", string(title_stderr))
		return
	}

	// Now do the actual download
	result, stdout, stderr, err := os.process_exec(
		os.Process_Desc{
			command = {"yt-dlp", "--extract-audio", "--audio-format", "wav",
				"--js-runtimes", "node", "--cookies-from-browser", "chromium",
				"-o", output_template, url},
		},
		context.allocator,
	)
	defer delete(stdout)
	defer delete(stderr)

	state.is_downloading = false

	if err != nil || result.exit_code != 0 {
		state.download_status = "Download failed"
		fmt.eprintfln("yt-dlp error: %s", string(stderr))
		return
	}

	// Parse the output filename — yt-dlp --print gives us the path with original ext,
	// but we extracted to wav so replace the extension
	raw_path := strings.trim_space(string(title_stdout))
	// yt-dlp --print filename shows the pre-extraction name; the extracted file has .wav
	dot_idx := strings.last_index(raw_path, ".")
	wav_path: string
	if dot_idx >= 0 {
		wav_path = strings.concatenate({raw_path[:dot_idx], ".wav"}, context.temp_allocator)
	} else {
		wav_path = strings.concatenate({raw_path, ".wav"}, context.temp_allocator)
	}

	cpath := strings.clone_to_cstring(wav_path, context.temp_allocator)

	if !load_audio_file(state, cpath) {
		state.download_status = "Failed to load downloaded audio"
	} else {
		state.download_status = rl.TextFormat("Saved to %s", cpath)
		scan_library(state)
	}
}

stop_preview :: proc(state: ^App_State) {
	if state.preview_playing {
		rl.StopMusicStream(state.preview_music)
		rl.UnloadMusicStream(state.preview_music)
		state.preview_playing = false
		state.preview_index = -1
	}
}

toggle_preview :: proc(state: ^App_State, index: int) {
	if state.preview_playing && state.preview_index == index {
		stop_preview(state)
		return
	}

	stop_preview(state)

	path := strings.clone_to_cstring(state.library_files[index], context.temp_allocator)
	music := rl.LoadMusicStream(path)
	if music.stream.sampleRate == 0 do return

	state.preview_music = music
	state.preview_index = index
	state.preview_playing = true
	rl.PlayMusicStream(state.preview_music)
	rl.SetMusicVolume(state.preview_music, state.volume)
}

delete_library_file :: proc(state: ^App_State, index: int) {
	if index < 0 || index >= len(state.library_files) do return

	// Stop preview if playing this file
	if state.preview_playing && state.preview_index == index {
		stop_preview(state)
	}

	file := state.library_files[index]
	_ = os.remove(file)
	delete(file)
	ordered_remove(&state.library_files, index)

	// Fix preview index if needed
	if state.preview_index > index {
		state.preview_index -= 1
	}
}

rename_library_file :: proc(state: ^App_State, index: int, new_name: string) -> bool {
	if index < 0 || index >= len(state.library_files) do return false
	if len(new_name) == 0 do return false

	old_path := state.library_files[index]
	dir := get_download_dir()
	new_path := strings.concatenate({dir, "/", new_name})

	err := os.rename(old_path, new_path)
	if err != nil {
		delete(new_path)
		return false
	}

	delete(old_path)
	state.library_files[index] = new_path
	return true
}

AUDIO_EXTENSIONS :: [?]string{".wav", ".mp3", ".flac", ".ogg"}

scan_library :: proc(state: ^App_State) {
	// Clear old list
	for &f in state.library_files {
		delete(f)
	}
	clear(&state.library_files)

	dir := get_download_dir()
	d, open_err := os.open(dir)
	if open_err != nil do return
	defer os.close(d)

	files, read_err := os.read_directory(d, -1, context.temp_allocator)
	if read_err != nil do return

	for fi in files {
		if fi.type == .Directory do continue
		ext := filepath.ext(fi.name)
		is_audio := false
		for ae in AUDIO_EXTENSIONS {
			if strings.equal_fold(ext, ae) {
				is_audio = true
				break
			}
		}
		if !is_audio do continue

		full_path := strings.concatenate({dir, "/", fi.name})
		append(&state.library_files, full_path)
	}
}
