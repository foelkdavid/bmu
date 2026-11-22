module gallery;
import std::math, std::core::string;
import raylib6::rl;
import gruvkit::ui, gruvkit::txt, gruvkit::sys, gruvkit::picker;

// Every gruvkit widget on one screen: buttons, icon buttons, inputs, checkboxes,
// dropdown, scrolling list, tiles, toast, tooltip, a modal dialog and the file picker.
//   c3c build example-gallery && ./build/example-gallery
//   ./build/example-gallery --shot out.png [--dialog | --picker]   (screenshot for checks)

// input ids: any int, unique per field on screen (picker uses 9000+)
const int ID_SEARCH = 1;
const int ID_PATH = 2;
const int ID_NOTE = 3;

// picker purposes: what the picker was opened for
const int PICK_FILE = 1;
const int PICK_DIR = 2;

char[128] search;
char[1024] path;
char[256] note;
bool opt_a = true;
bool opt_b;
int theme;
String[4] themes = { "Gruvbox dark", "Hard contrast", "Soft", "A rather long option name that will be cut off" };
String[3] image_filter = { ".png", ".jpg", ".qoi" };
float list_scroll;
int list_sel = -1;
bool dialog_open;

const String[*] ITEMS = {
	"Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot", "Golf", "Hotel", "India", "Juliett",
	"Kilo", "Lima", "Mike", "November", "Oscar", "Papa", "Quebec", "Romeo", "Sierra", "Tango",
};

fn void main(String[] args)
{
	ui::open("gruvkit gallery", 1100, 720, 900, 600);
	defer ui::close();
	ui::app_args(args);
	foreach (a : args)
	{
		if (a == "--dialog") dialog_open = true;
		if (a == "--picker") picker::start(PICK_FILE, FILE, "Pick an image", sys::home(), &image_filter);
	}
	picker::add_place(ui::I_IMAGE, "Pictures", txt::join(sys::home(), "Pictures"));
	picker::set_ext_icon(".png", ui::I_IMAGE);
	txt::set(&note, "Select me: Ctrl+A, Ctrl+Z, double-click a word");

	while (ui::running())
	{
		ui::frame_begin(dialog_open || picker::open);
		draw_main();
		ui::layer = 1;                       // modals: only layer 1 reacts while one is open
		if (dialog_open) draw_dialog();
		if (picker::open) picker::draw();
		ui::layer = 0;
		handle_pick();
		ui::frame_end();
	}
}

