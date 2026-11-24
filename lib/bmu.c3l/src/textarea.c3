module bmu::ui;
import std::math, std::core::string;
import raylib6::rl;
import bmu::txt;

// Wrapped text and the multi-line editor (text_area). Widths come from a per-size glyph advance cache, so wrapping a
// long text costs one table lookup per byte instead of measuring prefixes (text_w would be quadratic).

<* One wrapped line: bytes [start, end) of the text. The break character after it (a space or '\n') is in no line. *>
struct Line
{
	usz start;
	usz end;
}

const int ADV_SLOTS = 6;
struct AdvCache
{
	float size;        // logical size asked for
	float px_at;       // ui::px when filled (zoom / output scale change => refill)
	float[256] adv;    // advance of codepoints < 256, logical px
}
AdvCache[ADV_SLOTS] adv_cache;    // tests fill it to wrap without a font
int adv_next @private;

fn void adv_reset() @private
{
	foreach (&c : adv_cache) c.size = 0;
}

fn float glyph_adv(rl::RLFont* f, float k, int cp) @private
{
	int idx = rl::get_glyph_index(*f, cp);
	rl::RLGlyphInfo* g = &f.glyphs[idx];
	if (g.advance_x > 0) return (float)g.advance_x * k;
	return (f.recs[idx].width + (float)g.offset_x[0]) * k;
}

fn AdvCache* adv_for(float size) @private
{
	foreach (&c : adv_cache) if (c.size == size && c.px_at == px) return c;
	AdvCache* c = &adv_cache[adv_next];
	adv_next = (adv_next + 1) % ADV_SLOTS;
	c.size = size;
	c.px_at = px;
	if (!has_font)
	{
		for (int cp = 0; cp < 256; cp++)
		{
			char[2] one = { (char)cp, 0 };
			c.adv[cp] = cp < 32 || cp > 126 ? 0 : (float)rl::measure_text((ZString)&one, (int)size);
		}
		return c;
	}
	rl::RLFont* f = sized_font(size);
	float k = text_size(size) / (float)f.base_size;
	for (int cp = 0; cp < 256; cp++) c.adv[cp] = cp < 32 ? 0 : glyph_adv(f, k, cp);
	return c;
}

<* Decode one UTF-8 codepoint at s[i]; *n = its byte length (invalid bytes count as one '?'). *>
fn int utf8_at(String s, usz i, usz* n)
{
	char c = s[i];
	if (c < 0x80) { *n = 1; return c; }
	usz len = c >= 0xF0 ? 4 : (c >= 0xE0 ? 3 : (c >= 0xC0 ? 2 : 1));
	if (len == 1 || i + len > s.len) { *n = 1; return '?'; }
	int cp = len == 2 ? c & 0x1F : (len == 3 ? c & 0x0F : c & 0x07);
	for (usz k = 1; k < len; k++)
	{
		if ((s[i + k] & 0xC0) != 0x80) { *n = 1; return '?'; }
		cp = (cp << 6) | (s[i + k] & 0x3F);
	}
	*n = len;
	return cp;
}

fn float cp_w(AdvCache* c, float size, int cp) @private
{
	if (cp < 256) return c.adv[cp];
	if (!has_font) return text_w("?", size);
	rl::RLFont* f = sized_font(size);
	return glyph_adv(f, text_size(size) / (float)f.base_size, cp);
}

<* Width of `s` at `size`; same result as text_w for text without '\n', without its per-call copy. *>
fn float span_w(String s, float size = 15)
{
	AdvCache* c = adv_for(size);
	float w = 0;
	usz i = 0;
	while (i < s.len)
	{
		usz n;
		int cp = utf8_at(s, i, &n);
		w += cp_w(c, size, cp);
		i += n;
	}
	return w;
}

<*
 Break `s` into lines at most `w` logical px wide at `size`: at '\n', after the last space that fits, and inside
 words longer than a line. Stores the first out.len lines in `out` and returns the total count (>= 1).
 Pass an empty `out` to only count (e.g. to measure a height).
