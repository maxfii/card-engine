// cards dev — barebones balatro-ish card playground
// odin + raylib + microui · single file · one draw+update megafunction
//
// controls
//   click                     select a card
//   click-drag                move a card (reorders within a zone, moves between zones)
//   F1                        toggle the developer hud
//   wheel over a slider       change its value (a notch is 1/20 of the slider's range)
//   delete                    delete the selected card (when no textbox is focused)
//
// layout
//   board : fixed grid of cells (columns x rows, both tunable) — drop a card on any cell;
//           landing on an occupied cell swaps the two cards
//   hand  : fanned row along the bottom — drops insert, and the rest shuffle along
//   cards are fatty structs: content, layout slot, motion state and interaction state all in one
//
// fonts
//   FONT_PATH points at the ttf used for all text (currently Fira Sans Regular; FONT_PX holds
//   the sizes).
//   each size is rasterised at exactly the pixel size it is drawn at, so glyphs are never
//   resampled: crisp at 11-19px with a normal font, and with a pixel font set FONT_PX to
//   integer multiples of its design grid (e.g. 8/16/24). without the file the raylib
//   default bitmap font is used.
//   to bake the font into the binary instead of loading it from disk, replace the body of
//   load_font_at() with:
//     FONT_TTF :: #load("assets/font.ttf")   // file scope constant
//     f := rl.LoadFontFromMemory(".ttf", raw_data(FONT_TTF), i32(len(FONT_TTF)), c.int(size), nil, 0)
//   raylib also accepts ".bdf" and ".fnt", but a ttf is a single file (an .fnt needs its
//   own png atlas, which LoadFontFromMemory cannot take).

package main

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"
import rl "vendor:raylib"
import mu "vendor:microui"

// ----------------------------------------------------------------------------
// constants
// ----------------------------------------------------------------------------

// fonts: one instance per size actually drawn, so glyphs are never resampled
FONT_PATH :: "assets/fonts/FiraSans-Regular.ttf" // any ttf/otf works; a missing file falls back to the bitmap font

Font_Kind :: enum { UI, LABEL, SMALL, TINY }

FONT_PX :: [Font_Kind]f32 {
	.UI    = 19, // hud text, card titles
	.LABEL = 15, // hints and zone labels
	.SMALL = 13, // card cover text
	.TINY  = 11, // card uid
}

FONT_SPACING_PX :: [Font_Kind]f32{.UI = 0.3, .LABEL = 0.3, .SMALL = 0.2, .TINY = 0.2}

CARD_W      :: 140.0
CARD_H      :: 196.0
PIVOT_ABOVE :: 0.55 * CARD_H               // dangle pivot height above the card's top edge
CENTER_BELOW :: PIVOT_ABOVE + CARD_H * 0.5 // card center is this far below the pivot
DRAG_SLOP   :: 6.0                         // px of mouse travel before a press becomes a drag
SLIDER_WHEEL_FRACTION :: 0.05              // one wheel notch = this share of a slider's range, but never less than one step
TILT_VSCALE :: 0.001                       // tilt_gain is expressed per 1000 px/s
MAX_CARDS   :: 64
TITLE_MAX   :: 40
COVER_MAX   :: 160

BG         :: rl.Color{22, 36, 40, 255}
GHOST_FILL :: rl.Color{255, 255, 255, 8}
GHOST_LINE :: rl.Color{255, 255, 255, 26}
HINT_TEXT  :: rl.Color{255, 255, 255, 70}
SEL_GOLD   :: rl.Color{232, 186, 98, 255}
CARD_BODY  :: rl.Color{243, 239, 229, 255}
CARD_INK   :: rl.Color{36, 38, 48, 255}
CARD_DIM   :: rl.Color{104, 106, 120, 255}
CARD_EDGE  :: rl.Color{18, 20, 28, 255}

COVER_DEFAULT :: "lorem ipsum dolor sit amet, consectetur adipiscing elit"

Zone :: enum { BOARD, HAND }

// ----------------------------------------------------------------------------
// types
// ----------------------------------------------------------------------------

// fatty card: everything about a card lives here
Card :: struct {
	uid: int,

	// content
	title:     [TITLE_MAX]u8,
	title_len: int,
	cover:     [COVER_MAX]u8,
	cover_len: int,
	image:     rl.Texture2D,

	// layout / motion (anchor is the dangle pivot, not the card center)
	zone:        Zone,
	cell:        int, // board cell index; meaningful when zone == .BOARD
	home:        rl.Vector2,
	rest_angle:  f32,
	anchor:      rl.Vector2,
	prev_anchor: rl.Vector2,
	angle:       f32,
	ang_vel:     f32,

	// interaction / animation
	hover_t:   f32,
	drag_t:    f32,
	sel_t:     f32,
	dragging:  bool,
	armed:     bool,
	grab:      rl.Vector2,
	press_pos: rl.Vector2,
}

Tuning :: struct {
	follow_speed: f32, // drag follow (exponential ease, per second)
	return_speed: f32, // settle-to-home speed
	dangle_k:     f32, // spring stiffness pulling angle towards its target
	dangle_damp:  f32, // angular damping (low = wobblier)
	tilt_gain:    f32, // tilt per 1000 px/s of horizontal velocity
	max_tilt:     f32,
	hover_lift:   f32,
	hover_scale:  f32,
	drag_lift:    f32,
	drag_scale:   f32,
	board_cols:   f32,
	board_rows:   f32,
	board_gap:    f32,
	hand_spacing: f32,
	hand_tilt:    f32,
}

DEFAULT_TUNING :: Tuning{
	follow_speed = 26,
	return_speed = 11,
	dangle_k     = 110,
	dangle_damp  = 6,
	tilt_gain    = 0.22,
	max_tilt     = 0.4,
	hover_lift   = 16,
	hover_scale  = 1.05,
	drag_lift    = 10,
	drag_scale   = 1.12,
	board_cols   = 5,
	board_rows   = 2,
	board_gap    = 16,
	hand_spacing = 118,
	hand_tilt    = 0.045,
}

