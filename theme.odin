package music_trainer

import rl "vendor:raylib"

// -- Refined dark palette ----------------------------------------------------
// A cohesive set of base surfaces, accent chrome, and semantic transport
// colors. Note colors remain defined in types.odin; these are the "chrome".

BG_DEEP        :: rl.Color{20, 22, 30, 255}   // main canvas background
BG_PANEL       :: rl.Color{26, 29, 40, 255}   // raised panels (waveform, notes)
BG_BAR         :: rl.Color{22, 24, 33, 255}   // title / control / status bars
BG_BAR_LOWER   :: rl.Color{26, 28, 38, 255}   // slightly lighter for gradient ends
BG_CONTROL     :: rl.Color{36, 40, 54, 255}   // default control surface
BG_CONTROL_HI  :: rl.Color{48, 54, 72, 255}   // hover / focused surface
BG_CONTROL_PR  :: rl.Color{60, 68, 90, 255}   // pressed surface

BORDER         :: rl.Color{52, 58, 78, 255}
BORDER_FOCUS   :: ACCENT

TEXT_PRI       :: rl.Color{224, 228, 240, 255}
TEXT_SEC       :: rl.Color{170, 178, 200, 255}
TEXT_DIM       :: rl.Color{120, 128, 150, 255}

// Chrome accent — soft glowing turquoise, kept dim enough to be easy on the eyes.
ACCENT         :: rl.Color{86, 200, 196, 255}
ACCENT_BRIGHT  :: rl.Color{150, 228, 222, 255}
ACCENT_DIM     :: rl.Color{86, 200, 196, 120}
ACCENT_SOFT    :: rl.Color{86, 200, 196, 40}

// Semantic transport colors (kept consistent with the original icons)
PLAY_COLOR     :: rl.Color{80, 210, 130, 255}
PAUSE_COLOR    :: rl.Color{245, 205, 70, 255}
STOP_COLOR     :: rl.Color{225, 80, 90, 255}
RECORD_COLOR   :: rl.Color{235, 110, 140, 255}

SELECTION      :: rl.Color{100, 170, 240, 255}

// -- Color math helpers -------------------------------------------------------

lerp_color :: proc(a: rl.Color, b: rl.Color, t: f32) -> rl.Color {
	return rl.Color{
		u8(f32(a.r) + (f32(b.r) - f32(a.r)) * t),
		u8(f32(a.g) + (f32(b.g) - f32(a.g)) * t),
		u8(f32(a.b) + (f32(b.b) - f32(a.b)) * t),
		u8(f32(a.a) + (f32(b.a) - f32(a.a)) * t),
	}
}

fade :: proc(col: rl.Color, alpha: u8) -> rl.Color {
	return rl.Color{col.r, col.g, col.b, alpha}
}

// Vertical gradient fill — top color to bottom color.
draw_gradient_vertical :: proc(rect: rl.Rectangle, top: rl.Color, bottom: rl.Color) {
	steps := int(rect.height)
	if steps < 1 do steps = 1
	for i in 0 ..< steps {
		t := f32(i) / f32(steps)
		c := lerp_color(top, bottom, t)
		rl.DrawLine(
			i32(rect.x), i32(rect.y + f32(i)),
			i32(rect.x + rect.width), i32(rect.y + f32(i)),
			c,
		)
	}
}

// Subtle outer glow ring around a rounded rect. Draws a few expanding
// translucent outlines; cheap because it's only used on small controls.
draw_rounded_glow :: proc(rect: rl.Rectangle, radius: f32, color: rl.Color, layers: int, spread: f32) {
	for i in 1 ..= layers {
		t := f32(i) / f32(layers)
		expand := spread * f32(i)
		alpha := u8(f32(color.a) * (1.0 - t) * 0.5)
		rl.DrawRectangleRoundedLinesEx(
			{rect.x - expand, rect.y - expand, rect.width + expand * 2, rect.height + expand * 2},
			radius, 4, 1, fade(color, alpha),
		)
	}
}

// One-pixel top highlight line to fake a light source on raised surfaces.
draw_top_highlight :: proc(rect: rl.Rectangle, color: rl.Color) {
	rl.DrawLine(
		i32(rect.x) + 1, i32(rect.y),
		i32(rect.x + rect.width) - 1, i32(rect.y),
		color,
	)
}

// Horizontal helper since raylib has no DrawLineH.
draw_hline :: proc(x1, y, x2: f32, color: rl.Color) {
	rl.DrawLine(i32(x1), i32(y), i32(x2), i32(y), color)
}

// Soft horizontal glow band centered on y, spanning [x1, x2]. Quadratic alpha
// falloff from `peak_alpha` at the center to 0 at ±`half`. Transparent enough
// that content drawn underneath remains visible.
draw_hglow :: proc(x1, x2, y, half: f32, color: rl.Color, peak_alpha: u8) {
	hh := int(half)
	if hh < 1 do hh = 1
	for i in -hh ..= hh {
		t := abs(f32(i)) / f32(hh)
		a := u8(f32(peak_alpha) * (1.0 - t) * (1.0 - t))
		rl.DrawLine(i32(x1), i32(y + f32(i)), i32(x2), i32(y + f32(i)), fade(color, a))
	}
}

// Soft vertical glow band centered on x, spanning [y1, y2]. Same falloff as
// draw_hglow but oriented vertically — used for the playhead neon tube.
draw_vglow :: proc(x, y1, y2, half: f32, color: rl.Color, peak_alpha: u8) {
	hh := int(half)
	if hh < 1 do hh = 1
	for i in -hh ..= hh {
		t := abs(f32(i)) / f32(hh)
		a := u8(f32(peak_alpha) * (1.0 - t) * (1.0 - t))
		rl.DrawLine(i32(x + f32(i)), i32(y1), i32(x + f32(i)), i32(y2), fade(color, a))
	}
}