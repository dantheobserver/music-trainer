package music_trainer

import "core:c"
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
	if state.is_recording {
		draw_recording_strip(state)
		return
	}
	if !state.audio_loaded do return

	rect := state.waveform_rect
	center_y := rect.y + rect.height * 0.5

	// Background — subtle vertical gradient, rounded border
	draw_gradient_vertical(rect, BG_PANEL, rl.Color{16, 18, 26, 255})
	rl.DrawRectangleRoundedLinesEx(rect, 0.04, 4, 1, BORDER)

	// Faint time grid — accent-tinted
	grid_count := int(state.view_duration / 5.0) + 1
	grid_count = math.clamp(grid_count, 2, 20)
	grid_step := state.view_duration / f32(grid_count)
	for i in 0 ..= grid_count {
		t := state.view_start + f32(i) * grid_step
		x := time_to_screen_x(state, t)
		if x > rect.x + 1 && x < rect.x + rect.width - 1 {
			rl.DrawLineV({x, rect.y + 1}, {x, rect.y + rect.height - 1}, rl.Color{60, 80, 84, 55})
		}
	}

	// Center line glow is drawn after the waveform so the ribbon shows through.

	if state.cache_dirty {
		compute_waveform_cache(state)
	}

	// Nesting breadcrumb
	if is_isolated(state) {
		draw_isolation_breadcrumb(state)
	}

	if state.has_selection {
		sel_x1 := time_to_screen_x(state, state.selection_start)
		sel_x2 := time_to_screen_x(state, state.selection_end)
		sel_x1 = math.clamp(sel_x1, rect.x, rect.x + rect.width)
		sel_x2 = math.clamp(sel_x2, rect.x, rect.x + rect.width)

		// Selection fill — soft gradient highlight
		sel_rect := rl.Rectangle{sel_x1, rect.y, sel_x2 - sel_x1, rect.height}
		draw_gradient_vertical(sel_rect, rl.Color{120, 210, 232, 30}, rl.Color{120, 210, 232, 16})

		// Selection handles — rounded with accent glow
		handle_w: f32 = 5
		handle_a := rl.Rectangle{sel_x1 - handle_w / 2, rect.y, handle_w, rect.height}
		handle_b := rl.Rectangle{sel_x2 - handle_w / 2, rect.y, handle_w, rect.height}
		draw_rounded_glow(handle_a, 0.5, SELECTION, 2, 2.0)
		draw_rounded_glow(handle_b, 0.5, SELECTION, 2, 2.0)
		rl.DrawRectangleRec(handle_a, SELECTION)
		rl.DrawRectangleRec(handle_b, SELECTION)
	}

	// Waveform — neon ribbon: per-column bloom + crisp core, colored by detected
	// note, with amplitude-driven brightness so quiet parts recede.
	half_h := rect.height * 0.5
	notes := state.detected_notes[:]
	note_cursor := 0
	hop_time := f32(HOP_SIZE) / f32(state.sample_rate)
	// Muted teal for non-pitch sections — sits naturally in the theme
	dim_color := rl.Color{52, 74, 78, 255}

	n := len(state.waveform_cache)
	top_pts := make([]rl.Vector2, n, context.temp_allocator)
	bot_pts := make([]rl.Vector2, n, context.temp_allocator)

	for col in 0 ..< n {
		wc := state.waveform_cache[col]
		x := rect.x + f32(col)
		y_min := center_y - wc.max_val * half_h
		y_max := center_y - wc.min_val * half_h
		top := min(y_min, y_max)
		bot := max(y_min, y_max)
		if bot - top < 1.0 { bot = top + 1.0 }
		top_pts[col] = {x, top}
		bot_pts[col] = {x, bot}

		col_time := screen_x_to_time(state, x)

		// Advance note cursor to stay near column time
		for note_cursor < len(notes) - 1 && notes[note_cursor].time < col_time - hop_time {
			note_cursor += 1
		}

		// Find nearest passing note within hop_time window
		color := dim_color
		best_dist: f32 = hop_time * 2
		for i in max(0, note_cursor - 2) ..< min(len(notes), note_cursor + 4) {
			note := notes[i]
			if note.confidence < state.confidence_threshold do continue
			if note.frequency < state.min_freq_filter || note.frequency > state.max_freq_filter do continue
			dist := abs(note.time - col_time)
			if dist < best_dist {
				best_dist = dist
				nc := note_colors[note.note_index]
				color = rl.Color{nc.r, nc.g, nc.b, 255}
			}
		}

		// Amplitude-driven brightness (0.45..1.0)
		amp := abs(wc.max_val) + abs(wc.min_val)
		bright := 0.45 + 0.55 * math.clamp(amp * 0.5, 0.0, 1.0)

		if state.has_selection && col_time >= state.selection_start && col_time <= state.selection_end {
			// Brighten + boost selected region
			color = rl.Color{
				u8(min(i32(color.r) + 45, 255)),
				u8(min(i32(color.g) + 45, 255)),
				u8(min(i32(color.b) + 45, 255)),
				255,
			}
			bright = min(bright + 0.25, 1.0)
		}

		// Soft bloom halo around the column
		glow_a := u8(f32(color.a) * bright * 0.30)
		rl.DrawRectangleRec({x - 1, top, 3, bot - top}, rl.Color{color.r, color.g, color.b, glow_a})
		// Crisp neon core
		core_a := u8(f32(color.a) * bright * 0.95)
		rl.DrawLineV({x, top}, {x, bot}, rl.Color{color.r, color.g, color.b, core_a})
	}

	// Envelope sheen — a faint accent outline tracing the waveform silhouette
	if n > 1 {
		sheen := rl.Color{ACCENT_BRIGHT.r, ACCENT_BRIGHT.g, ACCENT_BRIGHT.b, 70}
		rl.DrawLineStrip(raw_data(top_pts), c.int(n), sheen)
		rl.DrawLineStrip(raw_data(bot_pts), c.int(n), sheen)
	}

	// Center line — a soft glowing horizon drawn over the ribbon. Low peak
	// alpha keeps it from overwhelming, so the waveform remains visible through it.
	draw_hglow(rect.x + 1, rect.x + rect.width - 1, center_y, 7, ACCENT, 60)
	rl.DrawLineEx(
		{rect.x + 1, center_y},
		{rect.x + rect.width - 1, center_y},
		1, rl.Color{ACCENT_BRIGHT.r, ACCENT_BRIGHT.g, ACCENT_BRIGHT.b, 120},
	)

