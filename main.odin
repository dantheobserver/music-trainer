package music_trainer

import "base:runtime"

import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"

// Rolling counter for on-demand screenshots (F12)
shot_count: int

main :: proc() {
	rl.InitWindow(1280, 720, "Music Trainer")
	defer rl.CloseWindow()
	rl.SetWindowTitle(rl.TextFormat("Music Trainer %s", APP_VERSION))

	rl.InitAudioDevice()
	defer rl.CloseAudioDevice()

	rl.SetTargetFPS(60)

	state := init_state()
	load_fonts(&state)
	setup_gui_style(&state)

	// Load file from command line argument
	args := runtime.args__
	if len(args) >= 2 {
		load_audio_file(&state, args[1])
	}


	for !rl.WindowShouldClose() {
		// Handle file drops
		if rl.IsFileDropped() {
			files := rl.LoadDroppedFiles()
			if files.count > 0 {
				path := files.paths[0]
				load_audio_file(&state, path)
			}
			rl.UnloadDroppedFiles(files)
		}

		poll_recording(&state)
		update_audio(&state)
		if state.preview_playing {
			rl.UpdateMusicStream(state.preview_music)
			if !rl.IsMusicStreamPlaying(state.preview_music) {
				stop_preview(&state)
			}
		}
		update_waveform_input(&state)

		rl.BeginDrawing()
		rl.ClearBackground(BG_DEEP)

		draw_ui(&state)
		draw_waveform(&state)
		draw_record_menu(&state)
		draw_library_overlay(&state)

		// F12 — save a screenshot of the current frame next to the binary
		if rl.IsKeyPressed(.F12) {
			shot_count += 1
			// Flush the 2D batch first — it is only presented on EndDrawing,
			// so a framebuffer read without this misses the last-drawn UI.
			rlgl.DrawRenderBatchActive()
			rl.TakeScreenshot(rl.TextFormat("screenshot_%d.png", shot_count))
		}

		rl.EndDrawing()

		free_all(context.temp_allocator)
	}

	if state.preview_playing {
		stop_preview(&state)
	}
	if state.is_recording {
		stop_recording(&state)
	}
	cleanup_stretched(&state)
	if state.audio_loaded {
		unload_audio(&state)
	}
	if state.fonts_loaded {
		rl.UnloadFont(state.font)
		rl.UnloadFont(state.font_bold)
	}
	delete(state.waveform_cache)
	delete(state.detected_notes)
	delete(state.isolation_stack)
	delete(record_samples)
	for &f in state.library_files {
		delete(f)
	}
	delete(state.library_files)
}