*>
fn int wrap(String s, float w, float size, Line[] out)
{
	AdvCache* c = adv_for(size);
	int count;
	usz start = 0;
	while (true)
	{
		usz i = start;
		float x = 0;
		usz space = usz::max;
		usz end;
		usz next;
		bool last;
		while (true)
		{
			if (i >= s.len) { end = s.len; last = true; break; }
			char ch = s[i];
			if (ch == '\n') { end = i; next = i + 1; break; }
			usz n;
			int cp = utf8_at(s, i, &n);
			float a = cp_w(c, size, cp);
			if (ch == ' ') { space = i; }
			else if (x + a > w && i > start)
			{
				if (space != usz::max) { end = space; next = space + 1; } else { end = i; next = i; }
				break;
			}
			x += a;
			i += n;
		}
		if (count < out.len) out[count] = { start, end };
		count++;
		if (last) break;
		start = next;
	}
	return count;
}

<* Height of `s` wrapped to `w` (lines * line_h; line_h 0 = line_height(size)). *>
fn float wrap_height(String s, float w, float size = 15, float line_h = 0)
{
	if (line_h <= 0) line_h = line_height(size);
	return wrap(s, w, size, {}) * line_h;
}

fn float line_height(float size = 15) => math::round(size * 1.4f);

const int WRAP_LINES = 4096;
Line[WRAP_LINES] wrap_lines @private;

<*
 Draw `s` wrapped to width `w` from (x, y); returns the height used. Only lines inside the current clip
 (begin_clip) or the window are drawn, so long texts in a scroll area stay cheap. At most WRAP_LINES lines.
*>
fn float text_wrap(String s, float x, float y, float w, float size = 15, Color color = FG, float line_h = 0)
{
	if (line_h <= 0) line_h = line_height(size);
	int n = wrap(s, w, size, &wrap_lines);
	int shown = math::min(n, WRAP_LINES);
	float top = math::max(clip.y, 0.0f);
	float bottom = math::min(clip.y + clip.height, sh());
	for (int i = 0; i < shown; i++)
	{
		float ly = y + i * line_h;
		if (ly + line_h < top) continue;
		if (ly > bottom) break;
		Line l = wrap_lines[i];
		if (l.end > l.start) text(s[l.start:l.end - l.start], x, ly, size, color);
	}
	return n * line_h;
}

// Multi-line editor -----------------------------------------------------------------

const int AREA_UNDO = 16;
const usz AREA_UNDO_BYTES = 16384;
struct AreaSnap
{
	char[AREA_UNDO_BYTES] text;
	usz caret;
}
AreaSnap[AREA_UNDO] area_undo @private;
int area_undo_count @private;
AreaSnap[AREA_UNDO] area_redo @private;
int area_redo_count @private;
int area_owner @private = -1;      // id the undo history belongs to
float area_want_x @private = -1;   // remembered x for Up/Down

struct AreaScroll
{
	int id;
	float scroll;
	ulong used;
}
AreaScroll[16] area_scrolls @private;
ulong area_clock @private;

fn float* area_scroll(int id) @private
{
	int slot = 0;
	foreach (i, &a : area_scrolls)
	{
		if (a.used && a.id == id) { a.used = ++area_clock; return &a.scroll; }
		if (a.used < area_scrolls[slot].used) slot = (int)i;
	}
	area_scrolls[slot] = { id, 0, ++area_clock };
	return &area_scrolls[slot].scroll;
}

fn void area_push(AreaSnap[] stack, int* count, char[] buf) @private
{
	String s = txt::view(buf);
	if (s.len >= AREA_UNDO_BYTES) return;    // too long to snapshot: no undo step
	if (*count == AREA_UNDO)
	{
		for (int i = 1; i < AREA_UNDO; i++) stack[i - 1] = stack[i];
		(*count)--;
	}
	txt::set(&stack[*count].text, s);
	stack[*count].caret = caret;
	(*count)++;
}

fn void area_before_edit(char[] buf, int kind) @private
{
	bool coalesce = kind == 1 && last_edit_kind == 1 && now - last_edit_time < 1.0 && !has_sel();
	if (!coalesce) area_push(&area_undo, &area_undo_count, buf);
	area_redo_count = 0;
	last_edit_kind = kind;
	last_edit_time = now;
}