Game :: struct {
	cards:    [dynamic]Card,
	selected: int, // uid, -1 = none
	next_uid:    int,
	fonts:       [Font_Kind]rl.Font,
	font_loaded: bool,
	show_ui:     bool,
	time:        f32,

	ui:     mu.Context, // ~270 KB, keep off the stack
	tuning: Tuning,

	drop_zone:  Zone,
	drop_index: int,
	drop_valid: bool,

	mod_shift: bool,
	mod_ctrl:  bool,
	mod_alt:   bool,

	// slider under the cursor (set while the hud is built, consumed by the next input pass)
	hot: Slider_Hover,
}

Slider_Hover :: struct {
	value:  ^f32,
	lo:     f32,
	hi:     f32,
	step:   f32,
	active: bool,
}

Slot_Ref :: struct { zone: Zone, index: int }

// board sort key: which card, ordered by title
Cell_Sort :: struct { card: int, title: string }

Key_Bind :: struct { ray: rl.KeyboardKey, mu: mu.Key }

KEY_MAP :: [?]Key_Bind{
	{.BACKSPACE, .BACKSPACE},
	{.DELETE, .DELETE},
	{.ENTER, .RETURN},
	{.KP_ENTER, .RETURN},
	{.LEFT, .LEFT},
	{.RIGHT, .RIGHT},
	{.HOME, .HOME},
	{.END, .END},
	{.A, .A},
	{.X, .X},
	{.C, .C},
	{.V, .V},
}

game: Game
rng_state: u64 = 0x2545F4914F6CDD1D

// ----------------------------------------------------------------------------
// small helpers
// ----------------------------------------------------------------------------

v2 :: proc(x, y: f32) -> rl.Vector2 { return {x, y} }

// raylib text functions take cstrings; odin strings are not null-terminated
cs :: proc(s: string) -> cstring { return fmt.ctprintf("%s", s) }

fade :: proc(c: rl.Color, a: f32) -> rl.Color {
	c := c
	c.a = u8(clamp(f32(c.a) * a, 0, 255))
	return c
}

approach :: proc(cur, target, speed, dt: f32) -> f32 {
	return cur + (target - cur) * (1 - math.exp(-speed * dt))
}

b2f :: proc(b: bool) -> f32 { return b ? 1 : 0 }

rng_next :: proc() -> u32 {
	x := rng_state
	x ~= x << 13
	x ~= x >> 7
	x ~= x << 17
	rng_state = x
	return u32(x >> 32)
}

set_text :: proc(buf: []u8, out_len: ^int, s: string) {
	out_len^ = copy(buf, s)
}

center_to_anchor :: proc(c: rl.Vector2) -> rl.Vector2 { return {c.x, c.y - CENTER_BELOW} }
anchor_to_center :: proc(anchor: rl.Vector2, angle: f32) -> rl.Vector2 {
	return anchor + rl.Vector2Rotate(v2(0, CENTER_BELOW), angle)
}

zone_name :: proc(z: Zone) -> string { return z == .HAND ? "hand" : "board" }

index_of_uid :: proc(g: ^Game, uid: int) -> int {
	if uid < 0 { return -1 }
	for i in 0 ..< len(g.cards) {
		if g.cards[i].uid == uid { return i }
	}
	return -1
}

zone_counts :: proc(g: ^Game) -> (board: int, hand: int) {
	for i in 0 ..< len(g.cards) {
		if g.cards[i].zone == .BOARD { board += 1 } else { hand += 1 }
	}
	return
}

// zone-relative position of a card (its index among the cards of its own zone)
zone_position :: proc(g: ^Game, uid: int) -> (zone: Zone, index: int) {
	board, hand := 0, 0
	for i in 0 ..< len(g.cards) {
		c := g.cards[i]
		if c.zone == .BOARD {
			if c.uid == uid { return .BOARD, board }
			board += 1
		} else {
			if c.uid == uid { return .HAND, hand }
			hand += 1
		}
	}
	return .HAND, 0
}

hand_slot_center :: proc(g: ^Game, i, n: int, sw, sh: f32) -> rl.Vector2 {
	spacing := min(g.tuning.hand_spacing, sw * 0.9 / f32(max(n, 1)))
	off := f32(i) - f32(max(n - 1, 0)) * 0.5
	return {sw * 0.5 + off * spacing, sh - 132 - 5 * off * off}
}

board_grid_cols :: proc(g: ^Game) -> int { return max(1, int(g.tuning.board_cols + 0.5)) }
board_grid_rows :: proc(g: ^Game) -> int { return max(1, int(g.tuning.board_rows + 0.5)) }
board_cells :: proc(g: ^Game) -> int { return board_grid_cols(g) * board_grid_rows(g) }

// board cell index -> center of that cell on screen
board_cell_center :: proc(g: ^Game, cell: int, sw: f32) -> rl.Vector2 {
	cols := board_grid_cols(g)
	gw := f32(cols) * CARD_W + f32(cols - 1) * g.tuning.board_gap
	x0 := sw * 0.5 - gw * 0.5 + CARD_W * 0.5
	y0: f32 = 96 + CARD_H * 0.5
	col := cell % cols
	row := cell / cols
	return {x0 + f32(col) * (CARD_W + g.tuning.board_gap), y0 + f32(row) * (CARD_H + g.tuning.board_gap)}
}

// index of the card sitting in `cell`, or -1
cell_occupant :: proc(g: ^Game, cell: int) -> int {
	for i in 0 ..< len(g.cards) {
		if g.cards[i].zone == .BOARD && g.cards[i].cell == cell { return i }
	}
	return -1
}

first_free_cell :: proc(g: ^Game) -> int {
	for cell in 0 ..< board_cells(g) {
		if cell_occupant(g, cell) < 0 { return cell }
	}
	return -1
}

slot_center_for :: proc(g: ^Game, zone: Zone, i: int, sw, sh: f32) -> rl.Vector2 {
	_, nh := zone_counts(g)
	switch zone {
	case .BOARD: return board_cell_center(g, i, sw)
	case .HAND:  return hand_slot_center(g, i, nh, sw, sh)
	}
	return {}
}

