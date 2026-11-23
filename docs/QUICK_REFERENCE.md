# bmu quick reference (one page)

The whole API and the rules on one page. Give this file (plus COOKBOOK.md) to an assistant writing a bmu app.
Language: **C3** 0.8.x. Modules: `bmu::ui`, `bmu::txt`, `bmu::sys`, `bmu::picker`, `bmu::image`, `bmu::fileop`, `bmu::find`; raylib is `rl::`.
Details: [API.md](API.md). Why things work the way they do: [CONCEPTS.md](CONCEPTS.md).

## Hard rules

1. Imports: `import std::math; import raylib6::rl; import bmu::ui, bmu::txt;` (+ `bmu::sys`,
   `bmu::picker` when used). `std::math` is needed to name the `Rect` type (`Rect box = ...`).
   Calls always carry the short module prefix: `ui::button`, `txt::view`, `sys::is_dir`, `picker::start`, `rl::...`.
2. **Immediate mode**: there are no widget objects. Call the widget every frame; it draws and returns what happened
   (`if (ui::button(...)) ...`). A widget you stop calling is gone.
3. **Logical pixels**: every coordinate is in logical px. Window size = `ui::sw()` x `ui::sh()`, never
   `rl::get_screen_width()`. The UI scale (Ctrl +/-/0) is applied for you.
4. **Editable text = fixed `char[N]` buffers** (globals or struct fields that live as long as the field is shown),
   passed as `&buf`. Read with `txt::view(&buf)`, write with `txt::set(&buf, s)`. Never pass a `String`.
5. **Ids**: each `ui::input` and `ui::dropdown` on screen needs a unique `int` id (constants). `picker` uses 9000+.
6. **Layers**: normal UI on layer 0. Modals: `ui::frame_begin(modal_open)`, then `ui::layer = 1;` before drawing the
   modal and `ui::layer = 0;` after. Only widgets on the active layer react to the mouse/keyboard.
7. Strings from `string::tformat`, `txt::join` are temp memory: use them inside `@pool()` (functions marked
   `=> @pool()` or an `@pool() { ... };` block). The frame loop is not pooled for you.
8. Letter shortcuts: `ui::ctrl_down() && ui::letter('f')`, not `rl::KeyboardKey.F` (keyboard-layout safe).
   Guard global shortcuts with `ui::focus < 0 && ui::top == 0` so they don't fire while typing or in a modal.
9. Icons are strings (`ui::I_PLAY`...) drawn with the embedded Nerd Font. Other glyphs must be added via
   `ui::load_font(extra)` before they render (see API §2).
10. Check visually: `./build/app --shot out.png` (any app using `ui::app_args(args)`), then look at the PNG.

## Skeleton

```c3
module quickref_app;
import std::math;
import raylib6::rl;
import bmu::ui, bmu::txt, bmu::picker;

const int ID_NAME = 1;
const int PICK_FILE = 1;
char[256] name;
char[1024] file;
bool about_open;

fn void main(String[] args)
{
	ui::open("My App", 900, 600);      // window, scale, font, keyboard layout
	defer ui::close();
	ui::app_args(args);                 // --shot FILE / --frames N / --scale S
	while (ui::running())
	{
		ui::frame_begin(about_open || picker::open);
		ui::text("My App", 20, 20, 24, ui::YELLOW);
		ui::input(ID_NAME, { 20, 70, 300, 36 }, &name, "Name");
		if (ui::button({ 20, 120, 160, 40 }, "Open file", PRIMARY, ui::I_FOLDER_OPEN)) picker::start(PICK_FILE, FILE, "Open", "~");
		if (ui::icon_button({ ui::sw() - 50, 14, 36, 36 }, ui::I_INFO, ui::FG4, "About")) about_open = true;
		ui::text_tail(txt::view(&file), 20, 180, 400, 14, ui::GRAY);

		ui::layer = 1;
		if (about_open)
		{
			Rect box = ui::dialog(420, 200);
			if (ui::dialog_header(box, ui::I_INFO, "About")) about_open = false;
		}
		if (picker::open) picker::draw();
		ui::layer = 0;

		int why;
		String path;
		if (picker::take(&why, &path)) txt::set(&file, path);
		ui::frame_end();
	}
}
```

## Everything, by module

