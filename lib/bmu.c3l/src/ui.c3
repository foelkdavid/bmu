module bmu::ui;
import std::math, std::core::string;
import raylib6::rl;
import bmu::txt;

// bmu::ui - small immediate-mode widget kit for raylib. Gruvbox dark palette,
// embedded Nerd Font (CodeNewRoman Nerd Font Propo, OFL - see ../assets/README.txt).
// Everything is drawn in LOGICAL pixels; `px` (= `scale` x `dpi`) maps them to physical pixels.
// Docs: docs/API.md (every function), docs/CONCEPTS.md (layers, ids, buffers).

alias Color = rl::RLColor;

const Color BG_HARD = { 29, 32, 33, 255 };    // bg0_h #1d2021
const Color BG      = { 40, 40, 40, 255 };    // bg0   #282828
const Color BG1     = { 60, 56, 54, 255 };    // bg1   #3c3836
const Color BG2     = { 80, 73, 69, 255 };    // bg2   #504945
const Color BG3     = { 102, 92, 84, 255 };   // bg3   #665c54
const Color BG4     = { 124, 111, 100, 255 }; // bg4   #7c6f64
const Color FG      = { 235, 219, 178, 255 }; // fg    #ebdbb2
const Color FG4     = { 168, 153, 132, 255 }; // fg4   #a89984
const Color GRAY    = { 146, 131, 116, 255 }; // gray  #928374
const Color RED     = { 251, 73, 52, 255 };   // #fb4934
const Color GREEN   = { 184, 187, 38, 255 };  // #b8bb26
const Color YELLOW  = { 250, 189, 47, 255 };  // #fabd2f
const Color BLUE    = { 131, 165, 152, 255 }; // #83a598
const Color PURPLE  = { 211, 134, 155, 255 }; // #d3869b
const Color AQUA    = { 142, 192, 124, 255 }; // #8ec07c
const Color ORANGE  = { 254, 128, 25, 255 };  // #fe8019
const Color DIM_RED    = { 204, 36, 29, 255 };  // #cc241d
const Color DIM_GREEN  = { 152, 151, 26, 255 }; // #98971a
const Color DIM_YELLOW = { 215, 153, 33, 255 }; // #d79921

// Nerd Font glyphs (Font Awesome range)
const String I_PLAY   = "";
const String I_STOP   = "";
const String I_PLUS   = "";
const String I_FOLDER = "";
const String I_FOLDER_OPEN = "";
const String I_FILE   = "";
const String I_GEAR   = "";
const String I_SEARCH = "";
const String I_TRASH  = "";
const String I_UP     = "";
const String I_HOME   = "";
const String I_HDD    = "";
const String I_GAMEPAD = "";
const String I_WINDOWS = "";
const String I_CLOCK  = "";
const String I_CHECK  = "";
const String I_TIMES  = "";
const String I_DOWN   = "";
const String I_RIGHT  = "";
const String I_REFRESH = "";
const String I_TERMINAL = "";
const String I_IMAGE  = "";
const String I_WRENCH = "";
const String I_STEAM  = "";
const String I_BOLT   = "";
const String I_WARN   = "";
const String I_INFO   = "";
const String I_LIST   = "";
const String I_EYE    = "";
const String I_STAR   = "";

const String I_COPY   = "\uF0C5";
const String I_CUT    = "\uF0C4";
const String I_PASTE  = "\uF0EA";
const String I_EDIT   = "\uF040";
const String I_BACK   = "\uF060";
const String I_FORWARD = "\uF061";
const String I_LEFT   = "\uF053";
const String I_GRID   = "\uF00A";
const String I_MENU   = "\uF0C9";
const String I_BOOKMARK = "\uF02E";
const String I_LINK   = "\uF0C1";
const String I_LOCK   = "\uF023";
const String I_EXTERNAL = "\uF08E";
const String I_UNDO   = "\uF0E2";
const String I_EYE_OFF = "\uF070";
const String I_SORT_UP = "\uF0DE";
const String I_SORT_DOWN = "\uF0DD";
const String I_DESKTOP = "\uF108";
const String I_DOWNLOAD = "\uF019";
const String I_MUSIC  = "\uF001";
const String I_VIDEO  = "\uF008";
const String I_FILE_TEXT = "\uF0F6";
const String I_FILE_IMAGE = "\uF1C5";
const String I_FILE_AUDIO = "\uF1C7";
const String I_FILE_VIDEO = "\uF1C8";
const String I_FILE_ARCHIVE = "\uF1C6";
const String I_FILE_CODE = "\uF1C9";
const String I_FILE_PDF = "\uF1C1";
const String I_MIC    = "\uF130";
const String I_VOLUME = "\uF028";
const String I_MUTE   = "\uF026";
const String I_RECORD = "\uF111";
const String I_PAUSE  = "\uF04C";
const String I_REPEAT = "\uF01E";
const String I_SLIDERS = "\uF1DE";
const String I_HEADPHONES = "\uF025";
const String I_USER   = "\uF007";
const String I_USERS  = "\uF0C0";
const String I_CHAT   = "\uF086";
const String I_GLOBE  = "\uF0AC";
const String I_SEND   = "\uF1D8";
const String I_BOOK   = "\uF02D";

const int[*] ICON_CODEPOINTS = {
	0xF04B, 0xF04D, 0xF067, 0xF07B, 0xF07C, 0xF15B, 0xF013, 0xF002, 0xF1F8, 0xF062,
	0xF015, 0xF0A0, 0xF11B, 0xF17A, 0xF017, 0xF00C, 0xF00D, 0xF078, 0xF054, 0xF021,
	0xF120, 0xF03E, 0xF0AD, 0xF1B6, 0xF0E7, 0xF071, 0xF05A, 0xF03A, 0xF06E, 0xF005,
	0xF0C5, 0xF0C4, 0xF0EA, 0xF040, 0xF060, 0xF061, 0xF053, 0xF00A, 0xF0C9, 0xF02E,
	0xF0C1, 0xF023, 0xF08E, 0xF0E2, 0xF070, 0xF0DE, 0xF0DD, 0xF108, 0xF019, 0xF001,
	0xF008, 0xF0F6, 0xF1C5, 0xF1C7, 0xF1C8, 0xF1C6, 0xF1C9, 0xF1C1,
	0xF130, 0xF028, 0xF026, 0xF111, 0xF04C, 0xF01E, 0xF1DE, 0xF025,
	0xF007, 0xF0C0, 0xF086, 0xF0AC, 0xF1D8, 0xF02D,
	0x2022, 0x2014, 0x2026, 0x00B7, 0x2013, 0x2018, 0x2019, 0x201C, 0x201D,
};

const char[*] FONT_DATA = $embed("../assets/ui.otf");
rl::RLFont font;
bool has_font;

// Lazy, bounded native-pixel atlases. Lookup is O(1); only a cache miss rasterizes.
const int FONT_CACHE_SIZE = 32;
const int FONT_MAX_PIXELS = 192;
struct FontSize
{
	rl::RLFont face;
	ulong used;
}
FontSize[FONT_CACHE_SIZE] font_sizes;
int[FONT_MAX_PIXELS + 1] font_slots; // slot + 1; zero = not cached
int[1024] font_codepoints;
int font_codepoint_count;
ulong font_clock;

// Flush queued glyphs before deleting an atlas during LRU eviction.
extern fn void flush_font_batch() @cname("rlDrawRenderBatchActive");