// Playback cursor — a stylized neon scrubber: soft vertical glow tube, a
// bright 1px core, chevron markers capping the top/bottom, and a gently
// pulsing dot where it crosses the center line.
	cursor_x := time_to_screen_x(state, state.current_time)
	if cursor_x >= rect.x && cursor_x <= rect.x + rect.width {
		// Neon tube glow + crisp core
		draw_vglow(cursor_x, rect.y + 1, rect.y + rect.height - 1, 5, ACCENT, 90)
		rl.DrawLineV(
			{cursor_x, rect.y + 1},
			{cursor_x, rect.y + rect.height - 1},
			ACCENT_BRIGHT,
		)

		// Top chevron (pointing down into the waveform)
		rl.DrawTriangle(
			{cursor_x - 6, rect.y - 1},
			{cursor_x + 6, rect.y - 1},
			{cursor_x, rect.y + 7},
			ACCENT_BRIGHT,
		)
		// Bottom chevron (pointing up)
		rl.DrawTriangle(
			{cursor_x - 6, rect.y + rect.height + 1},
			{cursor_x + 6, rect.y + rect.height + 1},
			{cursor_x, rect.y + rect.height - 7},
			ACCENT_BRIGHT,
		)

		// Pulsing center dot — subtle breathing glow with a bright core
		pulse := 0.5 + 0.5 * math.sin(rl.GetTime() * 3.0)
		halo_r := 5.0 + pulse * 2.5
		halo_a := u8(120 + 80 * pulse)
		rl.DrawCircle(i32(cursor_x), i32(center_y), f32(halo_r), rl.Color{ACCENT.r, ACCENT.g, ACCENT.b, halo_a})
		rl.DrawCircle(i32(cursor_x), i32(center_y), 3, ACCENT_BRIGHT)
		rl.DrawCircle(i32(cursor_x), i32(center_y), 1.5, rl.Color{255, 255, 255, 235})
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
		draw_text(state, label, x - 10, rect.y + rect.height + 2, 13, TEXT_DIM)
	}

	draw_waveform_overlay(state)
}