// nearest target across both zones: a board cell, or an insertion point in the hand
nearest_slot :: proc(g: ^Game, p: rl.Vector2, sw, sh: f32) -> Slot_Ref {
	_, nh := zone_counts(g)
	best := Slot_Ref{.HAND, nh}
	best_d := f32(1e9)
	for i in 0 ..= nh {
		d := rl.Vector2Distance(p, hand_slot_center(g, i, nh, sw, sh))
		if d < best_d { best_d = d; best = {.HAND, i} }
	}
	for cell in 0 ..< board_cells(g) {
		d := rl.Vector2Distance(p, board_cell_center(g, cell, sw))
		if d < best_d { best_d = d; best = {.BOARD, cell} }
	}
	return best
}

layout_cards :: proc(g: ^Game, sw, sh: f32) {
	_, nh := zone_counts(g)
	hi := 0
	for i in 0 ..< len(g.cards) {
		c := &g.cards[i]
		switch c.zone {
		case .BOARD:
			c.home = center_to_anchor(board_cell_center(g, c.cell, sw))
			c.rest_angle = 0
		case .HAND:
			off := f32(hi) - f32(max(nh - 1, 0)) * 0.5
			c.home = center_to_anchor(hand_slot_center(g, hi, nh, sw, sh))
			c.rest_angle = off * g.tuning.hand_tilt
			hi += 1
		}
	}
}

card_hit :: proc(c: ^Card, m: rl.Vector2, bottom_pad: f32) -> bool {
	d := rl.Vector2Rotate(m - c.anchor, -c.angle)
	return d.x >= -CARD_W * 0.5 && d.x <= CARD_W * 0.5 &&
	       d.y >= PIVOT_ABOVE - 2 && d.y <= PIVOT_ABOVE + CARD_H + bottom_pad
}

// ----------------------------------------------------------------------------
// deck editing
// ----------------------------------------------------------------------------

make_art :: proc(hue: f32) -> rl.Texture2D {
	top := rl.ColorFromHSV(hue, 0.30, 0.95)
	bot := rl.ColorFromHSV(f32(math.mod(f64(hue) + 46, 360)), 0.55, 0.68)
	img := rl.GenImageGradientLinear(64, 80, 0, top, bot)
	tex := rl.LoadTextureFromImage(img)
	rl.UnloadImage(img)
	rl.SetTextureFilter(tex, .POINT)
	return tex
}

add_card :: proc(g: ^Game, zone: Zone) {
	if len(g.cards) >= MAX_CARDS { return }
	c := Card {
		uid    = g.next_uid,
		zone   = zone,
		image  = make_art(f32(g.next_uid % 8) * 45 + 12),
	}
	g.next_uid += 1
	set_text(c.title[:], &c.title_len, fmt.tprintf("Card %d", c.uid))
	set_text(c.cover[:], &c.cover_len, COVER_DEFAULT)

	// spawn at its slot so the card eases in
	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())
	nb, nh := zone_counts(g)
	if zone == .BOARD {
		c.cell = first_free_cell(g)
		if c.cell < 0 { c.cell = nb } // grid full: overflow onto the next row
		c.anchor = center_to_anchor(board_cell_center(g, c.cell, sw))
	} else {
		c.anchor = center_to_anchor(hand_slot_center(g, nh, nh, sw, sh))
	}
	c.prev_anchor = c.anchor
	c.home = c.anchor
	c.angle = (f32(c.uid % 3) - 1) * 0.06
	c.rest_angle = c.angle

	append(&g.cards, c)
	g.selected = c.uid
}

duplicate_card :: proc(g: ^Game, uid: int) {
	src := index_of_uid(g, uid)
	if src < 0 || len(g.cards) >= MAX_CARDS { return }
	c := g.cards[src]
	c.uid = g.next_uid
	g.next_uid += 1
	c.image = make_art(f32(c.uid % 8) * 45 + 12) // fresh art so the copy is recognisable
	if c.zone == .BOARD {
		if cell := first_free_cell(g); cell >= 0 {
			c.cell = cell
		} else {
			c.zone = .HAND // no free cell: the copy goes to the hand instead
		}
	}
	c.hover_t = 0
	c.drag_t = 0
	c.sel_t = 0
	c.ang_vel = 0
	c.dragging = false
	c.armed = false

	append(&g.cards, c)
	for i := len(g.cards) - 1; i > src + 1; i -= 1 { g.cards[i] = g.cards[i - 1] }
	g.cards[src + 1] = c
	g.selected = c.uid
}

delete_card :: proc(g: ^Game, uid: int) {
	i := index_of_uid(g, uid)
	if i < 0 { return }
	rl.UnloadTexture(g.cards[i].image)
	ordered_remove(&g.cards, i)
	if g.selected == uid { g.selected = -1 }
}

// drop a card onto a board cell; a card already sitting there swaps places with it
place_on_cell :: proc(g: ^Game, uid: int, cell: int) {
	src := index_of_uid(g, uid)
	if src < 0 || cell < 0 { return }
	if g.cards[src].zone == .BOARD && g.cards[src].cell == cell { return }

	prev_zone := g.cards[src].zone
	prev_cell := g.cards[src].cell
	prev_hand := -1
	if prev_zone == .HAND {
		_, prev_hand = zone_position(g, uid)
	}

	if occ := cell_occupant(g, cell); occ >= 0 && occ != src {
		other := g.cards[occ].uid
		if prev_zone == .BOARD {
			g.cards[occ].cell = prev_cell // board to board: swap the two cells
		} else {
			move_card(g, other, .HAND, prev_hand) // displaced card takes the hand slot we came from
		}
	}

	if i := index_of_uid(g, uid); i >= 0 {
		g.cards[i].zone = .BOARD
		g.cards[i].cell = cell
	}
}

