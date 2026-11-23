# bmu cookbook

Working recipes. All code blocks on this page compile together as one program (`dev/tools/check-docs.sh`), and the
last recipe runs a small app that uses most of them: copy freely.

```c3
module cookbook;
import std::io, std::math, std::core::string, std::core::dstring;
import raylib6::rl;
import bmu::ui, bmu::txt, bmu::sys, bmu::picker, bmu::image;
```

## Labelled form fields with a Browse button

The standard settings row: caption left, field right, optional folder button that opens the picker.

```c3
const int PICK_FIELD_BASE = 100;   // picker purpose = PICK_FIELD_BASE + field id

// Returns true when the text changed (typed by the user).
fn bool form_field(float x, float* y, float w, String caption, int id, char[] buf, String placeholder, bool browse = false, picker::Mode mode = DIR)
{
	float lw = 150;
	ui::label(x, *y + 10, caption);
	float fw = w - lw - (browse ? 46 : 0);
	bool changed = ui::input(id, { x + lw, *y, fw, 36 }, buf, placeholder);
	if (browse && ui::icon_button({ x + lw + fw + 8, *y, 38, 36 }, ui::I_FOLDER_OPEN, ui::FG4, "Browse"))
	{
		picker::start(PICK_FIELD_BASE + id, mode, caption, txt::view(buf));
	}
	*y += 48;
	return changed;
}
```

## A filterable, scrollable, keyboard-driven list

```c3
const float LIST_ROW = 48;
float list_scroll;
int list_sel = -1;

// items: anything with a name; here plain strings. Returns the clicked index or -1.
fn int filtered_list(Rect area, String[] items, String filter)
{
	int clicked = -1;
	ui::panel(area, ui::BG_HARD);
	int shown = 0;
	foreach (it : items) if (txt::icontains(it, filter)) shown++;
	float content = (float)shown * LIST_ROW + 8;
	list_scroll = ui::scroll_wheel(area, list_scroll, content);
	ui::begin_clip(area);
	float y = area.y + 4 - list_scroll;
	foreach (i, it : items)
	{
		if (!txt::icontains(it, filter)) continue;
		Rect r = { area.x + 6, y, area.width - 12, LIST_ROW - 4 };
		y += LIST_ROW;
		if (r.y + r.height < area.y || r.y > area.y + area.height) continue;   // off-screen: skip drawing
		bool hov = ui::hover(r);
		if ((int)i == list_sel) { ui::panel(r, ui::BG2, 6); } else if (hov) { ui::panel(r, ui::BG1, 6); }
		if (hov) ui::cursor = POINTING_HAND;
		ui::tile({ r.x + 6, r.y + 6, 32, 32 }, null, it);
		ui::text_fit(it, r.x + 48, r.y + 13, r.width - 56, 15, ui::FG);
		if (ui::clicked(r)) { list_sel = (int)i; clicked = (int)i; }
		if (ui::right_clicked(r)) fruit_menu_open((int)i);
	}
	ui::end_clip();
	ui::scrollbar(area, list_scroll, content);

	// arrow keys when nobody is typing and no modal is open
	if (ui::focus < 0 && ui::top == 0)
	{
		int dir = ui::repeat(rl::RLKeyboardKey.DOWN) ? 1 : ui::repeat(rl::RLKeyboardKey.UP) ? -1 : 0;
		for (int i = list_sel + dir; dir != 0 && i >= 0 && i < items.len; i += dir)
		{
			if (!txt::icontains(items[i], filter)) continue;
			list_sel = i;
			// keep it visible (approximate: assumes no filter gaps above)
			float top = (float)i * LIST_ROW;
			if (top < list_scroll) list_scroll = top;
			if (top + LIST_ROW + 8 > list_scroll + area.height) list_scroll = top + LIST_ROW + 8 - area.height;
			break;
		}
	}
	return clicked;
}
```

## A modal dialog with Esc and a two-step delete

`ui::layer = 1` + `frame_begin(modal)` make it modal. The red button must be clicked twice within 3 s.

