module gruvkit::picker;
import std::math, std::core::string;
import raylib6::rl;
import gruvkit::txt, gruvkit::sys, gruvkit::ui;

// gruvkit::picker - built-in modal file / folder chooser. No portals, no zenity, no GTK.
//   picker::start(MY_PURPOSE, FILE, "Open a file", start_dir, &filters);   // open it
//   if (picker::open) picker::draw();          // every frame, on ui layer 1 (modal)
//   if (picker::take(&why, &path)) { ... }     // once, when the user picked something
// The `purpose` int is yours: it tells you which button opened the picker.

enum Mode
{
	FILE,
	DIR,
}

const MAX_ENTRIES = 4096;
const int ID_PATH = 9001;

bool open;
Mode mode;
int purpose;          // caller-defined meaning of the result
char[256] title;
char[1024] dir;
char[1024] path_edit;
char[1024] result;
bool done;            // result ready (cleared by take())
sys::Entry[MAX_ENTRIES] entries;
int entry_count;
int[MAX_ENTRIES] visible;   // indices into entries after filtering
int visible_count;
int selected = -1;
float scroll;
bool show_hidden;
bool show_all;        // ignore the extension filter
String[8] exts;
usz ext_count;
double last_click;
int last_click_idx = -1;
char[1024] last_dir;  // folder of the last confirmed pick (persist it if you like)

// Sidebar places added by the app (shown between Downloads and /mnt).
struct Place
{
	char[64] name;
	char[1024] path;
	String icon;
}
const MAX_PLACES = 16;
Place[MAX_PLACES] place_list;
int place_count;

// Per-extension icons in the list (e.g. ".exe" -> ui::I_WINDOWS, drawn in AQUA).
struct ExtIcon
{
	char[16] ext;
	String icon;
}
ExtIcon[16] ext_icons;
int ext_icon_count;

<* Add a sidebar place. Folders that do not exist are hidden when drawing. *>
fn void add_place(String icon, String name, String path)
{
	if (place_count >= MAX_PLACES) return;
	Place* p = &place_list[place_count++];
	txt::set(&p.name, name);
	txt::set(&p.path, path);
	p.icon = icon;
}

fn void clear_places() => place_count = 0;

<* Show files ending in `ext` (case-insensitive, include the dot) with `icon`. *>
fn void set_ext_icon(String ext, String icon)
{
	for (int i = 0; i < ext_icon_count; i++)
	{
		if (txt::ieq(txt::view(&ext_icons[i].ext), ext)) { ext_icons[i].icon = icon; return; }
	}
	if (ext_icon_count >= ext_icons.len) return;
	txt::set(&ext_icons[ext_icon_count].ext, ext);
	ext_icons[ext_icon_count++].icon = icon;
}

fn String ext_icon(String name)
{
	for (int i = 0; i < ext_icon_count; i++)
	{
		if (txt::iends_with(name, txt::view(&ext_icons[i].ext))) return ext_icons[i].icon;
	}
	return "";
}

<*
 Open the picker. `why` is returned by take(). `filter` = extensions incl. the dot
 (".png"); empty = all files. The strings must outlive the picker (constants, globals).
 `~` is $HOME. A start_dir that does not exist walks up to the nearest existing folder, then $HOME.
*>
fn void start(int why, Mode m, String title_text, String start_dir, String[] filter = {}) => @pool()
{
	open = true;
	done = false;
	mode = m;
	purpose = why;
	txt::set(&title, title_text);
	ext_count = 0;
	foreach (e : filter) if (ext_count < exts.len) exts[ext_count++] = e;
	show_all = false;
	String d = start_dir;
	if (d.starts_with("~")) d = string::tformat("%s%s", sys::home(), d[1..]);
	while (d.len > 1 && !sys::is_dir(d)) d = txt::dirname(d);
	if (!sys::is_dir(d)) d = sys::home();
	navigate(d);
}

<*
 Fetch the result once. The path stays valid until the next pick.
 @return "true exactly once after the user confirmed a file/folder"
*>
fn bool take(int* why, String* path)
{
	if (!done) return false;
	done = false;
	*why = purpose;
	*path = txt::view(&result);
	return true;
}

fn void navigate(String d) => @pool()
{
	char[1024] real;
	sys::realpath(&real, d);
	txt::set(&dir, txt::view(&real));
	txt::set(&path_edit, txt::view(&dir));
	entry_count = sys::list_dir(txt::view(&dir), &entries, show_hidden);
	if (entry_count < 0) entry_count = 0;
	selected = -1;
	scroll = 0;
	refilter();
}