| call | does |
|---|---|
| **app** (`ui::`) | |
| `open(title, w=1280, h=800, min_w=800, min_h=500, ui_scale=0)` | window (logical size), scale (0 = auto), font, layout map, 60 FPS, Esc doesn't quit |
| `app_args(args)` | `--shot FILE` (PNG after `--frames N`=3, then exit), `--scale S` |
| `running()` / `quit = true` | loop condition / leave the loop |
| `hold_close`, `close_requested` | close button asks the app instead of quitting (confirm while busy) |
| `frame_begin(modal=false)` / `frame_end()` | start (input, zoom keys, clear, 2D zoom) / finish (popup, tooltip, toast, present) |
| `zoom_shift_only`, `zoom_step()` | require Shift for built-in UI zoom; layout-aware +/- presses for custom content zoom |
| `zoom(s)`, `zoom_changed`, `zoom_toast`, `clear_color`, `close()` | scale like Ctrl +/-; "changed this frame" flag; toast on/off; background; shutdown |
| **layout & state** (`ui::`) | |
| `sw()`, `sh()` | window size in logical px |
| `scale`, `set_scale(s)`, `auto_scale()` | logical→physical (0.75..3); 1.0 ≤1440p, 1.5 at 4K |
| `layer`, `top`, `live()` | layer being drawn; layer that gets input; "may this widget react now" |
| `now`, `consumed`, `cursor` | `rl::get_time()` at frame start; a click was used; mouse cursor to show |
| **drawing** (`ui::`) | |
| `text(s, x, y, size=15, color=FG)`, `text_w(s, size=15)` | draw / measure (UTF-8) |
| `text_fit(s, x, y, w, size, color)` / `text_tail(...)` | cut the end with … / show only the end (paths) |
| `label(x, y, s)` | 14 px FG4 caption |
| `panel(r, color, round=0)`, `outline(r, color, round=0, thick=1)`, `hline(x, y, w, color=BG1)` | rectangles (round = corner radius in px) |
| `begin_clip(r)` / `end_clip()` | scissor + restrict hover to `r` (scroll areas) |
| `tile(r, tex*, name)` | texture fit into `r`, or a coloured letter tile when `tex` is null |
| `dialog(w, h) -> Rect`, `dialog_header(box, icon, title) -> bool` | modal frame (dims screen) / title + X (true = close) |
| **widgets** (`ui::`) | |
| `button(r, label, style=NORMAL, icon="", enabled=true) -> bool` | styles `NORMAL PRIMARY GOOD DANGER GHOST`; true on click |
| `icon_button(r, icon, color=FG4, tip="") -> bool` | square icon, hover background, tooltip |
| `checkbox(x, y, label, &flag, hint="") -> bool` | toggles `flag`; true when toggled; 24 px tall |
| `input(id, r, &buf, placeholder="", &submitted=null, icon="") -> bool` | one-line editor; true when text changed; `submitted` set on Enter |
| `dropdown(id, r, items, &sel) -> bool` | `String[] items`, `int sel`; true the frame after a choice |
| `menu_open(id, x=-1, y=-1)`; `if (menu_begin(id, w=240)) { menu_item(label, icon="", keys="", enabled=true) -> bool; menu_sep(); menu_end(); }` | right-click menu; draw it after the other widgets; owns input while open |
| `scroll_wheel(area, scroll, content) -> float`, `scrollbar(area, scroll, content)` | wheel scrolling (clamped) / thin bar |
| `hover(r)`, `clicked(r)`, `right_clicked(r)` | build your own widgets |
| `tooltip(s)`, `toast(s, color=AQUA)` | hover text this frame / 3.5 s notification bottom-right |
| `focus`, `focused(id)`, `focus_on(id, &buf)`, `unfocus()` | text focus (−1 = none); focus_on selects all |
| `letter('f')`, `ctrl_down()`, `shift_down()`, `repeat(key)` | layout-safe letter press; modifiers; press + auto-repeat |
| `load_font(extra={})`, `map_layout()` | done by `open()`; fonts use cached native-pixel atlases (first use of a size bakes it); reload to add glyphs |
| **colours / icons** | `BG_HARD BG BG1 BG2 BG3 BG4 FG FG4 GRAY RED GREEN YELLOW BLUE PURPLE AQUA ORANGE DIM_RED DIM_GREEN DIM_YELLOW`; `I_PLAY I_STOP I_PLUS I_FOLDER I_FOLDER_OPEN I_FILE I_GEAR I_SEARCH I_TRASH I_UP I_HOME I_HDD I_GAMEPAD I_WINDOWS I_CLOCK I_CHECK I_TIMES I_DOWN I_RIGHT I_REFRESH I_TERMINAL I_IMAGE I_WRENCH I_STEAM I_BOLT I_WARN I_INFO I_LIST I_EYE I_STAR I_EYE_OFF I_MENU I_COPY I_CUT I_PASTE I_EDIT I_BACK I_FORWARD I_LEFT I_GRID I_BOOKMARK I_LINK I_LOCK I_EXTERNAL I_UNDO I_SORT_UP I_SORT_DOWN I_DESKTOP I_DOWNLOAD I_MUSIC I_VIDEO I_FILE_TEXT I_FILE_IMAGE I_FILE_AUDIO I_FILE_VIDEO I_FILE_ARCHIVE I_FILE_CODE I_FILE_PDF` |
| **picker** (`picker::`) | |
| `start(why, FILE\|DIR, title, start_dir, filter={})` | open; `filter` = `String[]` like `{ ".png", ".jpg" }` |
| `open`, `draw()` | is it showing / draw it on layer 1 |
| `take(&why, &path) -> bool` | true once after a pick; `why` = your purpose constant |
| `last_dir`, `add_place(icon, name, path)`, `clear_places()`, `set_ext_icon(ext, icon)` | last folder used; sidebar entries; per-extension list icon |
| **image** (`image::`) | |
| `Loader.request(path)`, `.take(&result)`, `.cancel()`, `.close()` | bounded lazy CPU worker; latest selection wins; `READY` transfers `Result.pixels` (caller unloads); original `width`/`height`; upload on UI thread only; see API limits |
| **fileop** (`fileop::`) | |
| `Job.start(kind, src_dir, names, dst_dir, permanent_fallback)`, `.status(&p)`, `.answer(a, all)`, `.cancel()`, `.finished(&p)`, `.close()` | background `COPY MOVE TRASH DELETE` (+ `COUNT` for sizes, `RESTORE` from the trash); progress, conflicts (`REPLACE SKIP KEEP_BOTH`), all-or-nothing cancel; `can_trash(path)`, `trash_dir(&out)`, `trash_info(files_dir, name, &path, &date)` |
| **find** (`find::`) | |
| `Finder.start(root, query, hidden)`, `.results()`, `.rel(i)` `.name(i)` `.folder(i)` `.is_dir(i)`, `.searching()`, `.limited()`, `.close()` | background recursive name search, breadth-first, same filesystem, append-only hits |
| **txt** (`txt::`) — `char[]` buffers | |
| `view(&b) -> String`, `set(&b, s)`, `append(&b, s)`, `empty(&b)`, `z(&b) -> ZString` | read / write (truncates) / append / is empty / C string |
| `ieq`, `icontains`, `istarts_with`, `iends_with`, `icmp`, `natcmp`, `lower(c)` | case-insensitive tests, sort orders ("v9" < "v10") |
| `basename`, `dirname`, `strip_ext`, `join(a, b)` (temp), `zjoin` (temp) | path helpers |
| `pretty_name(&out, raw)`, `slug(&out, name, fallback="item")` | "Some_Name.exe"→"Some Name"; "Some Name!"→"some-name" |
| **sys** (`sys::`) — Linux | |
| `exists`, `is_dir`, `is_file`, `is_exec`, `mkdirs`, `move`, `realpath(&out, p)` | file system |
| `home()`, `env(name)`, `now()` (unix seconds) | environment |
| `list_dir(dir, Entry[] out, hidden) -> int` | dirs first, sorted; −1 = can't open; `Entry.name` (`char[256]`), `Entry.dir` |
| `read_temp(path) -> String?`, `read_tail(path, max)`, `write_file(path, data) -> bool` | whole file (temp) / last bytes / write |
| `c_fork c_execvpe c_waitpid c_kill c_setsid c_dup2 c_open c_close c_usleep ...` | raw libc for process control |

## C3 reminders

- `if (a) { x(); } else { y(); }`: with an `else`, both branches need braces.
- Float literals `0.5f`; convert with `(float)i`, `(int)f`.
- `Rect` is `{ x, y, width, height }` (floats); write literals as `{ 20, 70, 300, 36 }`.
- Default arguments can be skipped from the end only; named: `ui::button(r, "Go", style: PRIMARY)` also works.
- Enum values passed to a parameter of that enum type need no prefix: `PRIMARY`, `FILE`, `DIR`.