fn int font_pixels(float size) => (int)math::clamp(math::round(size * px), 1.0f, (float)FONT_MAX_PIXELS);
fn float text_pixel(float position) => math::round(position * px) / px;
fn float text_size(float size) => size * px > (float)FONT_MAX_PIXELS ? size : (float)font_pixels(size) / px;

fn rl::RLFont bake_font(int pixels)
{
	rl::RLFont face = rl::load_font_from_memory(".otf", &FONT_DATA[0], (int)FONT_DATA.len,
		pixels, &font_codepoints, font_codepoint_count);
	// raylib can return its shared default font on failure; never cache/unload it.
	if (!face.texture.id || face.glyph_count != font_codepoint_count) return {};
	// No mipmaps: at native size each atlas texel maps to one physical pixel.
	face.texture.set_filter(rl::RLTextureFilter.BILINEAR);
	return face;
}

fn rl::RLFont* sized_font(float size)
{
	int pixels = font_pixels(size);
	if (pixels == font.base_size) return &font;
	int slot = font_slots[pixels] - 1;
	if (slot < 0)
	{
		slot = 0;
		for (int i = 0; i < FONT_CACHE_SIZE; i++)
		{
			if (!font_sizes[i].face.texture.id) { slot = i; break; }
			if (font_sizes[i].used < font_sizes[slot].used) slot = i;
		}
		FontSize* cached = &font_sizes[slot];
		if (cached.face.texture.id)
		{
			flush_font_batch();
			font_slots[cached.face.base_size] = 0;
			rl::unload_font(cached.face);
		}
		cached.face = bake_font(pixels);
		if (!cached.face.texture.id || cached.face.glyph_count <= 0)
		{
			cached.face = {};
			return &font;
		}
		font_slots[pixels] = slot + 1;
	}
	font_sizes[slot].used = ++font_clock;
	return &font_sizes[slot].face;
}

<*
 Load the embedded UI font (needs an open window). Only the glyphs baked here can
 be drawn: ASCII, Latin-1, the I_* icons and `extra` (any other codepoints, e.g.
 more Nerd Font icons). Without a font, text falls back to raylib's default font.
*>
fn void load_font(int[] extra = {})
{
	unload_font();
	font_codepoint_count = 0;
	for (int c = 32; c < 127; c++) font_codepoints[font_codepoint_count++] = c;
	for (int c = 160; c < 256; c++) font_codepoints[font_codepoint_count++] = c;
	foreach (c : ICON_CODEPOINTS) font_codepoints[font_codepoint_count++] = c;
	foreach (c : extra) if (font_codepoint_count < font_codepoints.len) font_codepoints[font_codepoint_count++] = c;
	font = bake_font(font_pixels(15));
	has_font = font.texture.id && font.glyph_count > 0;
}

fn void unload_font()
{
	if (has_font)
	{
		flush_font_batch();
		rl::unload_font(font);
	}
	foreach (&cached : font_sizes)
	{
		if (cached.face.texture.id) rl::unload_font(cached.face);
		*cached = {};
	}
	font = {};
	font_slots = {};
	adv_reset();
	font_clock = 0;
	has_font = false;
}

// Text -----------------------------------------------------------------------

fn void text(String s, float x, float y, float size = 15, Color color = FG) => @pool()
{
	ZString zs = s.zstr_tcopy();
	if (has_font)
	{
		rl::draw_text_ex(*sized_font(size), zs, { text_pixel(x), text_pixel(y) }, text_size(size), 0, color);
		return;
	}
	rl::draw_text(zs, (int)x, (int)y, (int)size, color);
}

fn float text_w(String s, float size = 15) => @pool()
{
	ZString zs = s.zstr_tcopy();
	if (has_font) return rl::measure_text_ex(*sized_font(size), zs, text_size(size), 0)[0];
	return (float)rl::measure_text(zs, (int)size);
}

// Draw text clipped to a width with a trailing ellipsis.
fn void text_fit(String s, float x, float y, float w, float size = 15, Color color = FG) => @pool()
{
	if (text_w(s, size) <= w) { text(s, x, y, size, color); return; }
	usz n = s.len;
	while (n > 0 && text_w(string::tformat("%s…", s[:n]), size) > w)
	{
		n--;
		while (n > 0 && (s[n] & 0xC0) == 0x80) n--; // keep UTF-8 intact
	}
	text(string::tformat("%s…", s[:n]), x, y, size, color);
}

// Draw only the tail of a long string (paths), prefixed with an ellipsis.
fn void text_tail(String s, float x, float y, float w, float size = 15, Color color = FG) => @pool()
{
	if (text_w(s, size) <= w) { text(s, x, y, size, color); return; }
	usz start = 0;
	while (start < s.len && text_w(string::tformat("…%s", s[start..]), size) > w) start++;
	while (start < s.len && (s[start] & 0xC0) == 0x80) start++;
	text(string::tformat("…%s", s[start..]), x, y, size, color);
}

// Input state -----------------------------------------------------------------

int layer;          // layer currently being drawn
int top;            // only widgets on this layer react to input
bool popup_open;    // dropdown popup owns input when open
const int POPUP_LAYER = 99;
Rect clip = { -1e6, -1e6, 2e6, 2e6 };
rl::RLMouseCursor cursor;
bool consumed;      // a click was handled this frame
double now;

float scale = 1;     // UI zoom: logical px -> window (compositor) px; the user's setting, persisted by apps
float dpi = 1;       // compositor scale of the window's output (Wayland fractional scale, e.g. 1.5): window px -> physical px
float px = 1;        // scale * dpi: logical px -> physical (framebuffer) px; use it to size textures/fonts/1:1 images
bool dpi_changed;    // set for one frame by begin_frame() when `dpi` changed (window moved to another output)

fn float sw() => (float)rl::get_screen_width() / scale;
fn float sh() => (float)rl::get_screen_height() / scale;

fn void scissor(int x, int y, int w, int h)
{
	// rlgl directly, in physical px: raylib's begin_scissor_mode takes window px and truncates after its DPI multiply
	flush_font_batch();
	rl::gl_enable_scissor_test();
	int x0 = (int)((float)x * px);
	int y0 = (int)((float)y * px);
	int x1 = (int)((float)(x + w) * px + 0.99f);
	int y1 = (int)((float)(y + h) * px + 0.99f);
	rl::gl_scissor(x0, rl::get_render_height() - y1, x1 - x0, y1 - y0);
}

fn void set_scale(float s)
{
	scale = math::clamp(s, 0.75f, 3.0f);
	px = scale * dpi;
	rl::set_mouse_scale(1 / scale, 1 / scale); // mouse positions arrive in window px
}

<* Re-read the window's compositor scale (begin_frame calls it). Fonts follow by themselves (atlases are per pixel size). *>
fn void sync_dpi()
{
	float d = rl::get_window_scale_dpi()[0];
	dpi_changed = d > 0 && d != dpi;
	if (!dpi_changed) return;
	dpi = d;
	px = scale * dpi;
}

// Reasonable default: 1.0 at 1440p and below, 1.5 at 4K - measured in window px, so a 4K output that the
// compositor already scales by 1.5 (1440 logical lines) gets 1.0.
fn float auto_scale()
{
	int mh = rl::get_monitor_height(0); // primary output (Wayland gives windows no position)
	if (mh <= 0) return 1;
	return math::clamp(math::round((float)mh / dpi / 1440 * 4) / 4, 1.0f, 2.5f);
}

