package music_trainer

import "core:c"
import "core:math"
import "core:path/filepath"
import "core:strings"

import rl "vendor:raylib"

TITLE_HEIGHT :: 50
URL_HEIGHT :: 45
WAVEFORM_TOP :: 100
CONTROLS_HEIGHT :: 90
STATUS_HEIGHT :: 30
NOTE_DISPLAY_HEIGHT :: 110

FONT_PATH      :: "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf"
FONT_BOLD_PATH :: "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf"
FONT_SIZE      :: 22
FONT_SPACING   :: 1.0

load_fonts :: proc(state: ^App_State) {
	state.font = rl.LoadFontEx(FONT_PATH, FONT_SIZE, nil, 0)
	state.font_bold = rl.LoadFontEx(FONT_BOLD_PATH, 48, nil, 0)

	if state.font.glyphCount > 0 && state.font_bold.glyphCount > 0 {
		rl.SetTextureFilter(state.font.texture, .BILINEAR)
		rl.SetTextureFilter(state.font_bold.texture, .BILINEAR)
		state.fonts_loaded = true
	}
}

gui_color :: proc(hex: u32) -> c.int {
	return transmute(c.int)hex
}

setup_gui_style :: proc(state: ^App_State) {
	if state.fonts_loaded {
		rl.GuiSetFont(state.font)
	}

	rl.GuiSetStyle(.DEFAULT, c.int(rl.GuiDefaultProperty.TEXT_SIZE), FONT_SIZE)
	rl.GuiSetStyle(.DEFAULT, c.int(rl.GuiDefaultProperty.TEXT_SPACING), 1)

	rl.GuiSetStyle(.DEFAULT, c.int(rl.GuiControlProperty.TEXT_COLOR_NORMAL), gui_color(0xDDDDDDFF))
	rl.GuiSetStyle(.DEFAULT, c.int(rl.GuiControlProperty.TEXT_COLOR_FOCUSED), gui_color(0xFFFFFFFF))
	rl.GuiSetStyle(.DEFAULT, c.int(rl.GuiControlProperty.TEXT_COLOR_PRESSED), gui_color(0xFFFFFFFF))

	rl.GuiSetStyle(.DEFAULT, c.int(rl.GuiControlProperty.BASE_COLOR_NORMAL), gui_color(0x2A2A35FF))
	rl.GuiSetStyle(.DEFAULT, c.int(rl.GuiControlProperty.BASE_COLOR_FOCUSED), gui_color(0x3A3A48FF))
	rl.GuiSetStyle(.DEFAULT, c.int(rl.GuiControlProperty.BASE_COLOR_PRESSED), gui_color(0x4A4A58FF))
	rl.GuiSetStyle(.DEFAULT, c.int(rl.GuiControlProperty.BORDER_COLOR_NORMAL), gui_color(0x555566FF))
	rl.GuiSetStyle(.DEFAULT, c.int(rl.GuiControlProperty.BORDER_COLOR_FOCUSED), gui_color(0x7788AAFF))
}

// Helpers for font-based text
draw_text :: proc(state: ^App_State, text: cstring, x, y: f32, size: f32, color: rl.Color) {
	if state.fonts_loaded {
		rl.DrawTextEx(state.font, text, {x, y}, size, FONT_SPACING, color)
	} else {
		rl.DrawText(text, i32(x), i32(y), i32(size), color)
	}
}

draw_text_bold :: proc(state: ^App_State, text: cstring, x, y: f32, size: f32, color: rl.Color) {
	if state.fonts_loaded {
		rl.DrawTextEx(state.font_bold, text, {x, y}, size, FONT_SPACING, color)
	} else {
		rl.DrawText(text, i32(x), i32(y), i32(size), color)
	}
}

measure_text :: proc(state: ^App_State, text: cstring, size: f32) -> f32 {
	if state.fonts_loaded {
		return rl.MeasureTextEx(state.font, text, size, FONT_SPACING).x
	}
	return f32(rl.MeasureText(text, i32(size)))
}

measure_text_bold :: proc(state: ^App_State, text: cstring, size: f32) -> f32 {
	if state.fonts_loaded {
		return rl.MeasureTextEx(state.font_bold, text, size, FONT_SPACING).x
	}
	return f32(rl.MeasureText(text, i32(size)))
}