// move a card so it ends up at `zone_index` of the target zone, where
// zone_index is a slot index in the *current* arrangement (dragged card included).
// internally: remove the card, then insert it before the k-th card of that zone.
move_card :: proc(g: ^Game, uid: int, zone: Zone, zone_index: int) {
	cur := index_of_uid(g, uid)
	if cur < 0 { return }

	card := g.cards[cur]
	card.zone = zone

	others := 0
	for i in 0 ..< len(g.cards) {
		if i != cur && g.cards[i].zone == zone { others += 1 }
	}
	k := clamp(zone_index, 0, others)

	ordered_remove(&g.cards, cur)

	dest := len(g.cards)
	seen := 0
	for i in 0 ..< len(g.cards) {
		if g.cards[i].zone == zone {
			if seen == k { dest = i; break }
			seen += 1
		}
	}

	append(&g.cards, card)
	for i := len(g.cards) - 1; i > dest; i -= 1 { g.cards[i] = g.cards[i - 1] }
	g.cards[dest] = card
}

shuffle_zone :: proc(g: ^Game, zone: Zone) {
	idxs: [dynamic]int
	defer delete(idxs)
	for i in 0 ..< len(g.cards) {
		if g.cards[i].zone == zone { append(&idxs, i) }
	}

	if zone == .BOARD {
		// shuffle which cell each board card sits in (gaps stay gaps)
		cells: [dynamic]int
		defer delete(cells)
		for idx in idxs { append(&cells, g.cards[idx].cell) }
		for i := len(cells) - 1; i > 0; i -= 1 {
			j := int(rng_next() % u32(i + 1))
			cells[i], cells[j] = cells[j], cells[i]
		}
		for idx, k in idxs { g.cards[idx].cell = cells[k] }
		return
	}

	for i := len(idxs) - 1; i > 0; i -= 1 {
		j := int(rng_next() % u32(i + 1))
		g.cards[idxs[i]], g.cards[idxs[j]] = g.cards[idxs[j]], g.cards[idxs[i]]
	}
}

sort_zone :: proc(g: ^Game, zone: Zone) {
	idxs: [dynamic]int
	cards: [dynamic]Card
	defer delete(idxs)
	defer delete(cards)
	for i in 0 ..< len(g.cards) {
		if g.cards[i].zone == zone {
			append(&idxs, i)
			append(&cards, g.cards[i])
		}
	}
	if zone == .BOARD {
		// board order lives in the cells, so sort the cards and repack them into cells 0..n-1
		keys: [dynamic]Cell_Sort
		defer delete(keys)
		for idx in idxs {
			append(&keys, Cell_Sort{card = idx, title = string(g.cards[idx].title[:g.cards[idx].title_len])})
		}
		slice.sort_by(keys[:], proc(a, b: Cell_Sort) -> bool {
			return strings.compare(a.title, b.title) < 0
		})
		for key, k in keys { g.cards[key.card].cell = k }
		return
	}

	slice.sort_by(cards[:], proc(a, b: Card) -> bool {
		at := a.title
		bt := b.title
		return strings.compare(string(at[:a.title_len]), string(bt[:b.title_len])) < 0
	})
	for idx, k in idxs { g.cards[idx] = cards[k] }
}

seed_deck :: proc(g: ^Game) {
	for i in 0 ..< 8 { add_card(g, i < 5 ? .HAND : .BOARD) }
	g.selected = -1
}

reset_all :: proc(g: ^Game) {
	for i in 0 ..< len(g.cards) { rl.UnloadTexture(g.cards[i].image) }
	clear(&g.cards)
	g.selected = -1
	g.next_uid = 1
	g.tuning = DEFAULT_TUNING
	seed_deck(g)
}

// ----------------------------------------------------------------------------
// drawing helpers
// ----------------------------------------------------------------------------

draw_art :: proc(tex: rl.Texture2D, dst: rl.Rectangle) {
	tw := f32(tex.width)
	th := f32(tex.height)
	if tw <= 0 || th <= 0 { return }
	s := max(dst.width / tw, dst.height / th) // cover crop, centered
	src := rl.Rectangle{(tw - dst.width / s) * 0.5, (th - dst.height / s) * 0.5, dst.width / s, dst.height / s}
	rl.DrawTexturePro(tex, src, dst, {0, 0}, 0, rl.WHITE)
}

draw_wrapped :: proc(font: rl.Font, text: string, box: rl.Rectangle, size, spacing: f32, color: rl.Color, max_lines: int) {
	y := box.y
	i := 0
	line := 0
	for i < len(text) && line < max_lines {
		word := i
		best := i
		for {
			for word < len(text) && (text[word] == ' ' || text[word] == '\n') { word += 1 }
			if word >= len(text) { break }
			end := word
			for end < len(text) && text[end] != ' ' && text[end] != '\n' { end += 1 }
			if rl.MeasureTextEx(font, cs(text[i:end]), size, spacing).x > box.width && best > i { break }
			best = end
			word = end
		}
		if best <= i { break }
		line_str := strings.trim_right(text[i:best], " \n")
		if len(line_str) > 0 {
			rl.DrawTextEx(font, cs(line_str), {box.x, y}, size, spacing, color)
			y += size + 2
			line += 1
		}
		i = best
	}
}