// Modifier state that came with mouse clicks. raylib only learns Ctrl/Shift from key events sent to its
// window, so a modifier pressed while another window had focus (focus-follows-mouse, a click that focuses
// the window) would be missed. GLFW passes the compositor's modifier state with every mouse button event,
// but raylib drops it: bmu chains its own button callback in front of raylib's (installed once).
alias MouseButtonFn = fn void(void* window, CInt button, CInt action, CInt mods);
extern fn void* glfw_current_context() @cname("glfwGetCurrentContext") @private;
extern fn MouseButtonFn glfw_set_mouse_button_callback(void* window, MouseButtonFn cb) @cname("glfwSetMouseButtonCallback") @private;
MouseButtonFn raylib_button_cb @private;
bool button_hooked @private;
bool pending_ctrl @private;
bool pending_shift @private;
bool click_ctrl;
bool click_shift;

fn void on_mouse_button(void* window, CInt button, CInt action, CInt mods) @private
{
	pending_shift = pending_shift || (mods & 1) != 0; // GLFW_MOD_SHIFT
	pending_ctrl = pending_ctrl || (mods & 2) != 0;   // GLFW_MOD_CONTROL
	if (raylib_button_cb) raylib_button_cb(window, button, action, mods);
}

<* Events are polled at the end of a frame: hand their modifiers to the next frame, then reset. *>
fn void sync_click_modifiers() @private
{
	if (!button_hooked)
	{
		void* window = glfw_current_context();
		if (window)
		{
			raylib_button_cb = glfw_set_mouse_button_callback(window, &on_mouse_button);
			button_hooked = true;
		}
	}
	click_ctrl = pending_ctrl;
	click_shift = pending_shift;
	pending_ctrl = false;
	pending_shift = false;
}

fn void begin_frame()
{
	input_arrows_free = false;
	cursor = DEFAULT;
	consumed = false;
	now = rl::get_time();
	sync_dpi();
	sync_click_modifiers();
	layer = 0;
	if (popup_open) { top = POPUP_LAYER; } else if (menu_id >= 0) { top = MENU_LAYER; }
}

rl::RLMouseCursor shown_cursor @private;
bool cursor_known @private;

fn void end_frame()
{
	if (menu_id >= 0 && menu_seen != menu_id)           // the app did not draw it this frame
	{
		if (menu_fresh) { menu_fresh = false; } else { menu_close(); }
	}
	menu_seen = -1;
	draw_popup();
	draw_toast();
	// Only on change: raylib creates a new GLFW cursor on every call (never freed) and the compositor gets a
	// cursor update each time; per frame that leaked memory and sent 60 updates/s while hovering an input.
	if (!cursor_known || cursor != shown_cursor) { rl::set_mouse_cursor(cursor); shown_cursor = cursor; cursor_known = true; }
}

fn bool live() => layer == top && !consumed;

fn bool point_in(rl::RLVector2 p, Rect r) => p[0] >= r.x && p[0] < r.x + r.width && p[1] >= r.y && p[1] < r.y + r.height;

fn bool hover(Rect r)
{
	if (!live()) return false;
	rl::RLVector2 m = rl::get_mouse_position();
	return point_in(m, r) && point_in(m, clip);
}

fn bool clicked(Rect r)
{
	if (hover(r) && rl::is_mouse_button_pressed(rl::RLMouseButton.LEFT))
	{
		consumed = true;
		return true;
	}
	return false;
}

fn bool right_clicked(Rect r) => hover(r) && rl::is_mouse_button_pressed(rl::RLMouseButton.RIGHT);

// Drawing helpers ---------------------------------------------------------------

fn void panel(Rect r, Color c, float round = 0.0f)
{
	if (round <= 0) { rl::draw_rectangle_rec(r, c); return; }
	float m = r.width < r.height ? r.width : r.height;
	rl::draw_rectangle_rounded(r, round * 2 / m, 8, c);
}

fn void outline(Rect r, Color c, float round = 0.0f, float thick = 1)
{
	if (round <= 0) { rl::draw_rectangle_lines_ex(r, thick, c); return; }
	float m = r.width < r.height ? r.width : r.height;
	rl::draw_rectangle_rounded_lines_ex(r, round * 2 / m, 8, thick, c);
}

fn void hline(float x, float y, float w, Color c = BG1) => rl::draw_rectangle_rec({ x, y, w, 1 }, c);

fn void begin_clip(Rect r)
{
	clip = r;
	scissor((int)r.x, (int)r.y, (int)r.width, (int)r.height);
}

fn void end_clip()
{
	rl::end_scissor_mode();
	clip = { -1e6, -1e6, 2e6, 2e6 };
}

// Buttons -----------------------------------------------------------------------

enum Style
{
	NORMAL,
	PRIMARY,
	GOOD,
	DANGER,
	GHOST,
}

fn bool button(Rect r, String label, Style style = NORMAL, String icon = "", bool enabled = true)
{
	bool h = enabled && hover(r);
	if (h) cursor = POINTING_HAND;
	Color bg;
	Color fg;
	switch (style)
	{
		case NORMAL:  bg = h ? BG2 : BG1;              fg = FG;
		case PRIMARY: bg = h ? YELLOW : DIM_YELLOW;    fg = BG_HARD;
		case GOOD:    bg = h ? GREEN : DIM_GREEN;      fg = BG_HARD;
		case DANGER:  bg = h ? RED : DIM_RED;          fg = BG_HARD;
		case GHOST:   bg = h ? BG1 : { 0, 0, 0, 0 };   fg = h ? FG : FG4;
	}
	if (!enabled) { bg = BG1; fg = BG3; }
	panel(r, bg, 5);
	float size = r.height >= 44 ? 20 : 15;
	float iw = icon.len ? text_w(icon, size) + (label.len ? 8 : 0) : 0;
	float tw = text_w(label, size) + iw;
	float x = r.x + (r.width - tw) / 2;
	float y = r.y + (r.height - size) / 2 - 1;
	if (icon.len) text(icon, x, y, size, fg);
	text(label, x + iw, y, size, fg);
	return enabled && clicked(r);
}

fn bool icon_button(Rect r, String icon, Color color = FG4, String tip = "")
{
	bool h = hover(r);
	if (h)
	{
		cursor = POINTING_HAND;
		panel(r, BG1, 5);
		if (tip.len) tooltip(tip);
	}
	float s = r.height * 0.5f;
	text(icon, r.x + (r.width - text_w(icon, s)) / 2, r.y + (r.height - s) / 2 - 1, s, h ? FG : color);
	return clicked(r);
}

char[256] tip_text;
fn void tooltip(String s) => txt::set(&tip_text, s);

fn bool checkbox(float x, float y, String label, bool* v, String hint = "")
{
	float w = 22 + 10 + text_w(label, 15);
	Rect r = { x, y, w, 24 };
	bool h = hover(r);
	if (h) { cursor = POINTING_HAND; if (hint.len) tooltip(hint); }
	Rect box = { x, y + 2, 20, 20 };
	panel(box, *v ? DIM_YELLOW : (h ? BG2 : BG1), 4);
	if (*v) text(I_CHECK, x + 4, y + 5, 13, BG_HARD);
	text(label, x + 30, y + 4, 15, *v ? FG : FG4);
	if (clicked(r)) { *v = !*v; return true; }
	return false;
}