```c3
bool confirm_open;
double delete_armed;

// Returns true when the user confirmed the deletion.
fn bool confirm_dialog(String what) => @pool()
{
	Rect box = ui::dialog(480, 220);
	bool esc = ui::live() && rl::is_key_pressed(rl::RLKeyboardKey.ESCAPE);
	if (ui::dialog_header(box, ui::I_WARN, "Delete?") || esc) { confirm_open = false; return false; }
	ui::text_fit(string::tformat("\"%s\" will be removed.", what), box.x + 24, box.y + 72, box.width - 48, 15, ui::FG4);
	bool armed = ui::now - delete_armed < 3;
	float by = box.y + box.height - 60;
	if (ui::button({ box.x + box.width - 160, by, 140, 40 }, armed ? "Really?" : "Delete", DANGER, ui::I_TRASH))
	{
		if (armed) { confirm_open = false; delete_armed = 0; return true; }
		delete_armed = ui::now;
	}
	if (ui::button({ box.x + box.width - 270, by, 100, 40 }, "Cancel")) confirm_open = false;
	return false;
}
```

## A right-click menu

Open it on `right_clicked`, draw it after the rest of the window. It owns the input while open.

```c3
const int MENU_FRUIT = 1;
int menu_for = -1;                 // what the menu was opened for

fn void fruit_menu_open(int i) { menu_for = i; list_sel = i; ui::menu_open(MENU_FRUIT); }

// call after the window's widgets, before the modals
fn void fruit_menu(String[] items) => @pool()
{
	if (!ui::menu_begin(MENU_FRUIT)) return;
	String name = menu_for >= 0 ? items[menu_for] : "?";
	if (ui::menu_item(string::tformat("Eat %s", name), ui::I_PLAY, "Enter")) ui::toast(string::tformat("Ate %s", name));
	if (ui::menu_item("Copy name", ui::I_COPY, "Ctrl+C")) rl::set_clipboard_text(name.zstr_tcopy());
	ui::menu_item("Paste", ui::I_PASTE, "Ctrl+V", false);      // disabled
	ui::menu_sep();
	if (ui::menu_item("Delete…", ui::I_TRASH, "Del")) confirm_open = true;
	ui::menu_end();
}
```

## Tabs

Ghost buttons with an underline under the active one.

```c3
enum Tab { OVERVIEW, SETTINGS, LOG }
Tab tab = OVERVIEW;

fn void tabs(float x, float y, float w)
{
	String[3] names = { "Overview", "Settings", "Log" };
	String[3] icons = { ui::I_INFO, ui::I_WRENCH, ui::I_TERMINAL };
	ui::hline(x, y + 40, w, ui::BG1);                // under the whole row
	foreach (i, n : names)
	{
		float bw = ui::text_w(n, 15) + 56;
		Rect r = { x, y, bw, 40 };
		bool on = tab.ordinal == i;
		if (ui::button(r, n, GHOST, icons[i]) && !on) tab = (Tab)i;
		if (on) ui::panel({ r.x + 6, r.y + r.height - 3, r.width - 12, 3 }, ui::YELLOW, 1);
		x += bw + 6;
	}
}
```

## The file picker with several purposes

One picker, many buttons: the purpose int tells you which one opened it.

```c3
const int PICK_IMAGE = 1;
const int PICK_EXPORT_DIR = 2;
String[4] image_types = { ".png", ".jpg", ".jpeg", ".qoi" };   // global: must outlive the picker
char[1024] image_path;
char[1024] export_dir;

fn void open_image() => picker::start(PICK_IMAGE, FILE, "Open an image", txt::view(&picker::last_dir), &image_types);
fn void choose_export_dir() => picker::start(PICK_EXPORT_DIR, DIR, "Export to…", txt::view(&export_dir));

// once per frame, after picker::draw()
fn void handle_pick()
{
	int why;
	String path;
	if (!picker::take(&why, &path)) return;
	switch (why)
	{
		case PICK_IMAGE: txt::set(&image_path, path); ui::toast("Image chosen", ui::GREEN);
		case PICK_EXPORT_DIR: txt::set(&export_dir, path);
		default: if (why >= PICK_FIELD_BASE) { /* form_field browse: find the field by why - PICK_FIELD_BASE */ }
	}
}
```