// ---

draw_ui :: proc(state: ^App_State) {
	w := f32(rl.GetScreenWidth())
	h := f32(rl.GetScreenHeight())
	pad: f32 = 12

	note_bottom := h - STATUS_HEIGHT - CONTROLS_HEIGHT
	waveform_bottom := note_bottom - NOTE_DISPLAY_HEIGHT

	state.waveform_rect = {pad, WAVEFORM_TOP, w - 2 * pad, waveform_bottom - WAVEFORM_TOP}
	state.note_display_rect = {pad, waveform_bottom, w - 2 * pad, NOTE_DISPLAY_HEIGHT}

	draw_title_bar(state, w)
	draw_url_bar(state, w)
	draw_controls(state, w, h)
	draw_status_bar(state, w, h)
	draw_note_display(state)

	if !state.audio_loaded {
		rect := state.waveform_rect
		rl.DrawRectangleRec(rect, rl.Color{25, 25, 30, 255})
		rl.DrawRectangleLinesEx(rect, 2, rl.Color{80, 80, 100, 255})

		hint: cstring = "Drop an audio file here"
		hw := measure_text(state, hint, 24)
		draw_text(state, hint, rect.x + rect.width / 2 - hw / 2, rect.y + rect.height / 2 - 20, 24, rl.Color{140, 140, 160, 255})

		hint2: cstring = "or pass a file path as argument"
		hw2 := measure_text(state, hint2, 18)
		draw_text(state, hint2, rect.x + rect.width / 2 - hw2 / 2, rect.y + rect.height / 2 + 15, 18, rl.Color{100, 100, 120, 255})
	}

	handle_keyboard(state)
}

draw_title_bar :: proc(state: ^App_State, w: f32) {
	rl.DrawRectangleRec({0, 0, w, TITLE_HEIGHT}, rl.Color{22, 22, 28, 255})
	draw_text_bold(state, "Music Trainer", 14, 11, 28, rl.Color{220, 220, 230, 255})

	// Library button
	lib_btn_w: f32 = 80
	lib_btn_h: f32 = 32
	lib_btn_x := w - lib_btn_w - 14
	lib_btn_y: f32 = 9
	if rl.GuiButton({lib_btn_x, lib_btn_y, lib_btn_w, lib_btn_h}, "Library") {
		state.library_open = !state.library_open
		if state.library_open {
			scan_library(state)
		}
	}

	if state.audio_loaded {
		name := rl.TextFormat("%s", strings.clone_to_cstring(state.file_name, context.temp_allocator))
		nw := measure_text(state, name, 18)
		draw_text(state, name, lib_btn_x - nw - 14, 16, 18, rl.Color{160, 160, 180, 255})
	}

	if state.audio_loaded {
		minutes := int(state.current_time) / 60
		seconds := int(state.current_time) % 60
		total_min := int(state.duration) / 60
		total_sec := int(state.duration) % 60
		time_str := rl.TextFormat("%d:%02d / %d:%02d", i32(minutes), i32(seconds), i32(total_min), i32(total_sec))
		tw := measure_text(state, time_str, 20)
		draw_text(state, time_str, w / 2 - tw / 2, 15, 20, rl.Color{200, 200, 220, 255})
	}
}

draw_url_bar :: proc(state: ^App_State, w: f32) {
	y: f32 = TITLE_HEIGHT + 4
	pad: f32 = 12
	btn_w: f32 = 120
	bar_h: f32 = 38

	url_rect := rl.Rectangle{pad, y, w - 3 * pad - btn_w, bar_h}
	btn_rect := rl.Rectangle{w - pad - btn_w, y, btn_w, bar_h}

	if rl.GuiTextBox(url_rect, cstring(raw_data(state.url_buffer[:])), 512, state.url_edit_mode) {
		state.url_edit_mode = !state.url_edit_mode
	}

	// Handle Ctrl+V paste into URL field
	if state.url_edit_mode {
		ctrl := rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)
		if ctrl && rl.IsKeyPressed(.V) {
			clip := rl.GetClipboardText()
			if clip != nil {
				// Find current string length in buffer
				buf_len := 0
				for buf_len < 510 && state.url_buffer[buf_len] != 0 {
					buf_len += 1
				}
				// Append clipboard text
				clip_str := string(clip)
				for ch in clip_str {
					if buf_len >= 510 do break
					state.url_buffer[buf_len] = u8(ch)
					buf_len += 1
				}
				state.url_buffer[buf_len] = 0
			}
		}
		// Ctrl+A select all (clear and ready for paste)
		if ctrl && rl.IsKeyPressed(.A) {
			state.url_buffer = {}
		}
	}

	if rl.GuiButton(btn_rect, "Download") && !state.is_downloading {
		url := string(cstring(raw_data(state.url_buffer[:])))
		if len(url) > 0 {
			download_from_url(state, url)
		}
	}
}