// Collapsible section heading: chevron + small caps title (+ optional dim detail on the right), `w` wide,
// 22 px tall. Click toggles `*open`; true when toggled. Draw the section's rows only while `*open`.
fn bool section(float x, float y, float w, String title, bool* open, String detail = "")
{
	Rect r = { x - 4, y - 3, w + 8, 22 };
	bool h = hover(r);
	if (h) { cursor = POINTING_HAND; panel(r, BG1, 4); }
	text(*open ? I_DOWN : I_RIGHT, x, y + 2, 10, h ? FG4 : GRAY);
	text(title, x + 16, y, 12, h ? FG4 : GRAY);
	if (detail.len) { float dw = text_w(detail, 12); text(detail, x + w - dw, y, 12, GRAY); }
	if (clicked(r)) { *open = !*open; return true; }
	return false;
}

// Horizontal slider over `r` (track centred vertically, knob 14 px): press anywhere on it and drag to set `*v`
// within [lo, hi]; the mouse wheel over it steps 1/20 of the range. True in frames where `*v` changed.
// The dragged value is remembered by its address, so `v` must stay the same pointer while dragging.
float* slider_drag;
fn bool slider(Rect r, float* v, float lo = 0, float hi = 1, String tip = "")
{
	float old = *v;
	bool h = hover(r);
	if (h) { cursor = POINTING_HAND; if (tip.len) tooltip(tip); }
	if (h && rl::is_mouse_button_pressed(rl::RLMouseButton.LEFT)) { slider_drag = v; consumed = true; }
	if (slider_drag == v && !rl::is_mouse_button_down(rl::RLMouseButton.LEFT)) slider_drag = null;
	float pad = 7;
	float span = r.width - 2 * pad;
	if (slider_drag == v && layer == top && span > 0)
	{
		*v = lo + (rl::get_mouse_position()[0] - r.x - pad) / span * (hi - lo);
		cursor = POINTING_HAND;
	}
	else if (h)
	{
		float wheel = rl::get_mouse_wheel_move();
		if (wheel != 0) *v += wheel * (hi - lo) / 20;
	}
	*v = math::clamp(*v, math::min(lo, hi), math::max(lo, hi));
	float t = hi != lo ? (*v - lo) / (hi - lo) : 0;
	float cy = r.y + r.height / 2;
	bool on = h || slider_drag == v;
	panel({ r.x + pad, cy - 2, span, 4 }, BG2, 2);
	panel({ r.x + pad, cy - 2, span * t, 4 }, on ? YELLOW : DIM_YELLOW, 2);
	rl::draw_circle_v({ r.x + pad + span * t, cy }, on ? 7.5f : 7, on ? FG : FG4);
	return *v != old;
}

// Text input ----------------------------------------------------------------------
// One field is focused at a time; caret/anchor/undo belong to that field.
// Selection is [min(anchor, caret), max(anchor, caret)).

int focus = -1;     // id of the focused input
bool input_arrows_free; // set before ui::input to keep Up/Down for the app (suggestion lists); reset every frame
usz caret;
usz anchor;
double caret_blink;
float input_off;    // horizontal scroll of the focused field
bool dragging;
double last_click_time;
usz last_click_pos;
int click_count;

const MAX_UNDO = 48;
struct Snapshot
{
	char[1024] text;
	usz caret;
}
Snapshot[MAX_UNDO] undo_stack;
int undo_count;
Snapshot[MAX_UNDO] redo_stack;
int redo_count;
int last_edit_kind;  // coalesces consecutive typing into one undo step
double last_edit_time;

fn bool focused(int id) => focus == id;
fn void unfocus() => focus = -1;
fn void focus_on(int id, char[] buf)
{
	focus = id;
	caret = txt::view(buf).len;
	anchor = 0;            // focusing via shortcut selects everything
	caret_blink = now;
	input_off = 0;
	undo_count = 0;
	redo_count = 0;
	last_edit_kind = 0;
}

// Keyboard layout awareness: raylib key codes are US positions, so Ctrl+Z on
// QWERTZ would be the key labelled Y. GLFW knows which letter each key produces.
extern fn ZString glfw_key_name(CInt key, CInt scancode) @cname("glfwGetKeyName");
int[26] letter_keys;
int plus_key = (int)rl::RLKeyboardKey.EQUAL;
int minus_key = (int)rl::RLKeyboardKey.MINUS;

fn void map_layout()
{
	for (int k = 0; k < 26; k++) letter_keys[k] = 65 + k;
	plus_key = (int)rl::RLKeyboardKey.EQUAL;
	minus_key = (int)rl::RLKeyboardKey.MINUS;
	for (int code = 32; code <= 96; code++)
	{
		// Only defined printable GLFW keys have valid scancodes.
		if (!((code >= 44 && code <= 57) || (code >= 65 && code <= 93) ||
			code == 32 || code == 39 || code == 59 || code == 61 || code == 96)) continue;
		ZString name = glfw_key_name(code, 0);
		if (!name || !name[0] || name[1]) continue;
		char c = txt::lower(name[0]);
		if (c >= 'a' && c <= 'z') letter_keys[c - 'a'] = code;
		if (c == '+') plus_key = code;
		if (c == '-') minus_key = code;
	}
}

// Layout-aware +/- presses, including keypad. Caller chooses modifiers and step size.
fn int zoom_step()
{
	int step;
	if (rl::is_key_pressed((rl::RLKeyboardKey)plus_key) || rl::is_key_pressed(rl::RLKeyboardKey.KP_ADD)) step++;
	if (rl::is_key_pressed((rl::RLKeyboardKey)minus_key) || rl::is_key_pressed(rl::RLKeyboardKey.KP_SUBTRACT)) step--;
	return step;
}

fn bool letter(char c) => rl::is_key_pressed((rl::RLKeyboardKey)letter_keys[c - 'a']);
fn bool ctrl_down() => click_ctrl || rl::is_key_down(rl::RLKeyboardKey.LEFT_CONTROL) || rl::is_key_down(rl::RLKeyboardKey.RIGHT_CONTROL);
fn bool shift_down() => click_shift || rl::is_key_down(rl::RLKeyboardKey.LEFT_SHIFT) || rl::is_key_down(rl::RLKeyboardKey.RIGHT_SHIFT);

fn bool has_sel() => anchor != caret;

<* Replace an input's text (e.g. accept a completion) and put the caret at the end. *>
fn void input_replace(char[] buf, String s)
{
	txt::set(buf, s);
	caret = txt::view(buf).len;
	anchor = caret;
	caret_blink = now;
}
fn usz sel_lo() => anchor < caret ? anchor : caret;
fn usz sel_hi() => anchor < caret ? caret : anchor;

fn void push_snapshot(Snapshot[] stack, int* count, char[] buf)
{
	if (*count == MAX_UNDO)
	{
		for (int i = 1; i < MAX_UNDO; i++) stack[i - 1] = stack[i];
		(*count)--;
	}
	txt::set(&stack[*count].text, txt::view(buf));
	stack[*count].caret = caret;
	(*count)++;
}

// Record undo state before an edit. kind 1 = typing (coalesced), 2 = other.
fn void before_edit(char[] buf, int kind)
{
	bool coalesce = kind == 1 && last_edit_kind == 1 && now - last_edit_time < 1.0 && !has_sel();
	if (!coalesce) push_snapshot(&undo_stack, &undo_count, buf);
	redo_count = 0;
	last_edit_kind = kind;
	last_edit_time = now;
}

fn void restore(char[] buf, Snapshot* s)
{
	txt::set(buf, txt::view(&s.text));
	caret = s.caret;
	usz len = txt::view(buf).len;
	if (caret > len) caret = len;
	anchor = caret;
	last_edit_kind = 0;
}

fn void delete_sel(char[] buf)
{
	usz lo = sel_lo();
	remove_range(buf, lo, sel_hi());
	caret = lo;
	anchor = lo;
}