fn void draw_main() => @pool()
{
	float w = ui::sw();
	float h = ui::sh();
	// top bar
	ui::panel({ 0, 0, w, 64 }, ui::BG_HARD);
	ui::hline(0, 63, w, ui::BG1);
	ui::text(ui::I_STAR, 20, 20, 20, ui::YELLOW);
	ui::text("gallery", 52, 16, 24, ui::FG);
	ui::input(ID_SEARCH, { w - 340, 14, 320, 36 }, &search, "Filter list (Ctrl+F)", null, ui::I_SEARCH);
	if (ui::focus < 0 && ui::top == 0 && ui::ctrl_down() && ui::letter('f')) ui::focus_on(ID_SEARCH, &search);

	// left: scrolling, filterable list with tiles
	Rect list = { 0, 64, 300, h - 64 };
	ui::panel(list, ui::BG_HARD);
	float row = 52;
	int shown = 0;
	foreach (it : ITEMS) if (txt::icontains(it, txt::view(&search))) shown++;
	float content = (float)shown * row + 16;
	list_scroll = ui::scroll_wheel(list, list_scroll, content);
	ui::begin_clip(list);
	float y = list.y + 8 - list_scroll;
	foreach (i, it : ITEMS)
	{
		if (!txt::icontains(it, txt::view(&search))) continue;
		Rect r = { 8, y, list.width - 16, row - 4 };
		if ((int)i == list_sel) { ui::panel(r, ui::BG2, 6); } else if (ui::hover(r)) { ui::panel(r, ui::BG1, 6); }
		ui::tile({ r.x + 6, r.y + 6, 36, 36 }, null, it);
		ui::text_fit(it, r.x + 52, r.y + 14, r.width - 60, 16, ui::FG);
		if (ui::clicked(r)) list_sel = (int)i;
		y += row;
	}
	ui::end_clip();
	ui::scrollbar(list, list_scroll, content);

	// right: widgets
	float x = 330;
	y = 90;
	ui::text("Buttons", x, y, 18, ui::FG); y += 32;
	if (ui::button({ x, y, 130, 40 }, "Primary", PRIMARY, ui::I_PLAY)) ui::toast("Primary clicked");
	if (ui::button({ x + 140, y, 110, 40 }, "Good", GOOD, ui::I_CHECK)) ui::toast("Good clicked", ui::GREEN);
	if (ui::button({ x + 260, y, 110, 40 }, "Danger", DANGER, ui::I_TRASH)) ui::toast("Danger clicked", ui::RED);
	if (ui::button({ x + 380, y, 110, 40 }, "Normal")) ui::toast("Normal clicked");
	if (ui::button({ x + 500, y, 100, 40 }, "Ghost", GHOST)) ui::toast("Ghost clicked");
	ui::button({ x + 610, y, 110, 40 }, "Disabled", NORMAL, "", false);
	y += 52;
	if (ui::icon_button({ x, y, 40, 40 }, ui::I_GEAR, ui::FG4, "Open a dialog")) dialog_open = true;
	ui::icon_button({ x + 48, y, 40, 40 }, ui::I_REFRESH, ui::AQUA, "Icon button with a tooltip");
	ui::text("<- hover for tooltips", x + 100, y + 12, 14, ui::GRAY);
	y += 64;

	ui::text("Inputs", x, y, 18, ui::FG); y += 32;
	ui::label(x, y + 10, "Path");
	ui::input(ID_PATH, { x + 90, y, 420, 36 }, &path, "/some/file", null, ui::I_FOLDER);
	if (ui::icon_button({ x + 518, y, 38, 36 }, ui::I_FOLDER_OPEN, ui::FG4, "Browse for a file")) picker::start(PICK_FILE, FILE, "Pick an image", txt::view(&path), &image_filter);
	if (ui::icon_button({ x + 560, y, 38, 36 }, ui::I_HDD, ui::FG4, "Browse for a folder")) picker::start(PICK_DIR, DIR, "Pick a folder", txt::view(&path));
	y += 48;
	ui::label(x, y + 10, "Note");
	bool sent = false;
	if (ui::input(ID_NOTE, { x + 90, y, 508, 36 }, &note, "", &sent)) { /* changed this frame */ }
	if (sent) ui::toast(string::tformat("Enter: %s", txt::view(&note)));
	y += 64;

	ui::text("Options", x, y, 18, ui::FG); y += 32;
	ui::checkbox(x, y, "Option A", &opt_a, "Checkbox with a hint");
	ui::checkbox(x + 140, y, "Option B", &opt_b);
	ui::dropdown(10, { x + 280, y - 6, 320, 36 }, &themes, &theme);
	y += 48;
	ui::text(string::tformat("selected: %s · A=%s B=%s · UI scale %d%% (Ctrl +/-/0)", list_sel >= 0 ? ITEMS[list_sel] : "-",
		opt_a ? "on" : "off", opt_b ? "on" : "off", (int)(ui::scale * 100 + 0.5f)), x, y, 14, ui::GRAY);
	y += 30;
	ui::text_tail("/a/very/long/path/that/only/shows/its/end/because/text_tail/cuts/the/front.txt", x, y, 400, 14, ui::FG4);
}

fn void draw_dialog()
{
	Rect box = ui::dialog(560, 300);
	if (ui::dialog_header(box, ui::I_INFO, "A modal dialog") || (ui::live() && rl::is_key_pressed(rl::RLKeyboardKey.ESCAPE)))
	{
		dialog_open = false;
		return;
	}
	ui::text("Only layer 1 reacts while this is open.", box.x + 24, box.y + 80, 15, ui::FG4);
	ui::checkbox(box.x + 24, box.y + 120, "Option A (shared with the main view)", &opt_a);
	if (ui::button({ box.x + box.width - 140, box.y + box.height - 60, 120, 40 }, "Done", PRIMARY)) dialog_open = false;
}

fn void handle_pick()
{
	int why;
	String p;
	if (!picker::take(&why, &p)) return;
	txt::set(&path, p);
	ui::toast(why == PICK_DIR ? "Folder chosen" : "File chosen", ui::GREEN);
}
