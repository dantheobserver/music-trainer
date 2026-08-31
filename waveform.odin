package music_trainer

import "core:math"

import rl "vendor:raylib"

compute_waveform_cache :: proc(state: ^App_State) {
	if !state.audio_loaded do return

	pixel_width := int(state.waveform_rect.width)
	if pixel_width <= 0 do return

	clear(&state.waveform_cache)
	resize(&state.waveform_cache, pixel_width)

	channels := int(state.channels)
	sample_rate := f32(state.sample_rate)

	for col in 0 ..< pixel_width {
		t_start := state.view_start + f32(col) / f32(pixel_width) * state.view_duration
		t_end := state.view_start + f32(col + 1) / f32(pixel_width) * state.view_duration

		frame_start := int(t_start * sample_rate)
		frame_end := int(t_end * sample_rate)
		frame_start = math.clamp(frame_start, 0, int(state.wave.frameCount) - 1)
		frame_end = math.clamp(frame_end, frame_start + 1, int(state.wave.frameCount))

		min_val: f32 = 1.0
		max_val: f32 = -1.0

		for f in frame_start ..< frame_end {
			sample: f32
			if channels == 1 {
				sample = state.samples[f]
			} else {
				sample = (state.samples[f * channels] + state.samples[f * channels + 1]) * 0.5
			}
			min_val = min(min_val, sample)
			max_val = max(max_val, sample)
		}

		state.waveform_cache[col] = Waveform_Column{min_val, max_val}
	}

	state.cache_dirty = false
}

draw_waveform :: proc(state: ^App_State) {
	if !state.audio_loaded do return

	rect := state.waveform_rect
	center_y := rect.y + rect.height * 0.5

	// Background
	rl.DrawRectangleRec(rect, rl.Color{20, 20, 25, 255})

	// Center line
	rl.DrawLineV(
		{rect.x, center_y},
		{rect.x + rect.width, center_y},
		rl.Color{60, 60, 70, 255},
	)

	if state.cache_dirty {
		compute_waveform_cache(state)
	}

	// Selection overlay
	if state.has_selection {
		sel_x1 := time_to_screen_x(state, state.selection_start)
		sel_x2 := time_to_screen_x(state, state.selection_end)
		sel_x1 = math.clamp(sel_x1, rect.x, rect.x + rect.width)
		sel_x2 = math.clamp(sel_x2, rect.x, rect.x + rect.width)

		rl.DrawRectangleRec(
			{sel_x1, rect.y, sel_x2 - sel_x1, rect.height},
			rl.Color{100, 149, 237, 40},
		)

		// Selection handles
		handle_w: f32 = 4
		rl.DrawRectangleRec({sel_x1 - handle_w / 2, rect.y, handle_w, rect.height}, rl.Color{100, 149, 237, 180})
		rl.DrawRectangleRec({sel_x2 - handle_w / 2, rect.y, handle_w, rect.height}, rl.Color{100, 149, 237, 180})
	}

	// Waveform columns — colored by detected note
	half_h := rect.height * 0.5
	notes := state.detected_notes[:]
	note_cursor := 0
	hop_time := f32(HOP_SIZE) / f32(state.sample_rate)
	dim_color := rl.Color{50, 60, 55, 255}

	for col in 0 ..< len(state.waveform_cache) {
		wc := state.waveform_cache[col]
		x := rect.x + f32(col)
		y_min := center_y - wc.max_val * half_h
		y_max := center_y - wc.min_val * half_h

		col_time := screen_x_to_time(state, x)

		// Advance note cursor to stay near column time
		for note_cursor < len(notes) - 1 && notes[note_cursor].time < col_time - hop_time {
			note_cursor += 1
		}

		// Find nearest passing note within hop_time window
		color := dim_color
		best_dist: f32 = hop_time * 2
		for i in max(0, note_cursor - 2) ..< min(len(notes), note_cursor + 4) {
			n := notes[i]
			if n.confidence < state.confidence_threshold do continue
			if n.frequency < state.min_freq_filter || n.frequency > state.max_freq_filter do continue
			dist := abs(n.time - col_time)
			if dist < best_dist {
				best_dist = dist
				nc := note_colors[n.note_index]
				color = rl.Color{nc.r, nc.g, nc.b, 200}
			}
		}

		if state.has_selection {
			if col_time >= state.selection_start && col_time <= state.selection_end {
				// Brighten selected region
				color = rl.Color{
					u8(min(i32(color.r) + 40, 255)),
					u8(min(i32(color.g) + 40, 255)),
					u8(min(i32(color.b) + 40, 255)),
					255,
				}
			}
		}

		rl.DrawLineV({x, y_min}, {x, y_max}, color)
	}

	// Playback cursor
	cursor_x := time_to_screen_x(state, state.current_time)
	if cursor_x >= rect.x && cursor_x <= rect.x + rect.width {
		rl.DrawLineV(
			{cursor_x, rect.y},
			{cursor_x, rect.y + rect.height},
			rl.Color{255, 80, 80, 255},
		)
	}

	// Time labels
	label_count := int(state.view_duration / 5.0) + 1
	label_count = math.clamp(label_count, 2, 20)
	step := state.view_duration / f32(label_count)
	for i in 0 ..= label_count {
		t := state.view_start + f32(i) * step
		x := time_to_screen_x(state, t)
		if x < rect.x || x > rect.x + rect.width do continue

		minutes := int(t) / 60
		seconds := int(t) % 60
		label := rl.TextFormat("%d:%02d", i32(minutes), i32(seconds))
		draw_text(state, label, x - 10, rect.y + rect.height + 2, 13, rl.Color{150, 150, 160, 255})
	}
}