App-specific places and icons, once after `ui::open`:

```c3
fn void setup_picker() => @pool()
{
	picker::add_place(ui::I_IMAGE, "Pictures", txt::join(sys::home(), "Pictures"));
	picker::set_ext_icon(".png", ui::I_IMAGE);
	picker::set_ext_icon(".jpg", ui::I_IMAGE);
}
```

## Settings file (key=value) in ~/.config

```c3
struct Settings
{
	char[1024] last_dir;
	float ui_scale;
	bool show_hidden;
}
Settings settings;

fn String config_path() => txt::join(sys::home(), ".config/my-app/settings.ini");   // temp

fn void settings_save() => @pool()
{
	DString s;
	s.tinit();
	s.appendf("last_dir=%s\n", txt::view(&settings.last_dir));
	s.appendf("ui_scale=%.2f\n", settings.ui_scale);
	s.appendf("show_hidden=%d\n", settings.show_hidden ? 1 : 0);
	sys::mkdirs(txt::dirname(config_path()));
	if (!sys::write_file(config_path(), s.str_view())) ui::toast("Could not save settings", ui::RED);
}

fn void settings_load() => @pool()
{
	String? data = sys::read_temp(config_path());
	if (catch data) return;          // first run
	foreach (line : data.tsplit("\n"))
	{
		sz? eq = line.index_of_char('=');
		if (catch eq) continue;
		String key = line[:(usz)eq].trim();
		String val = line[(usz)eq + 1..].trim();
		switch (key)
		{
			case "last_dir": txt::set(&settings.last_dir, val);
			case "ui_scale": settings.ui_scale = (float)val.to_double() ?? 0;
			case "show_hidden": settings.show_hidden = val == "1";
		}
	}
}
```

Use it: `settings_load(); ui::open("My App", 1000, 700, 700, 450, settings.ui_scale);` and in the loop
`if (ui::zoom_changed) { settings.ui_scale = ui::scale; settings_save(); }`.

## Debounced autosave

Save shortly after the user stops editing, not on every keystroke.

```c3
bool dirty;
double dirty_at;

fn void mark_dirty() { dirty = true; dirty_at = ui::now; }

fn void autosave()     // call every frame
{
	if (!dirty) return;
	bool idle = ui::now - dirty_at > 0.6 && ui::focus < 0;   // left the field
	if (idle || ui::now - dirty_at > 3) { settings_save(); dirty = false; }
}
```

## Keyboard shortcuts (keyboard-layout safe)

```c3
fn void shortcuts(char[] search_buf, int search_id)
{
	if (ui::top != 0) return;                                 // a modal is open
	if (ui::ctrl_down() && ui::letter('f')) { ui::focus_on(search_id, search_buf); return; }
	if (ui::ctrl_down() && ui::letter('o')) { open_image(); return; }
	if (ui::focus >= 0) return;                               // typing: no single-key shortcuts
	if (rl::is_key_pressed(rl::RLKeyboardKey.DELETE) && list_sel >= 0) confirm_open = true;
	if (rl::is_key_pressed(rl::RLKeyboardKey.F5)) ui::toast("Refreshed");
}
```

For independent content zoom, set `ui::zoom_shift_only = true;` after `open()`. Whole-UI zoom then uses
Ctrl+Shift +/-/0. In your frame loop (after `frame_begin`), handle plain Ctrl +/- using `ui::zoom_step()`:

```c3
// sketch: app state, persisted alongside ui::scale
float content_scale = 1;
fn void content_zoom()
{
	if (ui::top != 0 || ui::focus >= 0 || !ui::ctrl_down() || ui::shift_down()) return;
	content_scale = math::clamp(content_scale + (float)ui::zoom_step() * 0.1f, 0.5f, 2.5f);
	if (rl::is_key_pressed(rl::RLKeyboardKey.ZERO)) content_scale = 1;
}
```

Use `content_scale` only in your content layout (row height, text/icons, padding), not in the surrounding controls.

## Drag & drop files onto the window