draw_sep :: proc(x: f32, area_y: f32) {
	rl.DrawLineV({x, area_y + 14}, {x, area_y + CONTROLS_HEIGHT - 14}, rl.Color{55, 55, 70, 255})
}

draw_controls :: proc(state: ^App_State, w: f32, h: f32) {
	area_y := h - STATUS_HEIGHT - CONTROLS_HEIGHT
	pad: f32 = 20
	gap: f32 = 24

	rl.DrawRectangleRec({0, area_y, w, CONTROLS_HEIGHT}, rl.Color{22, 22, 28, 255})
	rl.DrawLineV({0, area_y}, {w, area_y}, rl.Color{50, 50, 60, 255})

	btn_h: f32 = 40
	btn_sz: f32 = 44
	btn_y := area_y + (CONTROLS_HEIGHT - btn_sz) / 2
	icon_pad: f32 = 12

	// -- Play/Pause --
	play_rect := rl.Rectangle{pad, btn_y, btn_sz, btn_sz}
	play_hover := rl.CheckCollisionPointRec(rl.GetMousePosition(), play_rect)
	play_bg: rl.Color = play_hover ? {60, 60, 75, 255} : {40, 40, 52, 255}
	rl.DrawRectangleRounded(play_rect, 0.2, 4, play_bg)
	rl.DrawRectangleRoundedLinesEx(play_rect, 0.2, 4, 1, rl.Color{80, 80, 100, 255})

	if state.is_playing {
		// Pause icon: two vertical bars (yellow)
		bar_w: f32 = 5
		bar_h: f32 = 20
		bar_gap: f32 = 6
		bx := play_rect.x + (btn_sz - bar_w * 2 - bar_gap) / 2
		by := play_rect.y + (btn_sz - bar_h) / 2
		rl.DrawRectangleRec({bx, by, bar_w, bar_h}, rl.Color{240, 200, 40, 255})
		rl.DrawRectangleRec({bx + bar_w + bar_gap, by, bar_w, bar_h}, rl.Color{240, 200, 40, 255})
	} else {
		// Play icon: triangle (green)
		cx := play_rect.x + btn_sz / 2
		cy := play_rect.y + btn_sz / 2
		rl.DrawTriangle(
			{cx - 7, cy - 10},
			{cx - 7, cy + 10},
			{cx + 10, cy},
			rl.Color{60, 200, 80, 255},
		)
	}
	if play_hover && rl.IsMouseButtonPressed(.LEFT) {
		toggle_playback(state)
	}
	cursor := pad + btn_sz + 8

	// -- Stop --
	stop_rect := rl.Rectangle{cursor, btn_y, btn_sz, btn_sz}
	stop_hover := rl.CheckCollisionPointRec(rl.GetMousePosition(), stop_rect)
	stop_bg: rl.Color = stop_hover ? {60, 60, 75, 255} : {40, 40, 52, 255}
	rl.DrawRectangleRounded(stop_rect, 0.2, 4, stop_bg)
	rl.DrawRectangleRoundedLinesEx(stop_rect, 0.2, 4, 1, rl.Color{80, 80, 100, 255})
	// Stop icon: square (red)
	sq_sz: f32 = 16
	rl.DrawRectangleRec(
		{stop_rect.x + (btn_sz - sq_sz) / 2, stop_rect.y + (btn_sz - sq_sz) / 2, sq_sz, sq_sz},
		rl.Color{220, 60, 60, 255},
	)
	if stop_hover && rl.IsMouseButtonPressed(.LEFT) {
		stop_playback(state)
	}
	cursor += btn_sz + 8

	// -- Record --
	rec_rect := rl.Rectangle{cursor, btn_y, btn_sz, btn_sz}
	rec_hover := rl.CheckCollisionPointRec(rl.GetMousePosition(), rec_rect)
	rec_bg: rl.Color
	if state.is_recording {
		rec_bg = {80, 40, 50, 255}
	} else if rec_hover {
		rec_bg = {60, 60, 75, 255}
	} else {
		rec_bg = {40, 40, 52, 255}
	}
	rl.DrawRectangleRounded(rec_rect, 0.2, 4, rec_bg)
	rl.DrawRectangleRoundedLinesEx(rec_rect, 0.2, 4, 1, rl.Color{80, 80, 100, 255})
	// Record icon: circle (pink)
	rec_color: rl.Color = state.is_recording ? {255, 160, 180, 255} : {230, 140, 160, 255}
	rl.DrawCircle(
		i32(rec_rect.x + btn_sz / 2), i32(rec_rect.y + btn_sz / 2),
		9, rec_color,
	)
	if rec_hover && rl.IsMouseButtonPressed(.LEFT) {
		if state.is_recording {
			stop_recording(state)
		} else {
			start_recording(state)
		}
	}
	cursor += btn_sz + gap

	draw_sep(cursor, area_y)
	cursor += gap

	// -- Loop --
	rl.GuiCheckBox({cursor, btn_y + 9, 22, 22}, "Loop", &state.loop_enabled)
	loop_label_w := measure_text(state, "Loop", f32(FONT_SIZE))
	cursor += 22 + 8 + loop_label_w + gap

	draw_sep(cursor, area_y)
	cursor += gap

	// -- Speed / Volume (stacked) --
	remaining := w - cursor - pad
	bay_w := (remaining - gap) / 2
	bay_w = math.clamp(bay_w, 150, 350)
	slider_h: f32 = 12
	row1_y := area_y + 10
	row2_y := area_y + 48

	speed_label := rl.TextFormat("Speed: %.2fx", state.playback_speed)
	draw_text(state, speed_label, cursor, row1_y, 14, rl.Color{200, 200, 220, 255})
	rl.GuiSlider({cursor, row1_y + 18, bay_w, slider_h}, "", "", &state.playback_speed, 0.25, 2.0)

	if state.is_playing {
		rl.SetMusicPitch(state.music, state.playback_speed)
	}

	vol_pct := rl.TextFormat("Vol: %d%%", i32(state.volume * 100))
	draw_text(state, vol_pct, cursor, row2_y, 14, rl.Color{200, 200, 220, 255})
	rl.GuiSlider({cursor, row2_y + 18, bay_w, slider_h}, "", "", &state.volume, 0.0, 1.0)

	if state.audio_loaded {
		rl.SetMusicVolume(state.music, state.volume)
	}

	cursor += bay_w + gap

	draw_sep(cursor, area_y)
	cursor += gap

	// -- Detection filters (stacked) --
	det_w := w - cursor - pad
	det_w = math.clamp(det_w, 150, 350)

	sens_label := rl.TextFormat("Sensitivity: %.1f", state.confidence_threshold)
	draw_text(state, sens_label, cursor, row1_y, 14, rl.Color{180, 180, 200, 255})
	rl.GuiSlider({cursor, row1_y + 18, det_w, slider_h}, "", "", &state.confidence_threshold, 1.0, 10.0)

	// Freq range on second row, split in half
	freq_half := (det_w - 16) / 2

	min_note, _, min_oct, _ := frequency_to_note(f64(state.min_freq_filter))
	min_label := rl.TextFormat("Min: %dHz (%s%d)", i32(state.min_freq_filter), strings.clone_to_cstring(min_note, context.temp_allocator), i32(min_oct))
	draw_text(state, min_label, cursor, row2_y, 12, rl.Color{170, 170, 190, 255})
	rl.GuiSlider({cursor, row2_y + 16, freq_half, slider_h}, "", "", &state.min_freq_filter, 20.0, 2000.0)

	max_x := cursor + freq_half + 16
	max_note, _, max_oct, _ := frequency_to_note(f64(state.max_freq_filter))
	max_label := rl.TextFormat("Max: %dHz (%s%d)", i32(state.max_freq_filter), strings.clone_to_cstring(max_note, context.temp_allocator), i32(max_oct))
	draw_text(state, max_label, max_x, row2_y, 12, rl.Color{170, 170, 190, 255})
	rl.GuiSlider({max_x, row2_y + 16, freq_half, slider_h}, "", "", &state.max_freq_filter, 200.0, 8000.0)
}