RECORD_STRIP_PX :: 2.0 // horizontal size of one chunk entry

// Live capture display — a scrolling level strip, not a waveform. Each entry
// is the min/max extent of one ~21ms chunk (parec delivers at ~20ms latency so
// entries land roughly one per frame), and the write head shows the chunk
// currently filling, refreshed every frame. Time maps to pixels at a constant
// rate, so the motion never rescales and stays smooth; the cost is a few
// hundred simple primitives regardless of recording length. The detailed
// note-colored waveform only renders after stop, from the loaded file.
draw_recording_strip :: proc(state: ^App_State) {
	rect := state.waveform_rect
	center_y := rect.y + rect.height * 0.5

	// Flat background — one fill instead of the per-pixel-row gradient
	rl.DrawRectangleRec(rect, rl.Color{18, 20, 28, 255})
	rl.DrawRectangleRoundedLinesEx(rect, 0.04, 4, 1, BORDER)

	unit_per_sec := f32(record_sample_rate) / f32(RECORD_CHUNK_FRAMES)
	now_units := f32(record_strip_count) + f32(record_chunk_fill) / f32(RECORD_CHUNK_FRAMES)
	now_secs := now_units / unit_per_sec
	visible_units := rect.width / RECORD_STRIP_PX
	visible_secs := visible_units / unit_per_sec

	// Faint 5-second ticks scrolling with the strip
	first_tick := max(1, int((now_secs - visible_secs) / 5.0) + 1)
	last_tick := int(now_secs / 5.0)
	if last_tick >= first_tick {
		for m in first_tick ..= last_tick {
			x := strip_x(f32(m) * 5.0 * unit_per_sec, now_units, visible_units, rect)
			rl.DrawLineV({x, rect.y + 1}, {x, rect.y + rect.height - 1}, rl.Color{60, 80, 84, 45})
		}
	}

	// Silence baseline — drawn as a thin rect, not DrawLineEx: the app's
	// frame context (raygui/batch state) silently drops DrawLineEx primitives
	// here, while rects, lines and text render fine.
	rl.DrawRectangleRec(
		{rect.x + 1, center_y - 0.5, rect.width - 2, 1},
		rl.Color{ACCENT_BRIGHT.r, ACCENT_BRIGHT.g, ACCENT_BRIGHT.b, 60},
	)

	// Completed chunk entries, oldest first
	// Completed chunk entries, newest first so the loop can stop as soon as an
	// entry has scrolled off the left edge (the oldest entry starts ~1px outside)
	if record_strip_count > 0 {
		first := max(record_strip_count - int(visible_units) - 2, 0)
		for j := record_strip_count - 1; j >= first; j -= 1 {
			x := strip_x(f32(j) + 0.5, now_units, visible_units, rect)
			if x < rect.x - RECORD_STRIP_PX do break
			if x > rect.x + rect.width do continue
			draw_strip_entry(x, center_y, record_strip[j %% RECORD_LEVEL_CAP], rect.height)
		}
	}

	// Write head — the chunk currently filling, live every frame. It slides
	// toward the newest entry's slot and becomes it seamlessly on completion.
	if record_chunk_fill > 0 {
		head_unit := f32(record_strip_count) + f32(record_chunk_fill) * 0.5 / f32(RECORD_CHUNK_FRAMES)
		x := strip_x(head_unit, now_units, visible_units, rect)
		draw_strip_entry(x, center_y, record_chunk_partial, rect.height)
	}

	// Right-edge glow breathing with the live input level
	peak := max(abs(record_chunk_partial.min_val), abs(record_chunk_partial.max_val))
	draw_vglow(rect.x + rect.width - 1, rect.y + 1, rect.y + rect.height - 1, 4, RECORD_COLOR,
		u8(40 + 120 * math.clamp(peak * 1.3, 0.0, 1.0)))

	draw_recording_badge(state, rect)
}