```c3
fn void handle_drop()
{
	if (!rl::is_file_dropped()) return;
	rl::RLFilePathList files = rl::load_dropped_files();
	for (uint i = 0; i < files.count; i++)
	{
		String p = files.paths[i].str_view();
		if (sys::is_dir(p)) { txt::set(&export_dir, p); continue; }
		if (txt::iends_with(p, ".png") || txt::iends_with(p, ".jpg")) txt::set(&image_path, p);
	}
	rl::unload_dropped_files(files);
}
```

## Image tiles with a fallback

Load textures once (not every frame); `ui::tile` draws the letter tile while there is none.

```c3
rl::RLTexture2D preview;
char[1024] preview_of;

fn void draw_preview(Rect r) => @pool()
{
	String want = txt::view(&image_path);
	if (want != txt::view(&preview_of))                 // path changed: (re)load
	{
		if (preview.id) rl::unload_texture(preview);
		preview = {};
		if (sys::is_file(want)) preview = rl::load_texture(want.zstr_tcopy());
		if (preview.id) preview.set_filter(rl::RLTextureFilter.BILINEAR);
		txt::set(&preview_of, want);
	}
	ui::panel(r, ui::BG1, 8);
	ui::tile({ r.x + 4, r.y + 4, r.width - 8, r.height - 8 }, preview.id ? &preview : null, txt::basename(want));
}
```

## Async image preview

For interactive selection use a worker instead of the synchronous tile recipe above.
Request only when selection changes; poll in the frame loop, upload on the UI thread,
and close the loader before destroying its storage. Source/preview limits and blocking-close caveats: API.md.

```c3
image::Loader loader;
rl::RLTexture2D texture;

fn void select_image(String path)
{
	if (texture.id) rl::unload_texture(texture);
	texture = {};
	if (!loader.request(path)) return; // show an application error
}

fn void poll_image()
{
	image::Result result;
	if (!loader.take(&result)) return;
	if (result.status != READY) return; // show an application error
	defer rl::unload_image(result.pixels);
	texture = rl::load_texture_from_image(result.pixels);
}

fn void async_preview_example()
{
	rl::init_window(800, 600, "Async preview");
	defer rl::close_window();
	defer loader.close();
	defer { if (texture.id) rl::unload_texture(texture); }
	select_image("example.png");
	while (!rl::window_should_close())
	{
		poll_image();
		rl::begin_drawing();
		rl::clear_background(rl::BLACK);
		if (texture.id) rl::draw_texture(texture, 0, 0, rl::WHITE);
		rl::end_drawing();
	}
}
```

## A custom widget

Use `hover`/`clicked`, set the cursor, draw with `panel`/`text`. This one is a segmented toggle.

```c3
// Returns true when the choice changed.
fn bool segmented(Rect r, String[] options, int* sel)
{
	bool changed = false;
	ui::panel(r, ui::BG_HARD, 6);
	float w = r.width / options.len;
	foreach (i, o : options)
	{
		Rect s = { r.x + w * i + 3, r.y + 3, w - 6, r.height - 6 };
		bool on = *sel == (int)i;
		bool h = ui::hover(s);
		if (h) ui::cursor = POINTING_HAND;
		if (on || h) ui::panel(s, on ? ui::DIM_YELLOW : ui::BG1, 4);
		ui::text(o, s.x + (s.width - ui::text_w(o)) / 2, s.y + (s.height - 15) / 2 - 1, 15, on ? ui::BG_HARD : ui::FG4);
		if (ui::clicked(s) && !on) { *sel = (int)i; changed = true; }
	}
	return changed;
}
```

## Run a program and keep its output

`sys` exposes the libc calls. Fork, redirect stdout/stderr to a log, exec; poll with `WNOHANG`.