fn void copy_sel(char[] buf) => @pool()
{
	if (!has_sel()) return;
	String s = txt::view(buf)[sel_lo()..sel_hi() - 1];
	rl::set_clipboard_text(s.zstr_tcopy());
}

fn void select_word(char[] buf, usz at)
{
	usz lo = at;
	usz hi = at;
	while (lo > 0 && !word_sep(buf[lo - 1])) lo--;
	while (buf[hi] != 0 && !word_sep(buf[hi])) hi++;
	anchor = lo;
	caret = hi;
}

<*
 Single line text field. Returns true when the content changed.
 `submitted` (optional) is set when Enter was pressed.
*>
extern fn void explicit_bzero(void* p, usz n) @cname("explicit_bzero") @private @feat(LINUX);

<* Zero a buffer (e.g. a password) in a way the compiler cannot drop. *>
fn void wipe(char[] buf) @feat(LINUX) => explicit_bzero(buf.ptr, buf.len);
fn void wipe(char[] buf) @feat(!LINUX)
{
	foreach (&c : buf) @volatile_store(*c, (char)0);   // volatile: not optimised away
}

<*
 Password field: shows one bullet per character. Typing and paste append, Backspace / Ctrl+Backspace / Ctrl+U delete,
 Enter sets `submitted`. No caret movement, selection, copy or undo history, so the secret is only ever in `buf`:
 wipe(&buf) when done. Returns true when the text changed.
*>
fn bool secret_input(int id, Rect r, char[] buf, String placeholder = "", bool* submitted = null)
{
	float pad = 10;
	float tx = r.x + pad + 24;
	float avail = r.x + r.width - pad - tx;
	bool h = hover(r);
	if (h) cursor = IBEAM;
	if (rl::is_mouse_button_pressed(rl::RLMouseButton.LEFT) && live())
	{
		if (h) { if (focus != id) { focus = id; caret_blink = now; } consumed = true; }
		else if (focus == id) { focus = -1; }
	}
	bool f = focus == id && layer == top;
	panel(r, BG_HARD, 5);
	outline(r, f ? DIM_YELLOW : (h ? BG2 : BG1), 5, 1);
	bool changed;
	if (f)
	{
		bool ctrl = ctrl_down();
		int ch = rl::get_char_pressed();
		while (ch > 0)
		{
			if (!ctrl) { caret = txt::view(buf).len; changed |= insert_codepoint(buf, ch); }
			ch = rl::get_char_pressed();
		}
		if (repeat(rl::RLKeyboardKey.BACKSPACE))
		{
			usz len = txt::view(buf).len;
			if (ctrl) { wipe(buf); }
			else if (len) { usz p = prev_char(buf, len); for (usz i = p; i < len; i++) buf[i] = 0; }
			changed = true;
		}
		if (ctrl && letter('u')) { wipe(buf); changed = true; }
		if (ctrl && letter('v'))
		{
			ZString clip_text = rl::get_clipboard_text();
			if (clip_text)
			{
				caret = txt::view(buf).len;
				foreach (c : clip_text.str_view()) { if (c != '\n' && c != '\r') insert_byte(buf, c); }
				changed = true;
			}
		}
		if (rl::is_key_pressed(rl::RLKeyboardKey.ENTER) || rl::is_key_pressed(rl::RLKeyboardKey.KP_ENTER)) { if (submitted) *submitted = true; }
		if (rl::is_key_pressed(rl::RLKeyboardKey.ESCAPE)) focus = -1;
		if (changed) caret_blink = now;
	}
	text(I_LOCK, r.x + pad, r.y + (r.height - 14) / 2, 14, GRAY);
	float ty = r.y + (r.height - 15) / 2 - 1;
	// One bullet per codepoint, capped to the visible width (the length is not shown beyond that).
	int n;
	foreach (c : txt::view(buf)) if ((c & 0xC0) != 0x80) n++;
	if (n == 0 && !f) { text(placeholder, tx, ty, 15, BG4); return changed; }
	char[192] dots;
	int fit = math::min(n, (int)(avail / math::max(1.0f, text_w("•", 15))) - 1, 64);
	usz k;
	for (int i = 0; i < fit; i++) { dots[k++] = 0xE2; dots[k++] = 0x80; dots[k++] = 0xA2; }
	String shown = (String)dots[:k];
	text(shown, tx, ty, 15, FG);
	if (f && (now - caret_blink) - math::floor(now - caret_blink) < 0.6)
	{
		rl::draw_rectangle_rec({ tx + text_w(shown, 15), r.y + 7, 2, r.height - 14 }, YELLOW);
	}
	return changed;
}