// Map a chunk-time (in units of chunks since recording start) to screen x.
// While the recording is shorter than the window the strip anchors at the
// left edge; once it overflows, the write head locks to the right edge and
// everything scrolls left at a constant 2px per chunk.
strip_x :: proc(unit, now_units, visible_units: f32, rect: rl.Rectangle) -> f32 {
	if now_units > visible_units {
		return rect.x + rect.width - (now_units - unit) * RECORD_STRIP_PX
	}
	return rect.x + unit * RECORD_STRIP_PX
}

// One 2px column of the strip: the min/max extent of a chunk, alpha modulated
// by its peak so loud passages read brighter and silence stays a faint dot.
draw_strip_entry :: proc(x, center_y: f32, entry: Waveform_Column, panel_h: f32) {
	half_h := panel_h * 0.42
	top := center_y - entry.max_val * half_h
	bot := center_y - entry.min_val * half_h
	if bot - top < 2.0 {
		mid := (top + bot) * 0.5
		top, bot = mid - 1.0, mid + 1.0
	}
	peak := max(abs(entry.min_val), abs(entry.max_val))
	alpha := u8(90 + 160 * math.clamp(peak * 1.3, 0.0, 1.0))
	rl.DrawRectangleRec(
		{x - RECORD_STRIP_PX * 0.5, top, RECORD_STRIP_PX, bot - top},
		rl.Color{ACCENT_BRIGHT.r, ACCENT_BRIGHT.g, ACCENT_BRIGHT.b, alpha},
	)
}

// Pulsing REC badge pinned to the top-left of the waveform panel while a
// live capture is running.
draw_recording_badge :: proc(state: ^App_State, rect: rl.Rectangle) {
	pulse: f32 = 0.5 + 0.5 * f32(math.sin(rl.GetTime() * 5.0))
	dot_r: f32 = 5.0 + pulse * 1.5
	dot_a := u8(160 + 90 * pulse)

	pad: f32 = 10
	label: cstring = "REC"
	label_size: f32 = 16
	label_w := measure_text(state, label, label_size)

	secs := recording_duration()
	time_str := rl.TextFormat("%d:%02d", i32(secs) / 60, i32(secs) % 60)
	time_w := measure_text(state, time_str, label_size)

	// Linear layout: dot, REC label, elapsed time
	dot_x := rect.x + pad + 6 + dot_r
	dot_y := rect.y + pad + 8
	label_x := dot_x + dot_r + 6
	time_x := label_x + label_w + 8
	end_x := time_x + time_w

	// Soft pill behind the badge so it stays readable over the waveform
	pill := rl.Rectangle{rect.x + pad - 2, rect.y + pad - 2, end_x - rect.x - pad + 12, 24}
	rl.DrawRectangleRounded(pill, 0.4, 8, rl.Color{30, 16, 22, 190})
	rl.DrawRectangleRoundedLinesEx(pill, 0.4, 8, 1, rl.Color{RECORD_COLOR.r, RECORD_COLOR.g, RECORD_COLOR.b, 140})

	rl.DrawCircle(i32(dot_x), i32(dot_y), dot_r, rl.Color{RECORD_COLOR.r, RECORD_COLOR.g, RECORD_COLOR.b, dot_a})
	rl.DrawCircle(i32(dot_x), i32(dot_y), 2.5, rl.Color{255, 230, 238, 255})
	draw_text(state, label, label_x, rect.y + pad + 1, label_size, rl.Color{255, 190, 205, 255})
	draw_text(state, time_str, time_x, rect.y + pad + 1, label_size, TEXT_SEC)

	// "Now" edge — a soft glow marking where live audio lands
	draw_vglow(rect.x + rect.width - 1, rect.y + 1, rect.y + rect.height - 1, 4, RECORD_COLOR, 70)
}

OVERLAY_BTN_SZ :: 26
OVERLAY_BTN_GAP :: 4
OVERLAY_BAR_PAD :: 6
OVERLAY_ISO_W :: 58