```c3
int child_pid;

fn bool run_logged(String[] argv, String log_path) => @pool()
{
	ZString[] args = mem::talloc_array(ZString, argv.len + 1);
	foreach (i, a : argv) args[i] = a.zstr_tcopy();
	args[argv.len] = null;
	ZString log = log_path.zstr_tcopy();
	CInt pid = sys::c_fork();
	if (pid < 0) return false;
	if (pid == 0)
	{
		sys::c_setsid();                                   // own process group: kill(-pid) stops all of it
		CInt fd = sys::c_open(log, sys::O_WRONLY | sys::O_CREAT | sys::O_TRUNC, 0o644);
		if (fd >= 0) { sys::c_dup2(fd, 1); sys::c_dup2(fd, 2); sys::c_close(fd); }
		sys::c_execvpe(args[0], args.ptr, sys::environ);
		sys::c_exit(127);
	}
	child_pid = pid;
	return true;
}

fn bool child_running()            // call every frame
{
	if (child_pid <= 0) return false;
	CInt status;
	if (sys::c_waitpid(child_pid, &status, sys::WNOHANG) == child_pid) { child_pid = 0; return false; }
	return true;
}

fn void child_stop() { if (child_pid > 0) sys::c_kill(-child_pid, sys::SIGTERM); }
```

Show the log: `ui::text(sys::read_tail(path, 4096), ...)` line by line inside a clipped, scrolled area.

## Putting it together

```c3
const int ID_SEARCH = 1;
const int ID_TITLE = 2;
const int ID_FOLDER = 3;
char[128] search;
char[256] title_buf;
char[1024] folder_buf;
String[6] fruits = { "Apple", "Banana", "Cherry", "Date", "Elderberry", "Fig" };
String[3] modes = { "List", "Grid", "Compact" };
int mode_sel;

fn void cookbook_example_main(String[] args)
{
	settings_load();
	ui::open("Cookbook", 1100, 720, 800, 500, settings.ui_scale);
	defer ui::close();
	ui::app_args(args);
	setup_picker();
	while (ui::running()) cookbook_frame();
	settings_save();
}

fn void cookbook_frame() => @pool()
{
	ui::frame_begin(confirm_open || picker::open);
	if (ui::zoom_changed) { settings.ui_scale = ui::scale; mark_dirty(); }
	shortcuts(&search, ID_SEARCH);
	if (ui::top == 0) handle_drop();
	float w = ui::sw();
	float h = ui::sh();

	ui::panel({ 0, 0, w, 60 }, ui::BG_HARD);
	ui::text("Cookbook", 20, 16, 24, ui::FG);
	ui::input(ID_SEARCH, { w - 340, 12, 320, 36 }, &search, "Search (Ctrl+F)", null, ui::I_SEARCH);

	filtered_list({ 0, 60, 280, h - 60 }, &fruits, txt::view(&search));

	float x = 310;
	float y = 80;
	tabs(x, y, w - x - 20);
	y += 60;
	switch (tab)
	{
		case OVERVIEW:
			draw_preview({ x, y, 160, 160 });
			if (ui::button({ x + 180, y, 160, 40 }, "Open image", PRIMARY, ui::I_IMAGE)) open_image();
			if (ui::button({ x + 180, y + 50, 160, 40 }, "Delete…", DANGER, ui::I_TRASH, list_sel >= 0)) confirm_open = true;
			if (ui::button({ x + 180, y + 100, 160, 40 }, child_running() ? "Running…" : "Run ls", NORMAL, ui::I_TERMINAL, !child_running()))
			{
				String[2] cmd = { "ls", "-la" };
				run_logged(&cmd, "/tmp/cookbook-ls.log");
			}
		case SETTINGS:
			if (form_field(x, &y, w - x - 40, "Title", ID_TITLE, &title_buf, "Untitled")) mark_dirty();
			form_field(x, &y, w - x - 40, "Folder", ID_FOLDER, &folder_buf, "~/", true);
			ui::label(x, y + 10, "View");
			segmented({ x + 150, y, 300, 36 }, &modes, &mode_sel);
			y += 48;
			if (ui::checkbox(x + 150, y, "Show hidden files", &settings.show_hidden)) mark_dirty();
		case LOG:
			ui::text(sys::read_tail("/tmp/cookbook-ls.log", 400), x, y, 13, ui::FG4);
	}

	fruit_menu(&fruits);
	ui::layer = 1;
	if (confirm_open && confirm_dialog(list_sel >= 0 ? fruits[list_sel] : "?")) ui::toast("Deleted (not really)", ui::RED);
	if (picker::open) picker::draw();
	ui::layer = 0;
	handle_pick();
	autosave();
	ui::frame_end();
}
```