fn bool input(int id, Rect r, char[] buf, String placeholder = "", bool* submitted = null, String icon = "")
{
	float pad = 10;
	float tx = r.x + pad + (icon.len ? 24 : 0);
	float avail = r.x + r.width - pad - tx;

	bool h = hover(r);
	if (h) cursor = IBEAM;
	if (rl::is_mouse_button_pressed(rl::RLMouseButton.LEFT) && live())
	{
		if (h)
		{
			bool was = focus == id;
			if (!was) { focus_on(id, buf); input_off = 0; }
			usz pos = caret_at(txt::view(buf), rl::get_mouse_position()[0] - tx + input_off);
			if (was && now - last_click_time < 0.4 && pos == last_click_pos) { click_count++; } else { click_count = 1; }
			last_click_time = now;
			last_click_pos = pos;
			caret = pos;
			if (click_count == 2) { select_word(buf, pos); }
			else if (click_count >= 3) { anchor = 0; caret = txt::view(buf).len; }
			else if (!(was && shift_down())) { anchor = pos; }
			dragging = click_count == 1;
			caret_blink = now;
			consumed = true;
		}
		else if (focus == id) { focus = -1; }
	}
	bool f = focus == id && layer == top;
	if (f && dragging)
	{
		if (rl::is_mouse_button_down(rl::RLMouseButton.LEFT))
		{
			caret = caret_at(txt::view(buf), rl::get_mouse_position()[0] - tx + input_off);
		}
		else
		{
			dragging = false;
		}
	}
	panel(r, BG_HARD, 5);
	outline(r, f ? DIM_YELLOW : (h ? BG2 : BG1), 5, 1);

	bool changed = false;
	if (f)
	{
		usz len = txt::view(buf).len;
		if (caret > len) caret = len;
		if (anchor > len) anchor = len;
		bool ctrl = ctrl_down();
		bool shift = shift_down();

		int ch = rl::get_char_pressed();
		while (ch > 0)
		{
			if (!ctrl)
			{
				before_edit(buf, 1);
				if (has_sel()) delete_sel(buf);
				changed |= insert_codepoint(buf, ch);
				anchor = caret;
			}
			ch = rl::get_char_pressed();
		}
		if (repeat(rl::RLKeyboardKey.BACKSPACE) && (caret > 0 || has_sel()))
		{
			before_edit(buf, 2);
			if (!has_sel()) anchor = ctrl ? word_left(buf, caret) : prev_char(buf, caret);
			delete_sel(buf);
			changed = true;
		}
		if (repeat(rl::RLKeyboardKey.DELETE) && (buf[caret] != 0 || has_sel()))
		{
			before_edit(buf, 2);
			if (!has_sel()) anchor = ctrl ? word_right(buf, caret) : next_char(buf, caret);
			delete_sel(buf);
			changed = true;
		}

		// movement; Shift extends the selection
		bool moved = false;
		usz target = caret;
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
		if (rl::is_key_pressed(rl::RLKeyboardKey.HOME) || (!input_arrows_free && rl::is_key_pressed(rl::RLKeyboardKey.UP))) { target = 0; moved = true; }
		if (rl::is_key_pressed(rl::RLKeyboardKey.END) || (!input_arrows_free && rl::is_key_pressed(rl::RLKeyboardKey.DOWN))) { target = txt::view(buf).len; moved = true; }
		if (moved)
		{
			caret = target;
			if (!shift) anchor = caret;
			caret_blink = now;
			last_edit_kind = 0;
		}

		if (ctrl)
		{
			if (letter('a')) { anchor = 0; caret = txt::view(buf).len; }
			if (letter('c')) copy_sel(buf);
			if (letter('x') && has_sel())
			{
				before_edit(buf, 2);
				copy_sel(buf);
				delete_sel(buf);
				changed = true;
			}
			if (letter('v') || (shift && rl::is_key_pressed(rl::RLKeyboardKey.INSERT)))
			{
				ZString clip_text = rl::get_clipboard_text();
				if (clip_text && clip_text[0])
				{
					before_edit(buf, 2);
					if (has_sel()) delete_sel(buf);
					foreach (c : clip_text.str_view())
					{
						if (c == '\n' || c == '\r' || c == '\t') continue;
						insert_byte(buf, c);
					}
					anchor = caret;
					changed = true;
				}
			}
			bool redo = letter('y') || (shift && letter('z'));
			if (letter('z') && !shift && undo_count > 0)
			{
				push_snapshot(&redo_stack, &redo_count, buf);
				restore(buf, &undo_stack[--undo_count]);
				changed = true;
			}
			else if (redo && redo_count > 0)
			{
				push_snapshot(&undo_stack, &undo_count, buf);
				restore(buf, &redo_stack[--redo_count]);
				changed = true;
			}
			if (letter('u'))
			{
				before_edit(buf, 2);
				buf[0] = 0;
				caret = 0;
				anchor = 0;
				changed = true;
			}
		}
		if (rl::is_key_pressed(rl::RLKeyboardKey.ENTER) || rl::is_key_pressed(rl::RLKeyboardKey.KP_ENTER))
		{
			if (submitted) *submitted = true;
		}
		if (rl::is_key_pressed(rl::RLKeyboardKey.ESCAPE))
		{
			if (has_sel()) { anchor = caret; } else { focus = -1; }
		}
	}

	String s = txt::view(buf);
	if (icon.len) text(icon, r.x + pad, r.y + (r.height - 14) / 2, 14, GRAY);
	float ty = r.y + (r.height - 15) / 2 - 1;
	Rect saved = clip;
	scissor((int)tx - 2, (int)r.y, (int)avail + 4, (int)r.height);
	if (s.len == 0 && !f)
	{
		text(placeholder, tx, ty, 15, BG4);
	}
	else if (f)
	{
		// keep a stable scroll offset that only moves to keep the caret in view
		float cw = text_w(s[:caret], 15);
		float total = text_w(s, 15);
		if (cw - input_off > avail - 4) input_off = cw - avail + 4;
		if (cw - input_off < 0) input_off = cw;
		if (input_off > 0 && total - input_off < avail - 4) input_off = math::max(0.0f, total - avail + 4);
		if (has_sel())
		{
			float x0 = text_w(s[:sel_lo()], 15);
			float x1 = text_w(s[:sel_hi()], 15);
			rl::draw_rectangle_rec({ tx - input_off + x0, r.y + 6, x1 - x0, r.height - 12 }, { 215, 153, 33, 110 });
		}
		text(s, tx - input_off, ty, 15, FG);
		if ((now - caret_blink) - math::floor(now - caret_blink) < 0.6)
		{
			rl::draw_rectangle_rec({ tx - input_off + cw, r.y + 7, 2, r.height - 14 }, YELLOW);
		}
	}
	else
	{
		// unfocused: long values (paths) show their end
		float total = text_w(s, 15);
		text(s, tx - (total > avail ? total - avail : 0), ty, 15, FG);
	}
	rl::end_scissor_mode();
	if (saved.width < 1e6) scissor((int)saved.x, (int)saved.y, (int)saved.width, (int)saved.height);
	return changed;
}

// Byte index of the character boundary closest to pixel offset `x`.
fn usz caret_at(String s, float x)
{
	if (x <= 0) return 0;
	usz best = s.len;
	float prev = 0;
	usz i = 0;
	while (i < s.len)
	{
		usz n = i + 1;
		while (n < s.len && (s[n] & 0xC0) == 0x80) n++;
		float w = text_w(s[:n], 15);
		if (x < w)
		{
			best = x - prev < w - x ? i : n;
			break;
		}
		prev = w;
		i = n;
	}
	return best;
}

fn usz prev_char(char[] buf, usz i)
{
	if (i == 0) return 0;
	i--;
	while (i > 0 && (buf[i] & 0xC0) == 0x80) i--;
	return i;
}

fn usz next_char(char[] buf, usz i)
{
	if (buf[i] == 0) return i;
	i++;
	while (buf[i] != 0 && (buf[i] & 0xC0) == 0x80) i++;
	return i;
}

fn bool word_sep(char c) => c == ' ' || c == '\n' || c == '/' || c == '_' || c == '-' || c == '.' || c == '=';

fn usz word_left(char[] buf, usz i)
{
	while (i > 0 && word_sep(buf[i - 1])) i--;
	while (i > 0 && !word_sep(buf[i - 1])) i--;
	return i;
}

fn usz word_right(char[] buf, usz i)
{
	while (buf[i] != 0 && word_sep(buf[i])) i++;
	while (buf[i] != 0 && !word_sep(buf[i])) i++;
	return i;
}

fn bool repeat(rl::RLKeyboardKey k) => rl::is_key_pressed(k) || rl::is_key_pressed_repeat(k);

fn void remove_range(char[] buf, usz start, usz end)
{
	usz len = txt::view(buf).len;
	for (usz i = 0; end + i <= len; i++) buf[start + i] = buf[end + i];
	caret = start;
	caret_blink = now;
}

fn bool insert_byte(char[] buf, char c)
{
	usz len = txt::view(buf).len;
	if (len + 2 >= buf.len) return false;
	for (usz i = len + 1; i > caret; i--) buf[i] = buf[i - 1];
	buf[caret++] = c;
	caret_blink = now;
	return true;
}

fn bool insert_codepoint(char[] buf, int cp)
{
	char[4] u;
	usz n;
	if (cp < 0x80) { u[0] = (char)cp; n = 1; }
	else if (cp < 0x800) { u[0] = (char)(0xC0 | (cp >> 6)); u[1] = (char)(0x80 | (cp & 0x3F)); n = 2; }
	else if (cp < 0x10000) { u[0] = (char)(0xE0 | (cp >> 12)); u[1] = (char)(0x80 | ((cp >> 6) & 0x3F)); u[2] = (char)(0x80 | (cp & 0x3F)); n = 3; }
	else { u[0] = (char)(0xF0 | (cp >> 18)); u[1] = (char)(0x80 | ((cp >> 12) & 0x3F)); u[2] = (char)(0x80 | ((cp >> 6) & 0x3F)); u[3] = (char)(0x80 | (cp & 0x3F)); n = 4; }
	if (txt::view(buf).len + n + 1 >= buf.len) return false;
	for (usz i = 0; i < n; i++) insert_byte(buf, u[i]);
	return true;
}

// Dropdown --------------------------------------------------------------------------
// The popup is drawn at the end of the frame above everything else.