get_overlay_bar_rect :: proc(state: ^App_State) -> rl.Rectangle {
	rect := state.waveform_rect
	show_isolate := state.has_selection
	show_restore := is_isolated(state)
	iso_w: f32 = show_isolate ? OVERLAY_ISO_W : 0
	restore_w: f32 = show_restore ? OVERLAY_ISO_W : 0
	btn_count: f32 = 1 // Full view always present
	if show_isolate do btn_count += 1
	if show_restore do btn_count += 1
	bar_w := OVERLAY_BAR_PAD * 2 + OVERLAY_BTN_SZ + OVERLAY_BTN_GAP * (btn_count - 1) + iso_w + restore_w
	bar_x := rect.x + 8
	bar_y := rect.y + rect.height - OVERLAY_BTN_SZ - OVERLAY_BAR_PAD * 2 - 4
	return {bar_x, bar_y, bar_w, OVERLAY_BTN_SZ + OVERLAY_BAR_PAD * 2}
}

draw_waveform_overlay :: proc(state: ^App_State) {
	mouse := rl.GetMousePosition()
	bar_rect := get_overlay_bar_rect(state)

	btn_sz: f32 = OVERLAY_BTN_SZ
	btn_gap: f32 = OVERLAY_BTN_GAP
	bar_pad: f32 = OVERLAY_BAR_PAD

	rl.DrawRectangleRounded(bar_rect, 0.15, 4, rl.Color{15, 15, 20, 180})

	cx := bar_rect.x + bar_pad
	cy := bar_rect.y + bar_pad

	// -- Isolate (when selection exists) --
	if state.has_selection {
		iso_rect := rl.Rectangle{cx, cy, OVERLAY_ISO_W, btn_sz}
		iso_hover := rl.CheckCollisionPointRec(mouse, iso_rect)
		if iso_hover {
			rl.DrawRectangleRounded(iso_rect, 0.2, 4, rl.Color{60, 60, 75, 140})
		}
		lw := measure_text(state, "Isolate", 13)
		draw_text(state, "Isolate", cx + (OVERLAY_ISO_W - lw) / 2, cy + 6, 13, {180, 180, 220, 220})
		if iso_hover && rl.IsMouseButtonPressed(.LEFT) {
			zoom_to_selection(state)
		}
		cx += OVERLAY_ISO_W + btn_gap
	}

	// -- Restore (when isolated) --
	if is_isolated(state) {
		restore_rect := rl.Rectangle{cx, cy, OVERLAY_ISO_W, btn_sz}
		restore_hover := rl.CheckCollisionPointRec(mouse, restore_rect)
		if restore_hover {
			rl.DrawRectangleRounded(restore_rect, 0.2, 4, rl.Color{60, 60, 75, 140})
		}
		lw := measure_text(state, "Restore", 13)
		draw_text(state, "Restore", cx + (OVERLAY_ISO_W - lw) / 2, cy + 6, 13, {100, 180, 255, 220})
		if restore_hover && rl.IsMouseButtonPressed(.LEFT) {
			isolate_restore(state)
		}
		cx += OVERLAY_ISO_W + btn_gap
	}

	// -- Full view --
	full_rect := rl.Rectangle{cx, cy, btn_sz, btn_sz}
	full_hover := rl.CheckCollisionPointRec(mouse, full_rect)
	if full_hover {
		rl.DrawRectangleRounded(full_rect, 0.2, 4, rl.Color{60, 60, 75, 140})
	}
	fc := full_hover ? rl.Color{200, 200, 240, 220} : rl.Color{180, 180, 220, 220}
	fx := cx + 6
	fy := cy + 6
	fs: f32 = btn_sz - 12
	rl.DrawLineEx({fx, fy}, {fx + 4, fy}, 2, fc)
	rl.DrawLineEx({fx, fy}, {fx, fy + 4}, 2, fc)
	rl.DrawLineEx({fx + fs, fy}, {fx + fs - 4, fy}, 2, fc)
	rl.DrawLineEx({fx + fs, fy}, {fx + fs, fy + 4}, 2, fc)
	rl.DrawLineEx({fx, fy + fs}, {fx + 4, fy + fs}, 2, fc)
	rl.DrawLineEx({fx, fy + fs}, {fx, fy + fs - 4}, 2, fc)
	rl.DrawLineEx({fx + fs, fy + fs}, {fx + fs - 4, fy + fs}, 2, fc)
	rl.DrawLineEx({fx + fs, fy + fs}, {fx + fs, fy + fs - 4}, 2, fc)
	if full_hover && rl.IsMouseButtonPressed(.LEFT) {
		zoom_out_full(state)
	}
}