draw_card :: proc(g: ^Game, c: ^Card) {
	scale := 1 + c.hover_t * (g.tuning.hover_scale - 1) + c.drag_t * (g.tuning.drag_scale - 1)
	cam := rl.Camera2D {
		offset   = c.anchor,
		target   = {0, 0},
		rotation = c.angle * rl.RAD2DEG,
		zoom     = scale,
	}
	lift := clamp(c.hover_t + c.drag_t, 0, 1)

	// everything below is drawn in card-local space, pivot at (0, 0)
	rl.BeginMode2D(cam)
	rec := rl.Rectangle{-CARD_W * 0.5, PIVOT_ABOVE, CARD_W, CARD_H}

	// shadow
	srec := rl.Rectangle{rec.x + 3 + 5 * lift, rec.y + 6 + 10 * lift, rec.width, rec.height}
	rl.DrawRectangleRounded(srec, 0.08, 10, rl.Color{0, 0, 0, u8(55 + 90 * lift)})

	// body
	rl.DrawRectangleRounded(rec, 0.08, 10, CARD_BODY)

	// embedded art
	draw_art(c.image, rl.Rectangle{rec.x + 9, rec.y + 40, rec.width - 18, 94})

	// title + id
	rl.DrawTextEx(g.fonts[.UI], cs(string(c.title[:c.title_len])), {rec.x + 10, rec.y + 10}, FONT_PX[.UI], FONT_SPACING_PX[.UI], CARD_INK)
	uid_txt := fmt.ctprintf("#%d", c.uid)
	uw := rl.MeasureTextEx(g.fonts[.TINY], uid_txt, FONT_PX[.TINY], FONT_SPACING_PX[.TINY]).x
	rl.DrawTextEx(g.fonts[.TINY], uid_txt, {rec.x + rec.width - 10 - uw, rec.y + 14}, FONT_PX[.TINY], FONT_SPACING_PX[.TINY], CARD_DIM)

	// cover text
	draw_wrapped(g.fonts[.SMALL], string(c.cover[:c.cover_len]), rl.Rectangle{rec.x + 10, rec.y + 144, rec.width - 20, 44}, FONT_PX[.SMALL], FONT_SPACING_PX[.SMALL], CARD_DIM, 3)

	// edge + selection outline
	rl.DrawRectangleRoundedLinesEx(rec, 0.08, 10, 2, CARD_EDGE)
	if c.sel_t > 0.01 {
		e := 2 + 4 * c.sel_t
		orec := rl.Rectangle{rec.x - e, rec.y - e, rec.width + 2 * e, rec.height + 2 * e}
		rl.DrawRectangleRoundedLinesEx(orec, 0.08, 10, 2 + 2 * c.sel_t, fade(SEL_GOLD, c.sel_t))
	}
	rl.EndMode2D()
}

draw_board_ghosts :: proc(g: ^Game, sw, _: f32) {
	for cell in 0 ..< board_cells(g) {
		if cell_occupant(g, cell) >= 0 { continue }
		center := board_cell_center(g, cell, sw)
		rec := rl.Rectangle{center.x - CARD_W * 0.5, center.y - CARD_H * 0.5, CARD_W, CARD_H}
		rl.DrawRectangleRounded(rec, 0.08, 8, GHOST_FILL)
		rl.DrawRectangleRoundedLinesEx(rec, 0.08, 8, 2, GHOST_LINE)
	}
}

draw_ui_icon :: proc(ic: ^mu.Command_Icon) {
	col := rl.Color{ic.color.r, ic.color.g, ic.color.b, ic.color.a}
	r := ic.rect
	x, y, w, h := f32(r.x), f32(r.y), f32(r.w), f32(r.h)
	switch ic.id {
	case .NONE:
	case .CLOSE:
		p := h * 0.25
		rl.DrawLineEx({x + p, y + p}, {x + w - p, y + h - p}, 2, col)
		rl.DrawLineEx({x + w - p, y + p}, {x + p, y + h - p}, 2, col)
	case .CHECK:
		rl.DrawLineEx({x + w * 0.22, y + h * 0.55}, {x + w * 0.42, y + h * 0.75}, 2, col)
		rl.DrawLineEx({x + w * 0.42, y + h * 0.75}, {x + w * 0.8, y + h * 0.28}, 2, col)
	case .COLLAPSED:
		rl.DrawTriangle({x + w * 0.35, y + h * 0.25}, {x + w * 0.35, y + h * 0.75}, {x + w * 0.7, y + h * 0.5}, col)
	case .EXPANDED:
		rl.DrawTriangle({x + w * 0.25, y + h * 0.38}, {x + w * 0.75, y + h * 0.38}, {x + w * 0.5, y + h * 0.72}, col)
	case .RESIZE:
		rl.DrawLineEx({x + w - 4, y + h - 10}, {x + w - 10, y + h - 4}, 2, col)
		rl.DrawLineEx({x + w - 4, y + h - 16}, {x + w - 16, y + h - 4}, 2, col)
	}
}

draw_ui_commands :: proc(g: ^Game) {
	cmd: ^mu.Command
	scissor := false
	for mu.next_command(&g.ui, &cmd) {
		#partial switch v in cmd.variant {
		case ^mu.Command_Clip:
			if scissor { rl.EndScissorMode() }
			rl.BeginScissorMode(v.rect.x, v.rect.y, v.rect.w, v.rect.h)
			scissor = true
		case ^mu.Command_Rect:
			rl.DrawRectangleRec(
				{f32(v.rect.x), f32(v.rect.y), f32(v.rect.w), f32(v.rect.h)},
				{v.color.r, v.color.g, v.color.b, v.color.a},
			)
		case ^mu.Command_Text:
			rl.DrawTextEx(
				g.fonts[.UI], cs(v.str),
				{f32(v.pos.x), f32(v.pos.y)},
				FONT_PX[.UI], FONT_SPACING_PX[.UI],
				{v.color.r, v.color.g, v.color.b, v.color.a},
			)
		case ^mu.Command_Icon:
			draw_ui_icon(v)
		}
	}
	if scissor { rl.EndScissorMode() }
}

// ----------------------------------------------------------------------------
// fonts
// ----------------------------------------------------------------------------

// rasterises the font at exactly `size` px; falls back to the raylib bitmap font
load_font_at :: proc(size: int) -> rl.Font {
	if rl.FileExists(FONT_PATH) {
		f := rl.LoadFontEx(FONT_PATH, i32(size), nil, 0)
		// a failed load hands back the default font (baseSize 10), which we do not want here
		if f.glyphCount > 0 && f.texture.id > 0 && f.baseSize == i32(size) {
			rl.SetTextureFilter(f.texture, .BILINEAR) // 1:1 sampling, but smooth while a card is scaled
			return f
		}
	}
	d := rl.GetFontDefault()
	rl.SetTextureFilter(d.texture, .POINT) // crisp 2x default bitmap font
	return d
}