int dd_id = -1;
Rect dd_rect;
String[64] dd_items;
int dd_count;
int dd_result = -1;   // selection made last frame for dd_id
int dd_result_id = -1;
float dd_scroll;
int dd_prev_top;
char[8192] dd_store;  // item text storage (copied, valid while open)

fn bool dropdown(int id, Rect r, String[] items, int* sel)
{
	bool changed = false;
	if (dd_result_id == id && dd_result >= 0)
	{
		*sel = dd_result;
		dd_result = -1;
		dd_result_id = -1;
		changed = true;
	}
	bool h = hover(r);
	if (h) cursor = POINTING_HAND;
	bool open = popup_open && dd_id == id;
	panel(r, h || open ? BG2 : BG1, 5);
	String cur = *sel >= 0 && *sel < items.len ? items[*sel] : "";
	text_fit(cur, r.x + 10, r.y + (r.height - 15) / 2 - 1, r.width - 40, 15, FG);
	text(I_DOWN, r.x + r.width - 24, r.y + (r.height - 12) / 2, 12, FG4);
	if (clicked(r))
	{
		dd_id = id;
		dd_rect = r;
		dd_count = 0;
		dd_scroll = 0;
		usz off = 0;
		foreach (it : items)
		{
			if (dd_count >= dd_items.len || off + it.len >= dd_store.len) break;
			mem::copy(&dd_store[off], it.ptr, it.len);
			dd_items[dd_count++] = (String)dd_store[off:it.len];
			off += it.len;
		}
		dd_prev_top = top;
		popup_open = true;
		top = POPUP_LAYER;
	}
	return changed;
}

fn void draw_popup()
{
	if (!popup_open) return;
	int saved = layer;
	layer = POPUP_LAYER;
	float row = 30;
	float h = math::min((float)dd_count * row + 8, 340.0f);
	float y = dd_rect.y + dd_rect.height + 4;
	if (y + h > sh() - 8) y = dd_rect.y - h - 4;
	Rect box = { dd_rect.x, y, dd_rect.width, h };
	rl::draw_rectangle_rounded({ box.x + 3, box.y + 5, box.width, box.height }, 0.04f, 6, { 0, 0, 0, 90 });
	panel(box, BG1, 6);
	outline(box, BG3, 6);
	float content = (float)dd_count * row + 8;
	dd_scroll = scroll_wheel(box, dd_scroll, content);
	begin_clip(box);
	for (int i = 0; i < dd_count; i++)
	{
		Rect r = { box.x + 4, box.y + 4 + (float)i * row - dd_scroll, box.width - 8, row };
		if (hover(r)) { panel(r, BG2, 4); cursor = POINTING_HAND; }
		text_fit(dd_items[i], r.x + 8, r.y + 7, r.width - 16, 15, FG);
		if (clicked(r))
		{
			dd_result = i;
			dd_result_id = dd_id;
			close_popup();
		}
	}
	end_clip();
	if (popup_open && !consumed && rl::is_mouse_button_pressed(rl::RLMouseButton.LEFT) && !point_in(rl::get_mouse_position(), box))
	{
		close_popup();
		consumed = true;
	}
	if (popup_open && rl::is_key_pressed(rl::RLKeyboardKey.ESCAPE)) close_popup();
	layer = saved;
}

fn void close_popup()
{
	popup_open = false;
	top = dd_prev_top;
}

// Context menu ------------------------------------------------------------------------
// ui::menu_open(ID) on a right click; every frame, after everything else on the window:
//   if (ui::menu_begin(ID)) { if (ui::menu_item("Open", I_FOLDER_OPEN, "Enter")) ...; ui::menu_sep(); ...; ui::menu_end(); }
// While open it owns input (top = MENU_LAYER). The height is measured while drawing, so
// the first frame places the box with an estimate; nothing can be clicked in that frame.

const int MENU_LAYER = 98;
const float MENU_ROW = 30;
const MAX_MENU_ITEMS = 32;

struct MenuItem
{
	String label;
	String icon;
	String keys;
	bool enabled;
	bool sep;
}

int menu_id = -1;     // open menu, -1 = none
int menu_seen = -1;   // menu_begin ran this frame for menu_id
rl::RLVector2 menu_at;
Rect menu_box;
float menu_h;         // measured height (last frame)
float menu_y;
int menu_count;
int menu_hot = -1;    // highlighted item (mouse or arrow keys)
bool menu_fresh;      // opened this frame: ignore the opening click
int menu_prev_top;
int menu_saved_layer;
MenuItem[MAX_MENU_ITEMS] menu_items;
char[4096] menu_store;
usz menu_off;

<* Open context menu `id` at the mouse (or at `x, y` when given). Closes a dropdown. *>
fn void menu_open(int id, float x = -1, float y = -1)
{
	if (popup_open) close_popup();
	menu_prev_top = menu_id >= 0 ? menu_prev_top : top;
	menu_id = id;
	menu_at = x >= 0 ? (rl::RLVector2){ x, y } : rl::get_mouse_position();
	menu_h = 0;
	menu_hot = -1;
	menu_fresh = true;
	top = MENU_LAYER;
	consumed = true;
}

fn void menu_close()
{
	if (menu_id < 0) return;
	menu_id = -1;
	top = menu_prev_top;
}

fn bool menu_is_open(int id) => menu_id == id;

fn String menu_keep(String s)
{
	if (menu_off + s.len > menu_store.len) return "";
	mem::copy(&menu_store[menu_off], s.ptr, s.len);
	String r = (String)menu_store[menu_off:s.len];
	menu_off += s.len;
	return r;
}

fn Rect menu_place(float w, float h)
{
	float x = math::min(menu_at[0], sw() - w - 6);
	float y = menu_at[1];
	if (y + h > sh() - 6) y = math::max(6.0f, menu_at[1] - h);
	return { math::max(6.0f, x), y, w, h };
}

<*
 Start drawing menu `id`. Call after all other widgets of the frame (it must be on top).
 @return "true while the menu is open: then add items and call menu_end()"
*>
fn bool menu_begin(int id, float w = 240)
{
	if (menu_id != id) return false;
	menu_seen = id;
	menu_count = 0;
	menu_off = 0;
	menu_box = menu_place(w, menu_h > 0 ? menu_h : 8);
	menu_y = menu_box.y + 4;
	menu_saved_layer = layer;
	layer = MENU_LAYER;
	return true;
}

<*
 One entry: icon, label, shortcut hint on the right (`keys`, display only).
 @return "true when chosen (click or Enter); the menu closes"
*>
fn bool menu_item(String label, String icon = "", String keys = "", bool enabled = true)
{
	if (menu_count >= MAX_MENU_ITEMS) return false;
	Rect r = { menu_box.x + 4, menu_y, menu_box.width - 8, MENU_ROW };
	menu_y += MENU_ROW;
	int i = menu_count++;
	menu_items[i] = { menu_keep(label), menu_keep(icon), menu_keep(keys), enabled, false };
	if (menu_id < 0 || menu_fresh || !enabled) return false;
	if (hover(r)) menu_hot = i;
	bool hit = clicked(r) || (menu_hot == i && live() && (rl::is_key_pressed(rl::RLKeyboardKey.ENTER) || rl::is_key_pressed(rl::RLKeyboardKey.KP_ENTER)));
	if (hit) { menu_close(); consumed = true; }
	return hit;
}

fn void menu_sep()
{
	if (menu_count >= MAX_MENU_ITEMS) return;
	menu_items[menu_count++] = { .sep = true };
	menu_y += 9;
}