fn bool matches(sys::Entry* e)
{
	if (e.dir) return true;
	if (mode == DIR) return false;
	if (show_all || ext_count == 0) return true;
	String n = txt::view(&e.name);
	for (usz i = 0; i < ext_count; i++) if (txt::iends_with(n, exts[i])) return true;
	return false;
}

// Does the file name pass the extension filter (ignoring "All files")?
fn bool filtered(String name)
{
	if (ext_count == 0) return false;
	for (usz i = 0; i < ext_count; i++) if (txt::iends_with(name, exts[i])) return true;
	return false;
}

fn void refilter()
{
	visible_count = 0;
	for (int i = 0; i < entry_count; i++) if (matches(&entries[i])) visible[visible_count++] = i;
}

fn void finish(String path)
{
	txt::set(&result, path);
	done = true;
	open = false;
	ui::unfocus();
	txt::set(&last_dir, mode == DIR ? path : txt::dirname(path));
}

fn void cancel()
{
	open = false;
	ui::unfocus();
}

fn void activate(int vi) => @pool()
{
	sys::Entry* e = &entries[visible[vi]];
	String full = txt::join(txt::view(&dir), txt::view(&e.name));
	if (e.dir) { navigate(full); return; }
	finish(full);
}

fn void confirm() => @pool()
{
	if (selected >= 0 && selected < visible_count)
	{
		sys::Entry* e = &entries[visible[selected]];
		String full = txt::join(txt::view(&dir), txt::view(&e.name));
		if (mode == DIR || !e.dir) { finish(full); return; }
		navigate(full);
		return;
	}
	if (mode == DIR) finish(txt::view(&dir));
}