draw_status_bar :: proc(state: ^App_State, w: f32, h: f32) {
	y := h - STATUS_HEIGHT
	rl.DrawRectangleRec({0, y, w, STATUS_HEIGHT}, rl.Color{22, 22, 28, 255})
	draw_text(state, state.download_status, 14, y + 5, 16, rl.Color{160, 160, 180, 255})

	if state.has_selection {
		sel_dur := state.selection_end - state.selection_start
		sel_str := rl.TextFormat("Selection: %.1fs - %.1fs (%.1fs)", state.selection_start, state.selection_end, sel_dur)
		sw := measure_text(state, sel_str, 16)
		draw_text(state, sel_str, w - sw - 14, y + 5, 16, rl.Color{100, 160, 240, 255})
	}
}

draw_note_display :: proc(state: ^App_State) {
	rect := state.note_display_rect
	rl.DrawRectangleRec(rect, rl.Color{16, 16, 20, 255})
	rl.DrawRectangleLinesEx(rect, 1, rl.Color{50, 50, 60, 255})

	if !state.audio_loaded || len(state.detected_notes) == 0 do return

	notes := state.detected_notes[:]

	current_panel_w: f32 = 160
	timeline_rect := rl.Rectangle{rect.x, rect.y, rect.width - current_panel_w, rect.height}

	sep_x := rect.x + timeline_rect.width
	rl.DrawLineV({sep_x, rect.y + 8}, {sep_x, rect.y + rect.height - 8}, rl.Color{50, 50, 65, 255})

	// -- Timeline notes --
	view_end := state.view_start + state.view_duration
	min_pixel_gap: f32 = 45
	last_drawn_x: f32 = -100
	prev_midi := -1
	label_y := rect.y + rect.height * 0.55
	marker_top := rect.y + 8

	for &note in notes {
		if note.confidence < state.confidence_threshold do continue
		if note.frequency < state.min_freq_filter || note.frequency > state.max_freq_filter do continue
		if note.time < state.view_start || note.time > view_end do continue

		x := time_to_screen_x(state, note.time)
		if x < timeline_rect.x || x > timeline_rect.x + timeline_rect.width do continue

		if note.midi_num == prev_midi && (x - last_drawn_x) < min_pixel_gap do continue

		color := note_colors[note.note_index]
		note_label := rl.TextFormat("%s%d", strings.clone_to_cstring(note.note_name, context.temp_allocator), i32(note.octave))

		rl.DrawLineV({x, marker_top}, {x, rect.y + rect.height * 0.48}, rl.Color{color.r, color.g, color.b, 100})
		draw_text(state, note_label, x - 10, label_y, 17, color)

		last_drawn_x = x
		prev_midi = note.midi_num
	}

	// -- Current note panel --
	note_idx := find_note_at_time(notes, state.current_time, state.confidence_threshold, state.min_freq_filter, state.max_freq_filter)
	if note_idx >= 0 {
		note := notes[note_idx]
		if abs(note.time - state.current_time) < f32(HOP_SIZE) / f32(state.sample_rate) * 2 {
			color := note_colors[note.note_index]
			current_label := rl.TextFormat("%s%d", strings.clone_to_cstring(note.note_name, context.temp_allocator), i32(note.octave))
			lw := measure_text_bold(state, current_label, 44)
			cx := sep_x + (current_panel_w - lw) / 2
			cy := rect.y + 14
			draw_text_bold(state, current_label, cx, cy, 44, color)

			freq_label := rl.TextFormat("%.1f Hz", note.frequency)
			fw := measure_text(state, freq_label, 16)
			draw_text(state, freq_label, sep_x + (current_panel_w - fw) / 2, cy + 50, 16, rl.Color{color.r, color.g, color.b, 180})
		}
	}
}