fn void area_restore(char[] buf, AreaSnap* s) @private
{
	txt::set(buf, txt::view(&s.text));
	caret = math::min(s.caret, (usz)txt::view(buf).len);
	anchor = caret;
	last_edit_kind = 0;
}

// Visual line holding byte position p: the last line starting at or before p.
fn int line_of(Line[] lines, int n, usz p) @private
{
	int lo = 0;
	int hi = n - 1;
	while (lo < hi)
	{
		int mid = (lo + hi + 1) / 2;
		if (lines[mid].start <= p) { lo = mid; } else { hi = mid - 1; }
	}
	return lo;
}

// Byte position in line l closest to pixel offset x.
fn usz pos_in_line(String s, Line l, float x, float size) @private
{
	AdvCache* c = adv_for(size);
	float cx = 0;
	usz i = l.start;
	while (i < l.end)
	{
		usz n;
		int cp = utf8_at(s, i, &n);
		float a = cp_w(c, size, cp);
		if (x < cx + a / 2) return i;
		cx += a;
		i += n;
	}
	return l.end;
}

<*
 Multi-line text editor with word wrap, vertical scrolling, selection, clipboard and undo. Returns true when the
 text changed. Enter inserts a line break; with `enter_submits`, Enter sets `submitted` and Shift+Enter breaks
 the line. Ctrl+Enter always sets `submitted` (when given). The scroll offset is kept per id.
 Limits: WRAP_LINES visual lines are shown; undo needs the text under AREA_UNDO_BYTES.