load_fonts :: proc(g: ^Game) {
	// a constant array cannot be indexed with a variable, so this is spelled out
	g.fonts[.UI]    = load_font_at(int(FONT_PX[.UI]))
	g.fonts[.LABEL] = load_font_at(int(FONT_PX[.LABEL]))
	g.fonts[.SMALL] = load_font_at(int(FONT_PX[.SMALL]))
	g.fonts[.TINY]  = load_font_at(int(FONT_PX[.TINY]))
	// the default bitmap font has baseSize 10, so this only matches a real load
	g.font_loaded = g.fonts[.UI].baseSize == i32(FONT_PX[.UI])
}

unload_fonts :: proc(g: ^Game) {
	def := rl.GetFontDefault()
	for kind in Font_Kind {
		f := g.fonts[kind]
		if f.texture.id != 0 && f.texture.id != def.texture.id { rl.UnloadFont(f) }
	}
}

// ----------------------------------------------------------------------------
// microui glue
// ----------------------------------------------------------------------------

ui_text_width :: proc(font: mu.Font, str: string) -> i32 {
	return i32(rl.MeasureTextEx(game.fonts[.UI], cs(str), FONT_PX[.UI], FONT_SPACING_PX[.UI]).x + 0.5)
}

ui_text_height :: proc(font: mu.Font) -> i32 { return i32(FONT_PX[.UI] + 4) }

ui_set_clipboard :: proc(user: rawptr, text: string) -> bool {
	rl.SetClipboardText(strings.clone_to_cstring(text, context.temp_allocator))
	return true
}

ui_get_clipboard :: proc(user: rawptr) -> (text: string, ok: bool) {
	c := rl.GetClipboardText()
	if c == nil { return "", false }
	return string(c), true
}

set_modifier :: proc(ui: ^mu.Context, key: mu.Key, down: bool, state: ^bool) {
	if down == state^ { return }
	state^ = down
	if down { mu.input_key_down(ui, key) } else { mu.input_key_up(ui, key) }
}

slider_row :: proc(ui: ^mu.Context, label: string, value: ^f32, lo, hi, step: f32, fmt_string: string) {
	mu.layout_row(ui, {92, -1}, 24)
	mu.label(ui, label)
	id := mu.get_id(ui, uintptr(value))
	_ = mu.slider(ui, value, lo, hi, step, fmt_string)
	// remember it, so the wheel can nudge it on the next frame's input pass
	if ui.hover_id == id {
		game.hot = Slider_Hover{value = value, lo = lo, hi = hi, step = step, active = true}
	}
}

// one wheel notch moves a slider by this share of its range, never less than a whole step
slider_wheel_step :: proc(lo, hi, step: f32) -> f32 {
	return max((hi - lo) * SLIDER_WHEEL_FRACTION, step)
}

// nudge a slider by `notches` wheel clicks: range-scaled, snapped to the step grid, clamped
wheel_adjust :: proc(value, lo, hi, step: f32, notches: f32) -> f32 {
	v := value + notches * slider_wheel_step(lo, hi, step)
	if step > 0 {
		v = math.floor((v + step * 0.5) / step) * step
	}
	return clamp(v, lo, hi)
}

// ----------------------------------------------------------------------------
// the frame: single update + draw megafunction
// ----------------------------------------------------------------------------

