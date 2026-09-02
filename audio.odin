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

update_audio :: proc(state: ^App_State) {
	if !state.audio_loaded || !state.is_playing do return

	rl.UpdateMusicStream(state.music)
	state.current_time = rl.GetMusicTimePlayed(state.music)

	if state.loop_enabled && state.has_selection {
		if state.current_time >= state.selection_end {
			rl.SeekMusicStream(state.music, state.selection_start)
		}
	}
}

toggle_playback :: proc(state: ^App_State) {
	if !state.audio_loaded do return

	if state.is_playing {
		rl.PauseMusicStream(state.music)
		state.is_playing = false
	} else {
		if !rl.IsMusicStreamPlaying(state.music) {
			// Stream is stopped — must PlayMusicStream then seek
			rl.PlayMusicStream(state.music)
			if state.loop_enabled && state.has_selection {
				rl.SeekMusicStream(state.music, state.selection_start)
			} else if state.current_time > 0 && state.current_time < state.duration {
				rl.SeekMusicStream(state.music, state.current_time)
			}
		} else {
			rl.ResumeMusicStream(state.music)
		}
		rl.SetMusicPitch(state.music, state.playback_speed)
		rl.SetMusicVolume(state.music, state.volume)
		state.is_playing = true
	}
}

stop_playback :: proc(state: ^App_State) {
	if !state.audio_loaded do return
	rl.StopMusicStream(state.music)
	state.is_playing = false
	state.current_time = 0
}

set_playback_speed :: proc(state: ^App_State, speed: f32) {
	state.playback_speed = math.clamp(speed, 0.25, 2.0)
	if state.is_playing {
		rl.SetMusicPitch(state.music, state.playback_speed)
	}
}

seek_relative :: proc(state: ^App_State, offset: f32) {
	if !state.audio_loaded do return
	target := math.clamp(state.current_time + offset, 0, state.duration)
	rl.SeekMusicStream(state.music, target)
	state.current_time = target
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