<* Draw the picker as a modal. Call every frame while `open`, with ui::layer = 1. *>
fn void draw()
{
	if (!open) return;
	Rect box = ui::dialog(1100, 720);
	float x = box.x + 20;
	float y = box.y + 16;
	if (ui::dialog_header(box, mode == DIR ? ui::I_FOLDER_OPEN : ui::I_FILE, txt::view(&title), "Cancel (Esc)")) { cancel(); return; }
	y += 40;

	// path bar
	if (ui::icon_button({ x, y, 36, 36 }, ui::I_UP, ui::FG4, "Parent folder (Backspace)")) navigate(txt::dirname(txt::view(&dir)));
	bool submitted = false;
	ui::input(ID_PATH, { x + 44, y, box.width - 84, 36 }, &path_edit, "/path/to/folder", &submitted, ui::I_FOLDER);
	if (submitted)
	{
		String p = txt::view(&path_edit).trim();
		if (p.starts_with("~")) p = string::tformat("%s%s", sys::home(), p[1..]);
		if (sys::is_dir(p)) { navigate(p); ui::unfocus(); }
		else if (mode == FILE && sys::is_file(p)) { finish(p); }
		else { ui::toast("Path does not exist", ui::RED); }
	}
	y += 50;

	// places sidebar
	float side = 210;
	float list_h = box.y + box.height - 70 - y;
	Rect places = { x, y, side, list_h };
	ui::panel(places, ui::BG_HARD, 6);
	float py = y + 10;
	ui::text("PLACES", x + 14, py, 12, ui::GRAY);
	py += 24;
	py = place(x, py, side, ui::I_HOME, "Home", sys::home());
	py = place(x, py, side, ui::I_FOLDER, "Downloads", txt::join(sys::home(), "Downloads"));
	for (int i = 0; i < place_count; i++) py = place(x, py, side, place_list[i].icon, txt::view(&place_list[i].name), txt::view(&place_list[i].path));
	py = place(x, py, side, ui::I_HDD, "/mnt", "/mnt");
	py = place(x, py, side, ui::I_HDD, "/run/media", "/run/media");
	py = place(x, py, side, ui::I_HDD, "File system", "/");

	// entry list
	Rect list = { x + side + 12, y, box.width - side - 52, list_h };
	ui::panel(list, ui::BG_HARD, 6);
	float row = 30;
	float content = (float)visible_count * row + 8;
	scroll = ui::scroll_wheel(list, scroll, content);
	ui::begin_clip(list);
	for (int i = 0; i < visible_count; i++)
	{
		float ry = list.y + 4 + (float)i * row - scroll;
		if (ry + row < list.y || ry > list.y + list.height) continue;
		Rect r = { list.x + 4, ry, list.width - 14, row };
		sys::Entry* e = &entries[visible[i]];
		String name = txt::view(&e.name);
		bool sel = i == selected;
		bool hov = ui::hover(r);
		if (sel) { ui::panel(r, ui::BG2, 4); } else if (hov) { ui::panel(r, ui::BG1, 4); }
		if (hov) ui::cursor = POINTING_HAND;
		String special = e.dir ? "" : ext_icon(name);
		bool wanted = !e.dir && filtered(name);
		String icon = e.dir ? ui::I_FOLDER : (special.len ? special : ui::I_FILE);
		ui::Color ic = e.dir ? ui::DIM_YELLOW : (special.len ? ui::AQUA : ui::GRAY);
		ui::text(icon, r.x + 10, r.y + 8, 14, ic);
		ui::text_fit(name, r.x + 36, r.y + 6, r.width - 46, 15, e.dir || wanted || special.len ? ui::FG : ui::FG4);
		if (ui::clicked(r))
		{
			if (last_click_idx == i && ui::now - last_click < 0.35) { activate(i); ui::consumed = true; break; }
			selected = i;
			last_click = ui::now;
			last_click_idx = i;
		}
	}
	if (visible_count == 0)
	{
		ui::text(mode == DIR ? "No sub-folders here" : "Nothing matching here", list.x + 20, list.y + 20, 15, ui::GRAY);
	}
	ui::end_clip();
	ui::scrollbar(list, scroll, content);

	// keyboard navigation (when the path field is not focused)
	if (!ui::focused(ID_PATH) && ui::top == ui::layer && !ui::popup_open)
	{
		if (ui::repeat(rl::RLKeyboardKey.DOWN) && visible_count > 0) { selected = selected + 1 < visible_count ? selected + 1 : visible_count - 1; keep_visible(list, row); }
		if (ui::repeat(rl::RLKeyboardKey.UP) && visible_count > 0) { selected = selected > 0 ? selected - 1 : 0; keep_visible(list, row); }
		if (rl::is_key_pressed(rl::RLKeyboardKey.ENTER))
		{
			if (selected >= 0) { activate(selected); } else { confirm(); }
		}
		if (rl::is_key_pressed(rl::RLKeyboardKey.BACKSPACE)) navigate(txt::dirname(txt::view(&dir)));
		if (rl::is_key_pressed(rl::RLKeyboardKey.ESCAPE)) { cancel(); return; }
	}
	if (!open) return;

	// footer
	float fy = box.y + box.height - 54;
	if (ui::checkbox(x, fy + 8, "Hidden files", &show_hidden)) navigate(txt::view(&dir));
	if (mode == FILE && ext_count > 0)
	{
		if (ui::checkbox(x + 150, fy + 8, "All files", &show_all)) refilter();
		@pool()
		{
			String f = "";
			for (usz i = 0; i < ext_count; i++) f = string::tformat("%s%s%s", f, i ? " " : "", exts[i]);
			ui::text(string::tformat("Filter: %s", f), x + 270, fy + 12, 14, ui::GRAY);
		};
	}
	float bx = box.x + box.width - 20;
	String ok = mode == DIR ? (selected >= 0 ? "Select folder" : "Use this folder") : "Select";
	bool can = mode == DIR || (selected >= 0 && !entries[visible[selected]].dir);
	if (ui::button({ bx - 160, fy, 160, 40 }, ok, PRIMARY, ui::I_CHECK, can)) confirm();
	if (ui::button({ bx - 270, fy, 100, 40 }, "Cancel", NORMAL)) cancel();
}

fn float place(float x, float y, float w, String icon, String name, String path)
{
	if (!sys::is_dir(path)) return y;
	Rect r = { x + 6, y, w - 12, 30 };
	bool here = txt::view(&dir) == path;
	if (here) ui::panel(r, ui::BG1, 4);
	if (ui::hover(r)) { ui::panel(r, ui::BG2, 4); ui::cursor = POINTING_HAND; }
	ui::text(icon, r.x + 10, r.y + 8, 14, here ? ui::YELLOW : ui::FG4);
	ui::text_fit(name, r.x + 36, r.y + 6, r.width - 44, 15, here ? ui::FG : ui::FG4);
	if (ui::clicked(r)) navigate(path);
	return y + 32;
}

fn void keep_visible(Rect list, float row)
{
	float top = (float)selected * row;
	if (top < scroll) scroll = top;
	if (top + row + 8 > scroll + list.height) scroll = top + row + 8 - list.height;
}