*>
fn bool text_area(int id, Rect r, char[] buf, String placeholder = "", bool* submitted = null, bool enter_submits = false, float size = 15)
{
	float pad = 10;
	float lh = line_height(size);
	Rect inner = { r.x + pad, r.y + 8, r.width - 2 * pad - 6, r.height - 16 };
	float* scroll = area_scroll(id);
	String s = txt::view(buf);
	int n = wrap(s, inner.width, size, &wrap_lines);
	int shown = math::min(n, WRAP_LINES);

	bool h = hover(r);
	if (h) cursor = IBEAM;
	bool was = focus == id;
	if (rl::is_mouse_button_pressed(rl::RLMouseButton.LEFT) && live())
	{
		if (h)
		{
			if (!was) { focus_on(id, buf); }
			rl::RLVector2 m = rl::get_mouse_position();
			int li = math::clamp((int)((m[1] - inner.y + *scroll) / lh), 0, shown - 1);
			usz pos = pos_in_line(s, wrap_lines[li], m[0] - inner.x, size);
			if (was && now - last_click_time < 0.4 && pos == last_click_pos) { click_count++; } else { click_count = 1; }
			last_click_time = now;
			last_click_pos = pos;
			caret = pos;
			if (click_count == 2) { select_word(buf, pos); }
			else if (click_count >= 3) { anchor = wrap_lines[li].start; caret = wrap_lines[li].end; }
			else if (!(was && shift_down())) { anchor = pos; }
			dragging = click_count == 1;
			caret_blink = now;
			area_want_x = -1;
			consumed = true;
		}
		else if (focus == id) { focus = -1; }
	}
	bool f = focus == id && layer == top;
	if (f && area_owner != id)
	{
		area_owner = id;
		area_undo_count = 0;
		area_redo_count = 0;
		area_want_x = -1;
	}
	bool follow = false;        // keep the caret in view after keyboard input
	if (f && dragging)
	{
		if (rl::is_mouse_button_down(rl::RLMouseButton.LEFT))
		{
			rl::RLVector2 m = rl::get_mouse_position();
			if (m[1] < inner.y) *scroll -= lh / 2;
			if (m[1] > inner.y + inner.height) *scroll += lh / 2;
			int li = math::clamp((int)((m[1] - inner.y + *scroll) / lh), 0, shown - 1);
			caret = pos_in_line(s, wrap_lines[li], m[0] - inner.x, size);
		}
		else { dragging = false; }
	}

	bool changed = false;
	if (f)
	{
		usz len = s.len;
		if (caret > len) caret = len;
		if (anchor > len) anchor = len;
		bool ctrl = ctrl_down();
		bool shift = shift_down();
		usz caret_before = caret;

		int ch = rl::get_char_pressed();
		while (ch > 0)
		{
			if (!ctrl)
			{
				area_before_edit(buf, 1);
				if (has_sel()) delete_sel(buf);
				changed |= insert_codepoint(buf, ch);
				anchor = caret;
			}
			ch = rl::get_char_pressed();
		}
		bool enter = rl::is_key_pressed(rl::RLKeyboardKey.ENTER) || rl::is_key_pressed(rl::RLKeyboardKey.KP_ENTER) ||
			rl::is_key_pressed_repeat(rl::RLKeyboardKey.ENTER);
		if (enter)
		{
			if (ctrl || (enter_submits && !shift)) { if (submitted && !rl::is_key_pressed_repeat(rl::RLKeyboardKey.ENTER)) *submitted = true; }
			else
			{
				area_before_edit(buf, 2);
				if (has_sel()) delete_sel(buf);
				changed |= insert_byte(buf, '\n');
				anchor = caret;
			}
		}
		if (repeat(rl::RLKeyboardKey.BACKSPACE) && (caret > 0 || has_sel()))
		{
			area_before_edit(buf, 2);
			if (!has_sel()) anchor = ctrl ? word_left(buf, caret) : prev_char(buf, caret);
			delete_sel(buf);
			changed = true;
		}
		if (repeat(rl::RLKeyboardKey.DELETE) && (buf[caret] != 0 || has_sel()))
		{
			area_before_edit(buf, 2);
			if (!has_sel()) anchor = ctrl ? word_right(buf, caret) : next_char(buf, caret);
			delete_sel(buf);
			changed = true;
		}
		if (changed)
		{
			// re-wrap: movement below works on the edited text
			s = txt::view(buf);
			n = wrap(s, inner.width, size, &wrap_lines);
			shown = math::min(n, WRAP_LINES);
		}

		bool moved = false;
		bool vertical = false;
		usz target = caret;
		int li = line_of(&wrap_lines, shown, caret);
		if (repeat(rl::RLKeyboardKey.LEFT))
		{
			if (has_sel() && !shift) { target = sel_lo(); } else { target = ctrl ? word_left(buf, caret) : prev_char(buf, caret); }
			moved = true;
		}
		if (repeat(rl::RLKeyboardKey.RIGHT))
		{
			if (has_sel() && !shift) { target = sel_hi(); } else { target = ctrl ? word_right(buf, caret) : next_char(buf, caret); }
			moved = true;
		}
		int dl = 0;
		if (repeat(rl::RLKeyboardKey.UP)) dl = -1;
		if (repeat(rl::RLKeyboardKey.DOWN)) dl = 1;
		int page = math::max(1, (int)(inner.height / lh) - 1);
		if (repeat(rl::RLKeyboardKey.PAGE_UP)) dl = -page;
		if (repeat(rl::RLKeyboardKey.PAGE_DOWN)) dl = page;
		if (dl != 0)
		{
			Line cur = wrap_lines[li];
			if (area_want_x < 0) area_want_x = span_w(s[cur.start:caret - cur.start], size);
			int to = li + dl;
			if (to < 0) { target = 0; }
			else if (to >= shown) { target = s.len; }
			else { target = pos_in_line(s, wrap_lines[to], area_want_x, size); }
			moved = true;
			vertical = true;
		}
		if (rl::is_key_pressed(rl::RLKeyboardKey.HOME)) { target = ctrl ? 0 : wrap_lines[li].start; moved = true; }
		if (rl::is_key_pressed(rl::RLKeyboardKey.END)) { target = ctrl ? s.len : wrap_lines[li].end; moved = true; }
		if (moved)
		{
			caret = target;
			if (!shift) anchor = caret;
			caret_blink = now;
			last_edit_kind = 0;
			if (!vertical) area_want_x = -1;
		}

		if (ctrl)
		{
			if (letter('a')) { anchor = 0; caret = s.len; }
			if (letter('c')) copy_sel(buf);
			if (letter('x') && has_sel())
			{
				area_before_edit(buf, 2);
				copy_sel(buf);
				delete_sel(buf);
				changed = true;
			}
			if (letter('v') || (shift && rl::is_key_pressed(rl::RLKeyboardKey.INSERT)))
			{
				ZString clip_text = rl::get_clipboard_text();
				if (clip_text && clip_text[0])
				{
					area_before_edit(buf, 2);
					if (has_sel()) delete_sel(buf);
					foreach (c : clip_text.str_view())
					{
						if (c == '\r') continue;
						insert_byte(buf, c == '\t' ? ' ' : c);
					}
					anchor = caret;
					changed = true;
				}
			}
			bool redo = letter('y') || (shift && letter('z'));
			if (letter('z') && !shift && area_undo_count > 0)
			{
				area_push(&area_redo, &area_redo_count, buf);
				area_restore(buf, &area_undo[--area_undo_count]);
				changed = true;
			}
			else if (redo && area_redo_count > 0)
			{
				area_push(&area_undo, &area_undo_count, buf);
				area_restore(buf, &area_redo[--area_redo_count]);
				changed = true;
			}
		}
		if (rl::is_key_pressed(rl::RLKeyboardKey.ESCAPE))
		{
			if (has_sel()) { anchor = caret; } else { focus = -1; }
		}
		if (changed)
		{
			s = txt::view(buf);
			n = wrap(s, inner.width, size, &wrap_lines);
			shown = math::min(n, WRAP_LINES);
			area_want_x = -1;
		}
		follow = changed || moved || caret != caret_before;
	}

	// scrolling: wheel anywhere over the field, caret kept in view after keyboard input
	float content = shown * lh;
	if (live() && point_in(rl::get_mouse_position(), r)) *scroll -= rl::get_mouse_wheel_move() * 3 * lh;
	if (f && follow)
	{
		float cy = line_of(&wrap_lines, shown, caret) * lh;
		if (cy < *scroll) *scroll = cy;
		if (cy + lh > *scroll + inner.height) *scroll = cy + lh - inner.height;
	}
	*scroll = math::clamp(*scroll, 0.0f, math::max(0.0f, content - inner.height));

	panel(r, BG_HARD, 5);
	outline(r, f ? DIM_YELLOW : (h ? BG2 : BG1), 5, 1);
	Rect saved = clip;
	scissor((int)inner.x - 2, (int)inner.y, (int)inner.width + 4, (int)inner.height);
	float ty = inner.y - *scroll;
	if (s.len == 0 && !f)
	{
		text(placeholder, inner.x, inner.y, size, BG4);
	}
	else
	{
		int first = math::max(0, (int)(*scroll / lh));
		int last = math::min(shown - 1, (int)((*scroll + inner.height) / lh) + 1);
		usz lo = sel_lo();
		usz hi = sel_hi();
		bool sel = f && has_sel();
		for (int i = first; i <= last; i++)
		{
			Line l = wrap_lines[i];
			float ly = ty + i * lh;
			if (sel && hi > l.start && lo <= l.end)
			{
				usz a = math::max(lo, l.start);
				usz b = math::min(hi, l.end);
				float x0 = span_w(s[l.start:a - l.start], size);
				float x1 = span_w(s[l.start:b - l.start], size);
				if (hi > l.end) x1 += 5;     // the break after this line is selected too
				rl::draw_rectangle_rec({ inner.x + x0, ly, x1 - x0, lh }, { 215, 153, 33, 110 });
			}
			if (l.end > l.start) text(s[l.start:l.end - l.start], inner.x, ly + (lh - size) / 2 - 1, size, FG);
		}
		if (f && (now - caret_blink) - math::floor(now - caret_blink) < 0.6)
		{
			int cl = line_of(&wrap_lines, shown, caret);
			Line l = wrap_lines[cl];
			float cx = span_w(s[l.start:math::min(caret, l.end) - l.start], size);
			rl::draw_rectangle_rec({ inner.x + cx, ty + cl * lh + 2, 2, lh - 4 }, YELLOW);
		}
	}
	rl::end_scissor_mode();
	if (saved.width < 1e6) scissor((int)saved.x, (int)saved.y, (int)saved.width, (int)saved.height);
	scrollbar({ r.x, inner.y, r.width - 2, inner.height }, *scroll, content);
	return changed;
}