draw_library_overlay :: proc(state: ^App_State) {
	if !state.library_open do return
	w := f32(rl.GetScreenWidth())
	h := f32(rl.GetScreenHeight())
	draw_library_panel(state, w, h)
}

draw_library_panel :: proc(state: ^App_State, w: f32, h: f32) {
	panel_w: f32 = 340
	panel_x := w - panel_w
	panel_y: f32 = TITLE_HEIGHT
	panel_h := h - TITLE_HEIGHT

	// Dim background
	rl.DrawRectangleRec({0, 0, panel_x, h}, rl.Color{0, 0, 0, 80})

	// Panel background
	rl.DrawRectangleRec({panel_x, panel_y, panel_w, panel_h}, rl.Color{28, 28, 36, 255})
	rl.DrawLineV({panel_x, panel_y}, {panel_x, panel_y + panel_h}, rl.Color{60, 60, 80, 255})

	// Header
	header_h: f32 = 40
	draw_text_bold(state, "Library", panel_x + 14, panel_y + 8, 24, rl.Color{220, 220, 230, 255})

	// Close button
	close_sz: f32 = 28
	close_x := panel_x + panel_w - close_sz - 8
	close_y := panel_y + 6
	if rl.GuiButton({close_x, close_y, close_sz, close_sz}, "X") {
		state.library_open = false
		return
	}

	// File list
	list_y := panel_y + header_h + 4
	item_h: f32 = 36
	mouse := rl.GetMousePosition()

	if len(state.library_files) == 0 {
		draw_text(state, "No audio files found", panel_x + 14, list_y + 10, 16, rl.Color{120, 120, 140, 255})
		dir_str := rl.TextFormat("in ~/Music/music_trainer/")
		draw_text(state, dir_str, panel_x + 14, list_y + 32, 14, rl.Color{90, 90, 110, 255})
		return
	}

	// Scroll with mouse wheel when hovering panel
	panel_rect := rl.Rectangle{panel_x, list_y, panel_w, panel_h - header_h - 4}
	if rl.CheckCollisionPointRec(mouse, panel_rect) {
		wheel := rl.GetMouseWheelMove()
		if wheel != 0 {
			state.library_scroll -= wheel * item_h * 2
			max_scroll := f32(len(state.library_files)) * item_h - panel_rect.height
			state.library_scroll = math.clamp(state.library_scroll, 0, max(max_scroll, 0))
		}
	}

	rl.BeginScissorMode(i32(panel_x), i32(list_y), i32(panel_w), i32(panel_h - header_h - 4))

	for file, i in state.library_files {
		y := list_y + f32(i) * item_h - state.library_scroll
		if y + item_h < list_y || y > panel_y + panel_h do continue

		item_rect := rl.Rectangle{panel_x + 4, y, panel_w - 8, item_h - 2}
		hovered := rl.CheckCollisionPointRec(mouse, item_rect)

		if hovered {
			rl.DrawRectangleRec(item_rect, rl.Color{50, 50, 65, 255})
		}

		_, name := filepath.split(file)
		display := strings.clone_to_cstring(name, context.temp_allocator)

		// Truncate display if too wide
		max_text_w := panel_w - 28
		text_color := hovered ? rl.Color{255, 255, 255, 255} : rl.Color{200, 200, 215, 255}
		draw_text(state, display, panel_x + 14, y + 8, 16, text_color)

		if hovered && rl.IsMouseButtonPressed(.LEFT) {
			cpath := strings.clone_to_cstring(file, context.temp_allocator)
			load_audio_file(state, cpath)
			state.library_open = false
			state.skip_waveform_click = true
			rl.EndScissorMode()
			return
		}
	}

	rl.EndScissorMode()
}

handle_keyboard :: proc(state: ^App_State) {
	if state.url_edit_mode do return

	if rl.IsKeyPressed(.SPACE) {
		toggle_playback(state)
	}
	if rl.IsKeyPressed(.LEFT) {
		seek_relative(state, -5.0)
	}
	if rl.IsKeyPressed(.RIGHT) {
		seek_relative(state, 5.0)
	}
	if rl.IsKeyPressed(.UP) {
		set_playback_speed(state, state.playback_speed + 0.05)
	}
	if rl.IsKeyPressed(.DOWN) {
		set_playback_speed(state, state.playback_speed - 0.05)
	}
	if rl.IsKeyPressed(.ESCAPE) {
		state.has_selection = false
		state.is_selecting = false
	}
}
