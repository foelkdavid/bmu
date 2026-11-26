module bmu::ui;
import std::math, std::core::string, std::os::env;
import raylib6::rl;
import bmu::txt;

// Reusable "help / about" pieces for settings dialogs: a shortcut table and an About panel.

struct Shortcut
{
	String keys;      // "Ctrl + S"; for a heading: its title
	String action;
	bool heading;
}

const float SHORTCUT_ROW = 38;

<*
 Scrollable shortcut list (virtualized): headings in yellow, key caps on the left. Returns the new scroll offset;
 keep it in a global and pass it back next frame.
*>
fn float shortcut_table(Rect area, Shortcut[] rows, float scroll)
{
	float content = (float)rows.len * SHORTCUT_ROW;
	scroll = scroll_wheel(area, scroll, content);
	begin_clip(area);
	int first = math::max(0, (int)(scroll / SHORTCUT_ROW));
	int end = math::min((int)rows.len, first + (int)(area.height / SHORTCUT_ROW) + 2);
	float x = area.x;
	float width = area.width;
	float key_w = math::min(184.0f, (width - 40) * 0.45f);
	for (int i = first; i < end; i++)
	{
		float row_y = area.y + (float)i * SHORTCUT_ROW - scroll;
		Shortcut* s = &rows[i];
		if (s.heading)
		{
			text(s.keys, x + 8, row_y + 13, 13, YELLOW);
			hline(x + 146, row_y + 21, width - 166, BG2);
			continue;
		}
		panel({ x, row_y + 2, width - 12, SHORTCUT_ROW - 4 }, BG_HARD, 4);
		panel({ x + 6, row_y + 6, key_w, SHORTCUT_ROW - 12 }, BG1, 4);
		outline({ x + 6, row_y + 6, key_w, SHORTCUT_ROW - 12 }, BG2, 4);
		text_fit(s.keys, x + 16, row_y + 12, key_w - 20, 14, AQUA);
		text_fit(s.action, x + key_w + 22, row_y + 11, width - key_w - 44, 15, FG);
	}
	end_clip();
	scrollbar(area, scroll, content);
	return scroll;
}

<* bmu library version (= bmu project.json "version"; bmu-check verifies they match). *>
const String VERSION = "0.1.43";

// About panel: standard rows + the app's own. Collect when the panel opens (cheap, but not per frame).
const int ABOUT_MAX = 20;
char[40][ABOUT_MAX] about_keys;
char[512][ABOUT_MAX] about_values;
int about_count;

fn void about_add(String key, String value)
{
	if (about_count >= ABOUT_MAX) return;
	txt::set(&about_keys[about_count], key);
	txt::set(&about_values[about_count], value);
	about_count++;
}

extern fn sz about_readlink(ZString path, char* buf, usz size) @cname("readlink") @private @feat(LINUX);

<* Start the About rows: version, bmu version, display backend, GLFW, raylib, GPU, OpenGL, monitor, UI scale, binary. *>
fn void about_reset(String app, String version) => @pool()
{
	about_count = 0;
	about_add("Version", string::tformat("%s %s", app, version));
	about_add("bmu", VERSION);
	about_add("Display", string::tformat("%s (native)", backend()));
	about_add("GLFW", glfw_version());
	about_add("raylib", "6.0 (static, bundled with bmu)");
	about_add("GPU", gpu());
	about_add("OpenGL", gl_version());
	about_add("Monitor", string::tformat("%s · %d × %d @ %d Hz", rl::get_monitor_name(0).str_view(), rl::get_monitor_width(0), rl::get_monitor_height(0), rl::get_monitor_refresh_rate(0)));
	about_add("Interface", string::tformat("%d%% · display %d%%", (int)(scale * 100 + 0.5f), (int)(dpi * 100 + 0.5f)));
	$if env::LINUX:
		char[4096] exe;
		sz n = about_readlink("/proc/self/exe", &exe, exe.len - 1);
		about_add("Binary", n > 0 ? (String)exe[:(usz)n] : "unknown");
	$else
		about_add("Binary", std::os::env::executable_path() ?? "unknown");
	$endif
}

<* Key / value rows; long values show their end (paths). *>
fn void about_draw(Rect area)
{
	float key_w = 110;
	for (int i = 0; i < about_count; i++)
	{
		float row_y = area.y + 8 + (float)i * 34;
		if (row_y + 30 > area.y + area.height) break;
		text(txt::view(&about_keys[i]), area.x + 8, row_y + 8, 14, FG4);
		text_tail(txt::view(&about_values[i]), area.x + 8 + key_w, row_y + 7, area.width - key_w - 16, 15, FG);
	}
}