frame :: proc(g: ^Game) {
	dt := rl.GetFrameTime()
	if dt <= 0 { dt = 1.0 / 60.0 }
	g.time += dt

	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())
	m := rl.GetMousePosition()
	ui := &g.ui

	// ---------------------------------------------------------------- input
	mu.input_mouse_move(ui, i32(m.x), i32(m.y))
	if rl.IsMouseButtonPressed(.LEFT) { mu.input_mouse_down(ui, i32(m.x), i32(m.y), .LEFT) }
	if rl.IsMouseButtonReleased(.LEFT) { mu.input_mouse_up(ui, i32(m.x), i32(m.y), .LEFT) }
	if wheel := rl.GetMouseWheelMove(); wheel != 0 {
		// the wheel belongs to the slider under the cursor; anywhere else it scrolls the panel
		if g.hot.active {
			g.hot.value^ = wheel_adjust(g.hot.value^, g.hot.lo, g.hot.hi, g.hot.step, f32(wheel))
		} else {
			mu.input_scroll(ui, 0, i32(-wheel * 30))
		}
	}
	g.hot.active = false // slider_row sets it again while the hud is built
	for ch := rl.GetCharPressed(); ch != 0; ch = rl.GetCharPressed() {
		mu.input_text(ui, fmt.tprintf("%c", ch))
	}
	set_modifier(ui, .SHIFT, rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT), &g.mod_shift)
	set_modifier(ui, .CTRL, rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL), &g.mod_ctrl)
	set_modifier(ui, .ALT, rl.IsKeyDown(.LEFT_ALT) || rl.IsKeyDown(.RIGHT_ALT), &g.mod_alt)
	for e in KEY_MAP {
		if rl.IsKeyPressed(e.ray) || rl.IsKeyPressedRepeat(e.ray) { mu.input_key_down(ui, e.mu) }
		if rl.IsKeyReleased(e.ray) { mu.input_key_up(ui, e.mu) }
	}
	if rl.IsKeyPressed(.F1) { g.show_ui = !g.show_ui }

	// ------------------------------------------------------------ dev hud
	mu.begin(ui)
	if g.show_ui {
		// inspector ------------------------------------------------
		if mu.window(ui, "Inspector", {16, 16, 352, 210}, {.NO_RESIZE}) {
			sel := index_of_uid(g, g.selected)
			if sel < 0 {
				mu.text(ui, "no card selected\nclick a card to inspect it\nF1 hides the hud")
			} else {
				uid := g.cards[sel].uid

				mu.layout_row(ui, {52, -1}, 26)
				mu.label(ui, "title")
				r1 := mu.layout_next(ui)
				_ = mu.textbox_raw(ui, g.cards[sel].title[:], &g.cards[sel].title_len, mu.get_id(ui, fmt.tprintf("title##%d", uid)), r1, {})
				g.cards[sel].title_len = clamp(g.cards[sel].title_len, 0, TITLE_MAX)

				mu.layout_row(ui, {52, -1}, 26)
				mu.label(ui, "cover")
				r2 := mu.layout_next(ui)
				_ = mu.textbox_raw(ui, g.cards[sel].cover[:], &g.cards[sel].cover_len, mu.get_id(ui, fmt.tprintf("cover##%d", uid)), r2, {})
				g.cards[sel].cover_len = clamp(g.cards[sel].cover_len, 0, COVER_MAX)

				zone_now := g.cards[sel].zone
				mu.layout_row(ui, {84, 84, 84, -1}, 28)
				if .SUBMIT in mu.button(ui, zone_now == .HAND ? "-> board" : "-> hand") {
					if zone_now == .HAND {
						if cell := first_free_cell(g); cell >= 0 { place_on_cell(g, uid, cell) }
					} else {
						move_card(g, uid, .HAND, 1 << 30)
					}
				}
				if .SUBMIT in mu.button(ui, "duplicate") { duplicate_card(g, uid) }
				if .SUBMIT in mu.button(ui, "delete") { delete_card(g, uid) }

				// re-look-up: the buttons above may have moved or removed the card
				if fi := index_of_uid(g, uid); fi >= 0 {
					mu.layout_row(ui, {-1}, 22)
					mu.text(ui, fmt.tprintf(
						"uid %d · %s · title %d/%d · cover %d/%d",
						uid, zone_name(g.cards[fi].zone),
						g.cards[fi].title_len, TITLE_MAX,
						g.cards[fi].cover_len, COVER_MAX,
					))
				}
			}
		}

		// layout ----------------------------------------------------
		if mu.window(ui, "Layout", {16, 240, 352, 270}, {.NO_RESIZE}) {
			mu.layout_row(ui, {84, 84, 84, -1}, 28)
			if .SUBMIT in mu.button(ui, "add card") { add_card(g, .HAND) }
			if .SUBMIT in mu.button(ui, "shuffle") { shuffle_zone(g, .HAND); shuffle_zone(g, .BOARD) }
			if .SUBMIT in mu.button(ui, "sort") { sort_zone(g, .HAND); sort_zone(g, .BOARD) }
			if .SUBMIT in mu.button(ui, "reset") { reset_all(g) }

			nb, nh := zone_counts(g)
			mu.layout_row(ui, {-1}, 22)
			mu.text(ui, fmt.tprintf("%d cards · hand %d · board %d/%d", len(g.cards), nh, nb, board_cells(g)))
			mu.layout_row(ui, {-1}, 22)
			mu.text(ui, g.font_loaded ? "font: " + FONT_PATH : "font: default bitmap font (missing " + FONT_PATH + ")")

			slider_row(ui, "columns", &g.tuning.board_cols, 2, 8, 1, "%.0f")
			slider_row(ui, "rows", &g.tuning.board_rows, 1, 4, 1, "%.0f")
			slider_row(ui, "grid gap", &g.tuning.board_gap, 0, 48, 1, "%.0f")
			slider_row(ui, "hand gap", &g.tuning.hand_spacing, 60, 200, 1, "%.0f")
			slider_row(ui, "hand tilt", &g.tuning.hand_tilt, 0, 0.12, 0.005, "%.3f")

			mu.layout_row(ui, {-1}, 22)
			mu.text(ui, "ctrl+c/v/x/a work inside textboxes")
		}

		// tuning ----------------------------------------------------
		if mu.window(ui, "Tuning", {i32(sw) - 324, 16, 308, 430}, {.NO_RESIZE}) {
			slider_row(ui, "follow", &g.tuning.follow_speed, 4, 60, 0.5, "%.1f")
			slider_row(ui, "settle", &g.tuning.return_speed, 2, 30, 0.5, "%.1f")
			slider_row(ui, "dangle k", &g.tuning.dangle_k, 10, 400, 1, "%.0f")
			slider_row(ui, "damp", &g.tuning.dangle_damp, 0.5, 16, 0.1, "%.1f")
			slider_row(ui, "tilt", &g.tuning.tilt_gain, 0, 0.8, 0.01, "%.2f")
			slider_row(ui, "max tilt", &g.tuning.max_tilt, 0.05, 0.9, 0.01, "%.2f")
			slider_row(ui, "hover lift", &g.tuning.hover_lift, 0, 40, 1, "%.0f")
			slider_row(ui, "hover scale", &g.tuning.hover_scale, 1, 1.3, 0.01, "%.2f")
			slider_row(ui, "drag lift", &g.tuning.drag_lift, 0, 60, 1, "%.0f")
			slider_row(ui, "drag scale", &g.tuning.drag_scale, 1, 1.4, 0.01, "%.2f")

			mu.layout_row(ui, {-1}, 28)
			if .SUBMIT in mu.button(ui, "reset tuning") { g.tuning = DEFAULT_TUNING }
		}
	}
	mu.end(ui)

	ui_blocked := g.show_ui && ui.next_hover_root != nil
	if rl.IsKeyPressed(.DELETE) && ui.focus_id == 0 { delete_card(g, g.selected) }

	// ------------------------------------------------------- interaction
	hover_idx := -1
	if !ui_blocked {
		for i := len(g.cards) - 1; i >= 0; i -= 1 {           // topmost first
			c := &g.cards[i]
			if c.dragging { continue }
			if card_hit(c, m, c.hover_t * g.tuning.hover_lift + 4) { hover_idx = i; break }
		}
	}

	if rl.IsMouseButtonPressed(.LEFT) && !ui_blocked {
		if hover_idx >= 0 {
			c := &g.cards[hover_idx]
			g.selected = c.uid
			c.armed = true
			c.press_pos = m
		} else {
			g.selected = -1
		}
	}

	if rl.IsMouseButtonDown(.LEFT) {
		for i in 0 ..< len(g.cards) {
			c := &g.cards[i]
			if c.armed && !c.dragging && rl.Vector2Distance(m, c.press_pos) > DRAG_SLOP {
				c.dragging = true
				c.grab = c.anchor - m
				g.selected = c.uid
			}
		}
	}

	// drag targeting: the hand reorders live (cards make room), board drops are only
	// previewed and get committed on release, so sweeping across the grid cannot shuffle it
	g.drop_valid = false
	if di := index_of_dragged(g); di >= 0 {
		c := &g.cards[di]
		center := anchor_to_center(c.anchor, c.angle)
		ref := nearest_slot(g, center, sw, sh)
		g.drop_zone = ref.zone
		g.drop_index = ref.index
		g.drop_valid = true

		if ref.zone == .HAND {
			_, nh := zone_counts(g)
			cur_zone, cur_idx := zone_position(g, c.uid)
			if cur_zone != .HAND {
				move_card(g, c.uid, .HAND, ref.index) // came off the board: just join the hand
			} else if ref.index != cur_idx {
				d_new := rl.Vector2Distance(center, hand_slot_center(g, ref.index, nh, sw, sh))
				d_cur := rl.Vector2Distance(center, hand_slot_center(g, cur_idx, nh, sw, sh))
				if d_new < d_cur - 6 { move_card(g, c.uid, .HAND, ref.index) }
			}
		}
	}

	if rl.IsMouseButtonReleased(.LEFT) {
		if di := index_of_dragged(g); di >= 0 && g.drop_valid && g.drop_zone == .BOARD {
			place_on_cell(g, g.cards[di].uid, g.drop_index)
		}
		for i in 0 ..< len(g.cards) {
			g.cards[i].armed = false
			g.cards[i].dragging = false
		}
		g.drop_valid = false
	}

	// ----------------------------------------------------------- physics
	layout_cards(g, sw, sh)
	for i in 0 ..< len(g.cards) {
		c := &g.cards[i]
		c.prev_anchor = c.anchor
		if c.dragging {
			target := m + c.grab - v2(0, g.tuning.drag_lift * c.drag_t)
			c.anchor += (target - c.anchor) * (1 - math.exp(-g.tuning.follow_speed * dt))
		} else {
			target := c.home - v2(0, g.tuning.hover_lift * c.hover_t)
			c.anchor += (target - c.anchor) * (1 - math.exp(-g.tuning.return_speed * dt))
		}

		// dangle: spring the angle towards rest + a tilt proportional to horizontal velocity
		vel := (c.anchor - c.prev_anchor) / dt
		tilt := c.rest_angle + clamp(vel.x * TILT_VSCALE * g.tuning.tilt_gain, -g.tuning.max_tilt, g.tuning.max_tilt)
		c.ang_vel += (tilt - c.angle) * g.tuning.dangle_k * dt
		c.ang_vel *= math.exp(-g.tuning.dangle_damp * dt)
		c.angle += c.ang_vel * dt

		c.hover_t = approach(c.hover_t, b2f(i == hover_idx && !c.dragging), 16, dt)
		c.drag_t = approach(c.drag_t, b2f(c.dragging), 24, dt)
		c.sel_t = approach(c.sel_t, b2f(c.uid == g.selected), 14, dt)
	}

	// -------------------------------------------------------------- draw
	rl.BeginDrawing()
	rl.ClearBackground(BG)

	draw_board_ghosts(g, sw, sh)
	rl.DrawTextEx(g.fonts[.LABEL], "board", {18, 18}, FONT_PX[.LABEL], FONT_SPACING_PX[.LABEL], HINT_TEXT)
	rl.DrawTextEx(g.fonts[.LABEL], "hand", {18, sh - 200}, FONT_PX[.LABEL], FONT_SPACING_PX[.LABEL], HINT_TEXT)

	// cards in array order, dragged card last (on top)
	di := index_of_dragged(g)
	for i in 0 ..< len(g.cards) {
		if i != di { draw_card(g, &g.cards[i]) }
	}
	if di >= 0 { draw_card(g, &g.cards[di]) }

	if g.drop_valid {
		center := slot_center_for(g, g.drop_zone, g.drop_index, sw, sh)
		rec := rl.Rectangle{center.x - CARD_W * 0.5 - 5, center.y - CARD_H * 0.5 - 5, CARD_W + 10, CARD_H + 10}
		rl.DrawRectangleRounded(rec, 0.08, 8, fade(SEL_GOLD, 0.10))
		rl.DrawRectangleRoundedLinesEx(rec, 0.08, 8, 2, fade(SEL_GOLD, 0.55))
	}

	if !g.show_ui {
		rl.DrawTextEx(g.fonts[.LABEL], "drag cards · click select · F1 editor hud", {18, sh - 34}, FONT_PX[.LABEL], FONT_SPACING_PX[.LABEL], HINT_TEXT)
	}

	rl.SetMouseCursor(di >= 0 || hover_idx >= 0 ? .POINTING_HAND : .DEFAULT)

	draw_ui_commands(g)
	rl.EndDrawing()
}