update_waveform_input :: proc(state: ^App_State) {
	if !state.audio_loaded do return
	if state.library_open do return

	mouse := rl.GetMousePosition()
	rect := state.waveform_rect
	in_rect := rl.CheckCollisionPointRec(mouse, rect)

	// Zoom with mouse wheel
	wheel := rl.GetMouseWheelMove()
	if in_rect && wheel != 0 {
		if rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL) {
			// Zoom centered on mouse position
			mouse_time := screen_x_to_time(state, mouse.x)
			zoom_factor: f32 = 1.0 - wheel * 0.1
			new_duration := math.clamp(state.view_duration * zoom_factor, 0.5, state.duration)

			mouse_frac := (mouse.x - rect.x) / rect.width
			state.view_start = mouse_time - mouse_frac * new_duration
			state.view_duration = new_duration
			clamp_view(state)
			state.cache_dirty = true
		} else {
			// Scroll horizontally
			scroll_amount := state.view_duration * 0.1 * (-wheel)
			state.view_start = math.clamp(state.view_start + scroll_amount, 0, state.duration - state.view_duration)
			state.cache_dirty = true
		}
	}

	// Left-click: seek on click, select on drag (min 8px movement)
	DRAG_THRESHOLD :: 8

	if in_rect && rl.IsMouseButtonPressed(.LEFT) {
		state.click_start_x = mouse.x
		click_time := screen_x_to_time(state, mouse.x)

		if state.has_selection {
			handle_threshold: f32 = 8
			start_x := time_to_screen_x(state, state.selection_start)
			end_x := time_to_screen_x(state, state.selection_end)

			if abs(mouse.x - start_x) < handle_threshold {
				state.drag_handle = .Left
				state.is_selecting = true
			} else if abs(mouse.x - end_x) < handle_threshold {
				state.drag_handle = .Right
				state.is_selecting = true
			} else {
				// Will become selection or seek on release
				state.selection_start = click_time
				state.selection_end = click_time
				state.drag_handle = .Right
				state.is_selecting = false
				state.has_selection = false
			}
		} else {
			state.selection_start = click_time
			state.selection_end = click_time
			state.drag_handle = .Right
			state.is_selecting = false
		}
	}

	if in_rect && rl.IsMouseButtonDown(.LEFT) && !state.is_selecting {
		// Start selecting only after exceeding drag threshold
		if abs(mouse.x - state.click_start_x) >= DRAG_THRESHOLD {
			state.is_selecting = true
			state.has_selection = true
		}
	}

	if state.is_selecting && rl.IsMouseButtonDown(.LEFT) {
		drag_time := screen_x_to_time(state, mouse.x)
		drag_time = math.clamp(drag_time, 0, state.duration)

		switch state.drag_handle {
		case .Left:
			state.selection_start = min(drag_time, state.selection_end - 0.01)
		case .Right:
			state.selection_end = max(drag_time, state.selection_start + 0.01)
		case .Body:
		case .None:
		}
	}

	if rl.IsMouseButtonReleased(.LEFT) && !state.skip_waveform_click {
		if state.is_selecting {
			state.is_selecting = false
			state.drag_handle = .None

			if state.selection_start > state.selection_end {
				state.selection_start, state.selection_end = state.selection_end, state.selection_start
			}

			if state.selection_end - state.selection_start < 0.05 {
				state.has_selection = false
			} else {
				// Seek to selection start and begin playback
				rl.SeekMusicStream(state.music, state.selection_start)
				state.current_time = state.selection_start
				if !state.is_playing {
					rl.PlayMusicStream(state.music)
					rl.SeekMusicStream(state.music, state.selection_start)
					rl.SetMusicPitch(state.music, state.playback_speed)
					rl.SetMusicVolume(state.music, state.volume)
					state.is_playing = true
				}
				state.loop_enabled = true
			}
		} else if in_rect {
			// Click without drag — seek to position
			seek_time := screen_x_to_time(state, mouse.x)
			seek_time = math.clamp(seek_time, 0, state.duration)
			rl.SeekMusicStream(state.music, seek_time)
			state.current_time = seek_time
		}
		state.drag_handle = .None
	}
	if rl.IsMouseButtonReleased(.LEFT) {
		state.skip_waveform_click = false
	}

	// Click to seek (right-click)
	if in_rect && rl.IsMouseButtonPressed(.RIGHT) {
		seek_time := screen_x_to_time(state, mouse.x)
		seek_time = math.clamp(seek_time, 0, state.duration)
		rl.SeekMusicStream(state.music, seek_time)
		state.current_time = seek_time
	}
}

screen_x_to_time :: proc(state: ^App_State, x: f32) -> f32 {
	return state.view_start + (x - state.waveform_rect.x) / state.waveform_rect.width * state.view_duration
}

time_to_screen_x :: proc(state: ^App_State, t: f32) -> f32 {
	return state.waveform_rect.x + (t - state.view_start) / state.view_duration * state.waveform_rect.width
}

clamp_view :: proc(state: ^App_State) {
	if state.view_start < 0 do state.view_start = 0
	if state.view_start + state.view_duration > state.duration {
		state.view_start = max(state.duration - state.view_duration, 0)
	}
	if state.view_duration > state.duration {
		state.view_duration = state.duration
		state.view_start = 0
	}
}