<* Draw the menu, handle arrows / Esc / clicks outside. *>
fn void menu_end()
{
	float h = menu_y - menu_box.y + 4;
	bool was_fresh = menu_fresh;
	menu_fresh = false;
	if (menu_id >= 0)
	{
		menu_h = h;
		Rect box = menu_place(menu_box.width, h);
		rl::draw_rectangle_rounded({ box.x + 3, box.y + 5, box.width, box.height }, 0.04f, 6, { 0, 0, 0, 90 });
		panel(box, BG1, 6);
		outline(box, BG3, 6);
		float y = box.y + 4;
		for (int i = 0; i < menu_count; i++)
		{
			MenuItem* it = &menu_items[i];
			if (it.sep) { hline(box.x + 10, y + 4, box.width - 20, BG3); y += 9; continue; }
			Rect r = { box.x + 4, y, box.width - 8, MENU_ROW };
			y += MENU_ROW;
			if (it.enabled && i == menu_hot) { panel(r, BG2, 4); cursor = POINTING_HAND; }
			Color c = it.enabled ? FG : BG3;
			if (it.icon.len) text(it.icon, r.x + 10, r.y + 8, 14, it.enabled ? FG4 : BG3);
			float kw = it.keys.len ? text_w(it.keys, 13) + 12 : 0;
			text_fit(it.label, r.x + 34, r.y + 7, r.width - 44 - kw, 15, c);
			if (it.keys.len) text(it.keys, r.x + r.width - kw, r.y + 8, 13, GRAY);
		}
		if (!was_fresh)
		{
			bool down = repeat(rl::RLKeyboardKey.DOWN);
			bool up = repeat(rl::RLKeyboardKey.UP);
			if (down || up) menu_step(down ? 1 : -1);
			bool press = rl::is_mouse_button_pressed(rl::RLMouseButton.LEFT) || rl::is_mouse_button_pressed(rl::RLMouseButton.RIGHT);
			if (press && !consumed && !point_in(rl::get_mouse_position(), box)) { menu_close(); consumed = true; }
			if (rl::is_key_pressed(rl::RLKeyboardKey.ESCAPE)) menu_close();
		}
	}
	layer = menu_saved_layer;
}

fn void menu_step(int d)
{
	for (int n = 0; n < menu_count; n++)
	{
		menu_hot += d;
		if (menu_hot >= menu_count) menu_hot = 0;
		if (menu_hot < 0) menu_hot = menu_count - 1;
		if (!menu_items[menu_hot].sep && menu_items[menu_hot].enabled) return;
	}
	menu_hot = -1;
}

// Scrolling ---------------------------------------------------------------------------

fn float scroll_wheel(Rect area, float scroll, float content)
{
	if (live() && point_in(rl::get_mouse_position(), area))
	{
		scroll -= rl::get_mouse_wheel_move() * 48;
	}
	float max = content - area.height;
	if (max < 0) max = 0;
	if (scroll > max) scroll = max;
	if (scroll < 0) scroll = 0;
	return scroll;
}

fn void scrollbar(Rect area, float scroll, float content)
{
	if (content <= area.height) return;
	float frac = area.height / content;
	float bh = math::max(area.height * frac, 24.0f);
	float by = area.y + (area.height - bh) * (scroll / (content - area.height));
	panel({ area.x + area.width - 6, by, 4, bh }, BG3, 2);
}

// Toasts --------------------------------------------------------------------------------

char[512] toast_text;
double toast_until;
Color toast_color;

fn void toast(String s, Color c = AQUA)
{
	txt::set(&toast_text, s);
	toast_until = rl::get_time() + 3.5;
	toast_color = c;
}

fn void draw_toast()
{
	if (!txt::empty(&tip_text))
	{
		rl::RLVector2 m = rl::get_mouse_position();
		String t = txt::view(&tip_text);
		float w = text_w(t, 14) + 16;
		float x = math::min(m[0] + 14, sw() - w - 6);
		Rect r = { x, m[1] + 18, w, 26 };
		panel(r, BG_HARD, 4);
		outline(r, BG3, 4);
		text(t, r.x + 8, r.y + 5, 14, FG);
		tip_text[0] = 0;
	}
	if (now > toast_until) return;
	String t = txt::view(&toast_text);
	float w = text_w(t, 15) + 40;
	float a = (float)math::min(1.0, (toast_until - now) * 3);
	Rect r = { sw() - w - 20, sh() - 76, w, 40 };
	panel(r, { BG1.r, BG1.g, BG1.b, (char)(250 * a) }, 6);
	rl::draw_rectangle_rec({ r.x, r.y + 8, 3, r.height - 16 }, { toast_color.r, toast_color.g, toast_color.b, (char)(255 * a) });
	text(t, r.x + 20, r.y + 11, 15, { FG.r, FG.g, FG.b, (char)(255 * a) });
}

// Shared layout helpers -------------------------------------------------------------------

fn void label(float x, float y, String s) => text(s, x, y, 14, FG4);

<*
 Modal dialog frame: dims the whole window, draws a centered box (at most w x h,
 always 40 px away from the window edge) and returns it. Draw it on layer 1.
*>
fn Rect dialog(float w, float h)
{
	float vw = sw();
	float vh = sh();
	rl::draw_rectangle(0, 0, (int)vw + 1, (int)vh + 1, { 0, 0, 0, 150 });
	w = math::min(vw - 80, w);
	h = math::min(vh - 80, h);
	Rect box = { (vw - w) / 2, (vh - h) / 2, w, h };
	panel({ box.x + 4, box.y + 8, box.width, box.height }, { 0, 0, 0, 110 }, 10);
	panel(box, BG, 10);
	outline(box, BG2, 10);
	return box;
}

<*
 Title row of a dialog: icon + title on the left, a close (X) button on the right.
 @return "true when the close button was clicked"
*>
fn bool dialog_header(Rect box, String icon, String title, String close_tip = "Close (Esc)")
{
	float x = box.x + 20;
	float y = box.y + 16;
	if (icon.len) { text(icon, x, y + 2, 18, YELLOW); x += 30; }
	text(title, x, y, 20, FG);
	return icon_button({ box.x + box.width - 44, y - 4, 30, 30 }, I_TIMES, FG4, close_tip);
}

// An image fit into `r` (keeps aspect), or - when `tex` is null - a placeholder
// tile tinted by a hash of `name` showing its first letter.
fn void tile(Rect r, rl::RLTexture2D* tex, String name)
{
	if (tex)
	{
		float sw = (float)tex.width;
		float sh = (float)tex.height;
		float s = math::min(r.width / sw, r.height / sh);
		float w = sw * s;
		float h = sh * s;
		rl::draw_texture_pro(*tex, { 0, 0, sw, sh }, { r.x + (r.width - w) / 2, r.y + (r.height - h) / 2, w, h }, { 0, 0 }, 0, rl::WHITE);
		return;
	}
	Color[6] tints = { DIM_YELLOW, BLUE, PURPLE, AQUA, ORANGE, DIM_GREEN };
	uint hsh = 0;
	foreach (c : name) hsh = hsh * 31 + c;
	Color tint = tints[hsh % 6];
	panel(r, BG2, r.width * 0.14f);
	panel({ r.x + 3, r.y + 3, r.width - 6, r.height - 6 }, { tint.r, tint.g, tint.b, 70 }, r.width * 0.12f);
	String letter = name.len ? name[:1] : "?";
	float s = r.height * 0.5f;
	text(letter, r.x + (r.width - text_w(letter, s)) / 2, r.y + (r.height - s) / 2 - 2, s, tint);
}