update_waveform_input :: proc(state: ^App_State) {
	if !state.audio_loaded do return
	if state.library_open do return

	mouse := rl.GetMousePosition()
	rect := state.waveform_rect
	in_rect := rl.CheckCollisionPointRec(mouse, rect)

	// Check if mouse is over the zoom overlay bar — skip waveform clicks there
	overlay_bar := get_overlay_bar_rect(state)
	if rl.CheckCollisionPointRec(mouse, overlay_bar) && rl.IsMouseButtonPressed(.LEFT) {
		state.skip_waveform_click = true
	}

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

	if in_rect && rl.IsMouseButtonPressed(.LEFT) && !state.skip_waveform_click {
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

	// A press that started over the overlay bar must never begin a selection —
	// click_start_x would be stale from an earlier waveform click and spawn a
	// phantom selection.
	if in_rect && rl.IsMouseButtonDown(.LEFT) && !state.is_selecting && !state.skip_waveform_click {
		// Start selecting only after exceeding drag threshold
		if abs(mouse.x - state.click_start_x) >= DRAG_THRESHOLD {
			state.is_selecting = true
			state.has_selection = true
		}
	}

	if state.is_selecting && rl.IsMouseButtonDown(.LEFT) {
		drag_time := screen_x_to_time(state, mouse.x)
		drag_time = math.clamp(drag_time, 0, state.duration)
		if is_isolated(state) {
			// Selections made in an isolated view stay within the region
			top := state.isolation_stack[len(state.isolation_stack) - 1]
			drag_time = math.clamp(drag_time, top.selection_start, top.selection_end)
		}

		switch state.drag_handle {
		case .Left:
			state.selection_start = min(drag_time, state.selection_end - 0.01)
		case .Right:
			state.selection_end = max(drag_time, state.selection_start + 0.01)
		case .Body:
		case .None:
		}
	}

	// Release: commit the interaction only when it started on the waveform;
	// transient drag state unwinds either way so it can never stick.
	if rl.IsMouseButtonReleased(.LEFT) {
		if !state.skip_waveform_click {
			if state.is_selecting {
				if state.selection_start > state.selection_end {
					state.selection_start, state.selection_end = state.selection_end, state.selection_start
				}

				if state.selection_end - state.selection_start < MIN_SELECTION_DUR {
					state.has_selection = false
				} else {
					seek_to_time(state, state.selection_start)
					if !state.is_playing {
						toggle_playback(state)
					}
					state.loop_enabled = true
				}
			} else if in_rect {
				// Click without drag — seek to position
				click_time := screen_x_to_time(state, mouse.x)
				seek_to_time(state, click_time)
			}
		}
		state.is_selecting = false
		state.drag_handle = .None
		state.skip_waveform_click = false
	}

	// Click to seek (right-click)
	if in_rect && rl.IsMouseButtonPressed(.RIGHT) {
		rclick_time := screen_x_to_time(state, mouse.x)
		seek_to_time(state, rclick_time)
	}
}

screen_x_to_time :: proc(state: ^App_State, x: f32) -> f32 {
	return state.view_start + (x - state.waveform_rect.x) / state.waveform_rect.width * state.view_duration
}

time_to_screen_x :: proc(state: ^App_State, t: f32) -> f32 {
	return state.waveform_rect.x + (t - state.view_start) / state.view_duration * state.waveform_rect.width
}

clamp_view :: proc(state: ^App_State) {
	if is_isolated(state) {
		// Constrain view to current isolation level's bounds
		top := state.isolation_stack[len(state.isolation_stack) - 1]
		iso_start := top.selection_start
		iso_end := top.selection_end
		iso_dur := iso_end - iso_start
		if state.view_duration > iso_dur {
			state.view_duration = iso_dur
		}
		if state.view_start < iso_start {
			state.view_start = iso_start
		}
		if state.view_start + state.view_duration > iso_end {
			state.view_start = iso_end - state.view_duration
		}
	} else {
		if state.view_start < 0 do state.view_start = 0
		if state.view_start + state.view_duration > state.duration {
			state.view_start = max(state.duration - state.view_duration, 0)
		}
		if state.view_duration > state.duration {
			state.view_duration = state.duration
			state.view_start = 0
		}
	}
}

format_time_short :: proc(t: f32) -> cstring {
	minutes := i32(t) / 60
	seconds := i32(t) % 60
	return rl.TextFormat("%d:%02d", minutes, seconds)
}

draw_isolation_breadcrumb :: proc(state: ^App_State) {
	rect := state.waveform_rect
	x := rect.x + 8
	y := rect.y + 6
	n := len(state.isolation_stack)

	for i in 0 ..< n {
		level := state.isolation_stack[i]
		seg := rl.TextFormat("%s-%s", format_time_short(level.selection_start), format_time_short(level.selection_end))
		is_last := i == n - 1
		color: rl.Color = is_last ? {200, 220, 255, 255} : {140, 180, 220, 200}
		draw_text(state, seg, x, y, 13, color)
		x += measure_text(state, seg, 13)

		if !is_last {
			arrow: cstring = " > "
			draw_text(state, arrow, x, y, 13, rl.Color{100, 100, 130, 180})
			x += measure_text(state, arrow, 13)
		}
	}
}

is_isolated :: proc(state: ^App_State) -> bool {
	return len(state.isolation_stack) > 0
}

zoom_to_selection :: proc(state: ^App_State) {
	if !state.has_selection do return

	// Reject degenerate selections — isolating one would zoom into a sliver.
	// Clearing here also makes a phantom Isolate button heal itself.
	if state.selection_end - state.selection_start < MIN_SELECTION_DUR {
		state.has_selection = false
		return
	}

	// Push the parent state onto the stack — restoring unwinds to this snapshot
	append(&state.isolation_stack, Isolation_Level{
		view_start      = state.view_start,
		view_duration   = state.view_duration,
		selection_start = state.selection_start,
		selection_end   = state.selection_end,
		has_selection   = state.has_selection,
		loop_enabled    = state.loop_enabled,
	})

	// Entering isolation is a new state: the selection is absorbed into the
	// region itself (the whole region loops), so clear it.
	state.view_start = state.selection_start
	state.view_duration = state.selection_end - state.selection_start
	state.has_selection = false

	// Keep the playhead inside the new region — it must live within the
	// isolated state's bounds.
	if state.current_time < state.view_start || state.current_time > state.view_start + state.view_duration {
		seek_to_time(state, state.view_start)
	}

	clamp_view(state)
	state.cache_dirty = true
}

// Pop one isolation level
isolate_restore :: proc(state: ^App_State) {
	n := len(state.isolation_stack)
	if n == 0 do return

	prev := state.isolation_stack[n - 1]
	pop(&state.isolation_stack)

	state.view_start      = prev.view_start
	state.view_duration   = prev.view_duration
	state.selection_start = prev.selection_start
	state.selection_end   = prev.selection_end
	state.has_selection   = prev.has_selection
	state.loop_enabled    = prev.loop_enabled

	clamp_view(state)
	state.cache_dirty = true
}

// Pop all isolation levels — full view
zoom_out_full :: proc(state: ^App_State) {
	if len(state.isolation_stack) > 0 {
		first := state.isolation_stack[0]
		clear(&state.isolation_stack)

		state.view_start      = 0
		state.view_duration   = state.duration
		state.selection_start = first.selection_start
		state.selection_end   = first.selection_end
		state.has_selection   = first.has_selection
		state.loop_enabled    = first.loop_enabled
	} else {
		state.view_start = 0
		state.view_duration = state.duration
	}
	clamp_view(state)
	state.cache_dirty = true
}