index_of_dragged :: proc(g: ^Game) -> int {
	for i in 0 ..< len(g.cards) {
		if g.cards[i].dragging { return i }
	}
	return -1
}

// ----------------------------------------------------------------------------

main :: proc() {
	rl.SetConfigFlags({.WINDOW_RESIZABLE, .VSYNC_HINT})
	rl.InitWindow(1280, 760, "cards dev — odin + raylib + microui")
	defer rl.CloseWindow()
	rl.SetTargetFPS(60)

	load_fonts(&game)
	defer unload_fonts(&game)

	ui := &game.ui
	mu.init(ui, ui_set_clipboard, ui_get_clipboard)
	ui.text_width = ui_text_width
	ui.text_height = ui_text_height
	ui.style.size = {92, 26}
	ui.style.padding = 6
	ui.style.spacing = 6
	ui.style.title_height = 30
	ui.style.colors[.WINDOW_BG] = {22, 34, 38, 240}
	ui.style.colors[.TITLE_BG] = {26, 48, 52, 255}
	ui.style.colors[.BORDER] = {12, 18, 20, 255}

	game.tuning = DEFAULT_TUNING
	game.show_ui = true
	game.selected = -1
	game.next_uid = 1
	seed_deck(&game)

	for !rl.WindowShouldClose() {
		frame(&game)
		free_all(context.temp_allocator)
	}
}
