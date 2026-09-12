package music_trainer

import rl "vendor:raylib"

FFT_SIZE :: 4096
HOP_SIZE :: 2048
MIN_FREQ :: 60.0
MAX_FREQ :: 4000.0
CONFIDENCE_THRESHOLD :: 0.3

// Selections shorter than this are treated as clicks, not selections
MIN_SELECTION_DUR :: 0.05

@(rodata)
note_names := [12]string{"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"}

@(rodata)
note_colors := [12]rl.Color{
	{231, 76, 60, 255},    // C  - red
	{192, 57, 43, 255},    // C# - dark red
	{230, 126, 34, 255},   // D  - orange
	{211, 84, 0, 255},     // D# - dark orange
	{241, 196, 15, 255},   // E  - yellow
	{46, 204, 113, 255},   // F  - green
	{39, 174, 96, 255},    // F# - dark green
	{52, 152, 219, 255},   // G  - blue
	{41, 128, 185, 255},   // G# - dark blue
	{155, 89, 182, 255},   // A  - purple
	{142, 68, 173, 255},   // A# - dark purple
	{236, 240, 241, 255},  // B  - light gray
}

Drag_Handle :: enum {
	None,
	Left,
	Right,
	Body,
}

Waveform_Column :: struct {
	min_val: f32,
	max_val: f32,
}

Detected_Note :: struct {
	time:       f32,
	frequency:  f32,
	note_name:  string,
	midi_num:   int,
	confidence: f32,
	octave:     int,
	note_index: int,
}

Isolation_Level :: struct {
	view_start:      f32,
	view_duration:   f32,
	selection_start: f32,
	selection_end:   f32,
	has_selection:   bool,
	loop_enabled:    bool,
}

App_State :: struct {
	// Audio
	music:           rl.Music,
	wave:            rl.Wave,
	samples:         [^]f32,
	sample_count:    int,
	sample_rate:     u32,
	channels:        u32,
	duration:        f32,
	audio_loaded:    bool,
	file_name:       string,

	// Playback
	is_playing:      bool,
	playback_speed:  f32,
	volume:          f32,
	loop_enabled:    bool,
	current_time:    f32,
	pitch_correct:   bool,

	// Pitch-corrected stretched stream
	stretched_music: rl.Music,
	stretched_speed: f32,
	has_stretched:   bool,

	// Selection
	selection_start: f32,
	selection_end:   f32,
	has_selection:   bool,
	is_selecting:    bool,
	drag_handle:     Drag_Handle,
	click_start_x:       f32,
	skip_waveform_click: bool,

	// Waveform display
	waveform_cache:  [dynamic]Waveform_Column,
	view_start:      f32,
	view_duration:   f32,
	waveform_rect:   rl.Rectangle,
	cache_dirty:     bool,
	isolation_stack: [dynamic]Isolation_Level,

	// Pitch / notes
	detected_notes:  [dynamic]Detected_Note,
	note_display_rect: rl.Rectangle,

	// Fonts
	font:            rl.Font,
	font_bold:       rl.Font,
	fonts_loaded:    bool,

	// Library
	library_open:    bool,
	library_files:   [dynamic]string,
	library_scroll:  f32,

	// Library preview
	preview_music:   rl.Music,
	preview_index:   int,
	preview_playing: bool,

	// Library rename
	rename_index:      int,
	rename_buffer:     [256]u8,
	rename_active:     bool,
	rename_ext:        [16]u8,
	rename_cursor:     int,
	rename_sel_start:  int,
	rename_sel_end:    int,
	rename_blink:      f32,
	rename_last_click: f64,

	// Library delete confirmation
	delete_index:    int,
	delete_confirm:  bool,

	// Detection filters
	confidence_threshold: f32,
	min_freq_filter:      f32,
	max_freq_filter:      f32,

	// Recording
	is_recording:    bool,
	record_file:     string,

	// URL input
	url_buffer:      [512]u8,
	url_len:         i32,
	url_edit_mode:   bool,
	is_downloading:  bool,
	download_status: cstring,
	status_owned:    cstring, // heap-backed copy of download_status, freed on replace
}

init_state :: proc() -> App_State {
	return App_State{
		playback_speed       = 1.0,
		volume               = 1.0,
		view_start           = 0,
		view_duration        = 1.0,
		cache_dirty          = true,
		download_status      = "Ready",
		confidence_threshold = 0.3,
		min_freq_filter      = 60.0,
		max_freq_filter      = 4000.0,
		preview_index        = -1,
		rename_index         = -1,
		delete_index         = -1,
	}
}
