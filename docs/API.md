# bmu API reference

Every public call, grouped by topic. Each entry: signature, what it does, gotchas.
New here? Read [GETTING_STARTED.md](GETTING_STARTED.md), keep [QUICK_REFERENCE.md](QUICK_REFERENCE.md) open.

**Conventions on this page**

- Module prefixes are always written: `ui::`, `txt::`, `sys::`, `picker::`, `rl::` (raylib 6 binding).
- Coordinates and sizes are **logical pixels** (see [CONCEPTS.md](CONCEPTS.md#logical-pixels)); `Rect` is C3's
  `std::math` rectangle `{ x, y, width, height }` (floats).
- `char[] buf` parameters take a fixed buffer by address: `&my_buf` where `char[256] my_buf;`.
- "temp" = allocated in C3's temp allocator; valid until the enclosing `@pool()` ends.
- Source of truth: `lib/bmu.c3l/src/` (`app.c3`, `ui.c3`, `picker.c3`, `txt.c3`, `sys.c3`). Names in those files that
  are not listed here are internal (they are visible, but may change).

Contents

1. [App and frame loop](#1-app-and-frame-loop)
2. [Font, text and icons](#2-font-text-and-icons)
3. [Colours](#3-colours)
4. [Layout, scale and input state](#4-layout-scale-and-input-state)
5. [Drawing helpers](#5-drawing-helpers)
6. [Buttons and checkboxes](#6-buttons-and-checkboxes)
7. [Text input](#7-text-input)
8. [Dropdown and context menu](#8-dropdown-and-context-menu)
9. [Scrolling](#9-scrolling)
10. [Tooltips and toasts](#10-tooltips-and-toasts)
11. [Dialogs](#11-dialogs)
12. [Keyboard](#12-keyboard)
13. [File picker (picker::)](#13-file-picker-picker)
14. [Text buffers and strings (txt::)](#14-text-buffers-and-strings-txt)
15. [Files and system (sys::)](#15-files-and-system-sys)
16. [Limits](#16-limits)
17. [Low level: without the app layer](#17-low-level-without-the-app-layer)

---

## 1. App and frame loop

`app.c3`, module `bmu::ui`. Optional, but use it: it does window setup, the UI zoom keys and `--shot`.

```c3
module api_loop;
import bmu::ui;

fn void main(String[] args)
{
	ui::open("My App", 1000, 640, 700, 420);   // logical size, logical minimum size
	defer ui::close();
	ui::app_args(args);
	while (ui::running())
	{
		ui::frame_begin();          // modal? pass true while a modal is open
		ui::text("hi", 20, 20);
		ui::frame_end();
	}
}
```

| | |
|---|---|
| `fn void open(String title, int w = 1280, int h = 800, int min_w = 800, int min_h = 500, float ui_scale = 0)` | Resizable window (MSAA 4x; 60 FPS paced by sleeping, no vsync: on Wayland the first synced swap stalls ~0.5 s), size `w x h` **logical** px times the scale, clamped to 90% of the monitor; min size likewise. `ui_scale > 0` sets the scale (e.g. a saved one), else `auto_scale()`. Loads the font, maps the keyboard layout, 60 FPS, `Esc` does **not** close the window, raylib log level WARNING. |
| `fn void app_args(String[] args)` | Reads `--shot FILE` (save a PNG of the window after `--frames N` frames, default 3, and once the window size has been stable for 5 frames, so a tiling WM's resize is not caught; then `running()` returns false), `--scale S`. Ignores every other argument: parse your own afterwards (skip `--x value` pairs). |
| `fn bool running()` | `false` when the window is closed, `quit` was set, or the `--shot` was taken. |
| `bool quit` | Set to `true` to end the loop (e.g. a Quit button). |
| `bool hold_close = false` | Set true while closing must be confirmed (e.g. a file copy runs): the window's close button then sets `close_requested` instead of ending the loop. |
| `bool close_requested` | Set by `running()` when the user tried to close under `hold_close`. Show your question, clear it, and set `quit = true` to really close. |
| `fn void frame_begin(bool modal = false)` | Resets per-frame input state, handles **Ctrl + / Ctrl − / Ctrl 0** (zoom, auto), sets `top` = `modal ? 1 : 0` (unless a dropdown is open), `begin_drawing`, clears to `clear_color`, starts the 2D zoom, `layer = 0`. |
| `fn void frame_end()` | Draws the open dropdown popup, the tooltip and the toast **on top of everything**, sets the mouse cursor, ends drawing, handles `--shot`. |
| `bool zoom_shift_only = false` | Set true to use Ctrl+Shift +/-/0 for whole-UI zoom, reserving plain Ctrl +/-/0 for app-specific content zoom. |
| `fn int zoom_step()` | Layout-aware +/- key presses (including keypad), returns −1, 0, or +1; caller supplies modifiers and step size. `map_layout()` maps symbol keys as well as letters. |
| `fn void zoom(float s)` | Set the scale like the keys do: clamps; on a real scale change, updates min window size, sets `zoom_changed`, and toasts "UI scale N%" if `zoom_toast`. |
| `bool zoom_changed` | True for the frame in which the user zoomed. Persist `ui::scale` then. |
| `bool zoom_toast = true` | Show the "UI scale" toast. |
| `Color clear_color = BG` | Background colour. |
| `fn void fit_window(bool resize)` | Re-apply the min size for the current scale; `resize` also resets the window size. |
| `fn void close()` | Unload the font, close the window. |
| `fn String backend()`, `glfw_version()`, `gpu()`, `gl_version()` | Runtime facts for an About page or bug report: windowing backend ("Wayland"), GLFW version string, GPU/driver (GL_RENDERER), OpenGL version. After `open()`, UI thread; cheap, but call on demand, not per frame. |

Gotchas
- Call all widgets between `frame_begin` and `frame_end`. Drawing raw raylib (`rl::draw_*`) there is fine; it is
  zoomed like everything else, so use logical coordinates.
- A modal you draw must be on layer 1 **and** you must pass `modal = true` the same frame, or layer 0 keeps reacting.
- The loop is not inside `@pool()`. Temp strings work anyway but pile up until exit: put per-frame code in
  functions declared `=> @pool()` or wrap the body in `@pool() { ... };`.

## 2. Font, text and icons

The font is CodeNewRoman Nerd Font Propo (`lib/bmu.c3l/assets/ui.otf`, SIL OFL), `$embed`ded into the binary and
rasterized at the displayed physical pixel size, without mipmap downsampling. Text origins and sizes round to
physical pixels (including fractional UI zoom); drawing and measurement use the same atlas. Up to 32 additional
sizes are cached with LRU eviction, alongside the default body-size atlas. A new size is baked on its first
measurement/draw from the embedded bytes; cache hits do not rasterize or allocate atlases. Applications with many
sizes should avoid cycling through more than 32 distinct physical sizes per frame. Rasterization is synchronous
on a cache miss (including first use after zoom). Above 192 physical px, the 192 px atlas is scaled up, preserving
the requested display size.

| | |
|---|---|
| `fn void text(String s, float x, float y, float size = 15, Color color = FG)` | Draw UTF-8 text; (x, y) = top-left. Common sizes: 13 status, 14 labels, 15 body, 18–20 headings, 24+ titles. |
| `fn float text_w(String s, float size = 15)` | Width in logical px. |
| `fn void text_fit(String s, float x, float y, float w, float size = 15, Color color = FG)` | Like `text`, cut to width `w` with a trailing `…` (UTF-8 safe). |
| `fn void text_tail(String s, float x, float y, float w, float size = 15, Color color = FG)` | Shows only the end, prefixed with `…` (for paths). |
| `fn void label(float x, float y, String s)` | 14 px, `FG4`: the caption left of a field. |
| `fn void load_font(int[] extra = {})` | Reset the atlas cache and bake the default body-size font; other sizes bake on first use. Codepoints included: ASCII 32–126, Latin-1 160–255, the `I_*` icons, `•` `—` `…` `·`, and `extra`. **A glyph not baked shows as `?`.** `open()` calls it with no extras; to add glyphs call `ui::unload_font(); ui::load_font(&my_codepoints);` after `open()`. |
| `fn void unload_font()` | Free all cached atlases (safe to call again). `bool has_font` tells whether it loaded (else raylib's default font is used). |

Icons (Nerd Font / Font Awesome codepoints, all `String` constants):

| | | | |
|---|---|---|---|
| `I_PLAY`  | `I_STOP` | `I_PLUS` | `I_FOLDER` |
| `I_FOLDER_OPEN` | `I_FILE` | `I_GEAR` | `I_SEARCH` |
| `I_TRASH` | `I_UP` | `I_HOME` | `I_HDD` |
| `I_GAMEPAD` | `I_WINDOWS` | `I_CLOCK` | `I_CHECK` |
| `I_TIMES` (×) | `I_DOWN` (chevron) | `I_RIGHT` (chevron) | `I_REFRESH` |
| `I_TERMINAL` | `I_IMAGE` | `I_WRENCH` | `I_STEAM` |
| `I_BOLT` | `I_WARN` | `I_INFO` | `I_LIST` |
| `I_EYE` | `I_STAR` | `I_EYE_OFF` | `I_MENU` (≡) |
| `I_COPY` | `I_CUT` | `I_PASTE` | `I_EDIT` (pencil) |
| `I_BACK` (←) | `I_FORWARD` (→) | `I_LEFT` (chevron) | `I_GRID` |
| `I_BOOKMARK` | `I_LINK` | `I_LOCK` | `I_EXTERNAL` |
| `I_UNDO` | `I_SORT_UP` | `I_SORT_DOWN` | `I_DESKTOP` |
| `I_DOWNLOAD` | `I_MUSIC` | `I_VIDEO` | `I_FILE_TEXT` |
| `I_FILE_IMAGE` | `I_FILE_AUDIO` | `I_FILE_VIDEO` | `I_FILE_ARCHIVE` |
| `I_FILE_CODE` | `I_FILE_PDF` | | |

To add one: find its codepoint (e.g. on nerdfonts.com/cheat-sheet), add the `String` constant (`"\uF0C7"`: C3 escapes are `\uXXXX`, not `\u{...}`) and pass
the codepoint to `load_font`. To add it to the library, append to `ICON_CODEPOINTS` and the `I_*` list in `ui.c3`.

## 3. Colours

`alias Color = rl::RLColor` (`{ r, g, b, a }` chars). Gruvbox dark:

| constant | hex | use |
|---|---|---|
| `BG_HARD` | #1d2021 | bars, sidebars, input fields, list backgrounds |
| `BG` | #282828 | window background, dialogs |
| `BG1` | #3c3836 | normal button, hover row, separators |
| `BG2` | #504945 | hovered button, selected row, dialog outline |
| `BG3` | #665c54 | disabled text, scrollbar, popup outline |
| `BG4` | #7c6f64 | placeholder text |
| `FG` | #ebdbb2 | text |
| `FG4` | #a89984 | secondary text, labels, idle icons |
| `GRAY` | #928374 | hints, status text |
| `RED` `GREEN` `YELLOW` `BLUE` `PURPLE` `AQUA` `ORANGE` | bright accents | errors, success, highlight, info |
| `DIM_RED` `DIM_GREEN` `DIM_YELLOW` | #cc241d #98971a #d79921 | idle state of DANGER/GOOD/PRIMARY buttons, focus ring |

Transparent variants: `{ ui::AQUA.r, ui::AQUA.g, ui::AQUA.b, 70 }`.

## 4. Layout, scale and input state

| | |
|---|---|
| `fn float sw()`, `fn float sh()` | Window width/height in logical px. Lay out relative to these each frame (resizable window). |
| `float scale` | Logical → physical factor, 0.75 … 3. |
| `fn void set_scale(float s)` | Clamp and apply (also mouse scaling). Prefer `zoom()` inside the loop. |
| `fn float auto_scale()` | 1.0 up to 1440p monitor height, steps of 0.25 above (2160p → 1.5), max 2.5. |
| `int layer` | The layer you are drawing (set it: 0 normal, 1 modal). |
| `int top` | The layer that receives input this frame (set by `frame_begin`; 99 while a dropdown is open). |
| `fn bool live()` | `layer == top && !consumed`: may a widget react now? Use for your own key handling inside modals. |
| `bool consumed` | A click was already used this frame (later widgets ignore it). Set it when your own code eats a click. |
| `bool popup_open` | A dropdown list is open (it owns input). |
| `double now` | `rl::get_time()` at frame start (seconds). |
| `rl::RLMouseCursor cursor` | Cursor applied at `frame_end`: set `ui::cursor = POINTING_HAND` / `IBEAM` on hover in custom widgets. |
| `Rect clip` | Current clip rect (from `begin_clip`). |

## 5. Drawing helpers

| | |
|---|---|
| `fn void panel(Rect r, Color c, float round = 0)` | Filled rect; `round` = corner radius in px (5 buttons, 6 lists, 10 dialogs). |
| `fn void outline(Rect r, Color c, float round = 0, float thick = 1)` | Border. |
| `fn void hline(float x, float y, float w, Color c = BG1)` | 1 px separator. |
| `fn void begin_clip(Rect r)` / `fn void end_clip()` | Scissor to `r` **and** make hover/click ignore points outside it. Required around scrolled content. Not nestable (one clip at a time; `input` restores it). |
| `fn void scissor(int x, int y, int w, int h)` | Raw scissor in logical px (use instead of `rl::begin_scissor_mode`, which wants physical px). |
| `fn void tile(Rect r, rl::RLTexture2D* tex, String name)` | Draw `tex` fit into `r` keeping aspect; `null` → rounded tile with `name`'s first letter, colour picked by a hash of `name` (stable per name). |

## 6. Buttons and checkboxes

```c3
// sketch
if (ui::button({ x, y, 140, 40 }, "Save", PRIMARY, ui::I_CHECK)) save();
if (ui::button({ x, y, 140, 40 }, "Delete", DANGER, ui::I_TRASH, has_selection)) delete();
if (ui::icon_button({ x, y, 36, 36 }, ui::I_GEAR, ui::FG4, "Settings")) settings_open = true;
ui::checkbox(x, y, "Show hidden", &show_hidden, "Also list dot-files");
```

| | |
|---|---|
| `enum Style { NORMAL, PRIMARY, GOOD, DANGER, GHOST }` | NORMAL grey; PRIMARY yellow (one per view); GOOD green; DANGER red; GHOST transparent until hovered (tabs, toolbars). |
| `fn bool button(Rect r, String label, Style style = NORMAL, String icon = "", bool enabled = true)` | True on the click frame. Label and icon centred; text is 20 px when `r.height >= 44`, else 15. Disabled: greyed, never true. Label `""` + icon = icon-only button with a background. Heights: 36–40 normal, 44+ big. |
| `fn bool icon_button(Rect r, String icon, Color color = FG4, String tip = "")` | Icon at half the rect height, hover background + tooltip. |
| `fn bool checkbox(float x, float y, String label, bool* v, String hint = "")` | 24 px tall row (box + label); toggles `*v`, true when toggled. `hint` = tooltip. |

## 7. Text input

```c3
// sketch
const int ID_NAME = 1;
char[128] name;
bool enter;
if (ui::input(ID_NAME, { x, y, 320, 36 }, &name, "Name", &enter, ui::I_SEARCH)) changed = true;
if (enter) submit();
```

`fn bool input(int id, Rect r, char[] buf, String placeholder = "", bool* submitted = null, String icon = "")`

- Returns true in every frame the content changed. `*submitted` is set to true when Enter/keypad Enter is pressed
  (initialise your bool to false each frame). `icon` is drawn at the left in GRAY.
- `buf` is edited in place and stays NUL-terminated. Max length = `buf.len - 1` bytes; extra typing is dropped.
- Behaviour: click focuses + places the caret, drag selects, double-click selects a word, triple-click all,
  Shift+click extends. Keys: ←/→ (Ctrl = by word), Home/↑ start, End/↓ end, Shift extends, Backspace/Delete
  (Ctrl = word), Ctrl+A/C/X/V, Shift+Insert paste, Ctrl+Z undo, Ctrl+Y or Ctrl+Shift+Z redo, Ctrl+U clear,
  Esc drops the selection, a second Esc unfocuses. Pasted newlines/tabs are dropped. Clicking elsewhere unfocuses.
- Word separators: space `/ _ - . =`.
- Unfocused long values show their **end** (paths); focused, the view scrolls to keep the caret visible.
- One field is focused at a time; undo history (48 steps, typing within 1 s coalesces) belongs to the focused field and
  resets on focus change.

| | |
|---|---|
| `int focus` | Focused input id, −1 = none. `ui::focus >= 0` ⇒ the user is typing: skip your single-key shortcuts. |
| `fn bool focused(int id)` | |
| `fn void focus_on(int id, char[] buf)` | Focus a field from code (e.g. Ctrl+F); selects all its text. |
| `fn void unfocus()` | |

Gotchas: ids must be unique among fields drawn in the same frame, and the same field must keep its id every frame.
Text size inside inputs is fixed at 15 px. Undo snapshots hold 1023 bytes: longer buffers undo truncated.

### Password field

`fn bool secret_input(int id, Rect r, char[] buf, String placeholder = "", bool* submitted = null)` shows one bullet
per character with a lock icon. Typing and paste append; Backspace, Ctrl+Backspace and Ctrl+U delete; Enter sets
`submitted`. No caret movement, selection, copy or undo history: the secret lives only in `buf`.
`fn void wipe(char[] buf)` zeroes a buffer with `explicit_bzero` (not optimized away): call it when the dialog closes.

### Completions under an input

`bool input_arrows_free` — set it right before `ui::input(...)` to leave Up/Down to the app (normally they jump to
start/end), e.g. to move through a suggestion list drawn under the field. Reset every frame.
`fn void input_replace(char[] buf, String s)` — replace the text and put the caret at the end (accepting a
completion while the field keeps focus).

## 8. Dropdown and context menu

```c3
// sketch
String[3] sizes = { "Small", "Medium", "Large" };
int size_sel = 1;
if (ui::dropdown(20, { x, y, 220, 36 }, &sizes, &size_sel)) apply_size();
```

`fn bool dropdown(int id, Rect r, String[] items, int* sel)`

- Shows `items[*sel]` (empty if out of range). Click opens a list below (above if no room), max 340 px tall,
  scrollable; Esc or a click outside closes.
- The choice is written to `*sel` **the next frame** the dropdown is drawn, and that call returns true.
- Items are copied when the list opens (max 64 items, 8 KB text), so temp strings are fine.
- While open, the popup owns all input (`popup_open`, `top = 99`); it is drawn by `frame_end`.

### Context menu

```c3
// sketch
const int MENU_ROW = 1;                                    // your menu ids
if (ui::right_clicked(row)) { selected = i; ui::menu_open(MENU_ROW); }
// every frame, after all other layer 0 widgets (and before modals):
if (ui::menu_begin(MENU_ROW))
{
	if (ui::menu_item("Open", ui::I_FOLDER_OPEN, "Enter")) open(selected);
	if (ui::menu_item("Paste", ui::I_PASTE, "Ctrl+V", can_paste)) paste();
	ui::menu_sep();
	if (ui::menu_item("Delete", ui::I_TRASH, "Del")) delete(selected);
	ui::menu_end();
}
```

| | |
|---|---|
| `fn void menu_open(int id, float x = -1, float y = -1)` | Open menu `id` at the mouse (or at `x, y`). Closes an open dropdown, consumes the click, gives the menu the input (`top = MENU_LAYER`, 98) from now on. Remember yourself what it was opened for. |
| `fn bool menu_begin(int id, float w = 240)` | True while `id` is open: then add items and call `menu_end()`. Call it **after** the widgets it should cover. A menu not drawn for a frame closes. |
| `fn bool menu_item(String label, String icon = "", String keys = "", bool enabled = true)` | One row (30 px): icon, label, `keys` hint right-aligned in GRAY (display only). True when clicked or Enter was pressed on it; the menu closes. Disabled rows are greyed and skipped by the arrow keys. |
| `fn void menu_sep()` | Separator line. |
| `fn void menu_end()` | Draws the box (flipped up / shifted left to stay in the window), handles ↑/↓, Esc and clicks outside (they close it and are consumed). |
| `fn void menu_close()`, `fn bool menu_is_open(int id)`, `int menu_id` | Close from code; query (−1 = none open). |

Gotchas: labels are copied, so temp strings are fine. The menu measures its height while drawing, so the first frame
places it with an estimate; nothing can be clicked in that frame anyway. Your own shortcuts guarded with `ui::top == 0`
are off while it is open.

## 9. Scrolling

```c3
// sketch
float content = (float)count * ROW + 8;
scroll = ui::scroll_wheel(area, scroll, content);   // float scroll; kept by you
ui::begin_clip(area);
for (int i = 0; i < count; i++) { float y = area.y + 4 + (float)i * ROW - scroll; ... }
ui::end_clip();
ui::scrollbar(area, scroll, content);
```

| | |
|---|---|
| `fn float scroll_wheel(Rect area, float scroll, float content)` | Applies the mouse wheel (48 px/notch) when the pointer is over `area` and the layer is live; returns the clamped offset (0 … content − area.height). |
| `fn void scrollbar(Rect area, float scroll, float content)` | 4 px bar at the right edge; nothing when it all fits. |

Skip drawing rows outside the area for long lists (`if (y + ROW < area.y \|\| y > area.y + area.height) continue;`).

## 10. Tooltips and toasts

| | |
|---|---|
| `fn void tooltip(String s)` | Show `s` next to the mouse this frame (call while hovering). Max 255 bytes. |
| `fn void toast(String s, Color c = AQUA)` | Notification bottom-right for 3.5 s with a coloured accent (GREEN success, RED error, ORANGE warning). One at a time; a new one replaces it. Max 511 bytes, copied (temp strings fine). |

## 11. Dialogs

| | |
|---|---|
| `fn Rect dialog(float w, float h)` | Dims the window, draws a centred box (at most `w x h`, 40 px from the window edge) with a shadow, returns it. |
| `fn bool dialog_header(Rect box, String icon, String title, String close_tip = "Close (Esc)")` | Icon (YELLOW) + 20 px title at `box.x + 20, box.y + 16`, X button top-right. True when X was clicked. Content usually starts at `box.y + 60`. |

Esc is not handled for you: `if (ui::live() && rl::is_key_pressed(rl::RLKeyboardKey.ESCAPE)) close;` (see COOKBOOK).

## 12. Keyboard

raylib key codes are US key **positions**; on QWERTZ, `rl::KeyboardKey.Z` is the key labelled Y.

| | |
|---|---|
| `fn bool letter(char c)` | Was the key that types letter `c` ('a'..'z', lowercase) pressed this frame (layout-aware). |
| `fn bool ctrl_down()`, `fn bool shift_down()` | Either side. On frames with a mouse press/release they also use the modifier state the compositor sent with the click, so Ctrl/Shift-clicks work even when the modifier went down while another window had focus. |
| `fn bool repeat(rl::RLKeyboardKey k)` | Pressed or auto-repeating (arrow keys in lists). |
| `fn void map_layout()` | Builds the letter map from GLFW (`open` calls it). |

Ctrl +/−/0 are taken by `frame_begin` for zoom.

## 13. File picker (picker::)

Module `bmu::picker`. A modal file/folder chooser drawn with bmu itself: path bar (type a path or `~/...`,
Enter), places sidebar (Home, Downloads, your places, /mnt, /run/media, /), list (dirs first, sorted), hidden-files
and all-files toggles. Double-click/Enter opens, Backspace goes up, ↑/↓ select, Esc cancels.

```c3
// sketch
const int PICK_ICON = 1;                          // your "purposes"
String[2] images = { ".png", ".jpg" };            // must outlive the picker: global or const
picker::start(PICK_ICON, FILE, "Choose an icon", start_dir, &images);
// every frame, after layer 0 widgets:
ui::layer = 1; if (picker::open) picker::draw(); ui::layer = 0;
int why; String path;
if (picker::take(&why, &path)) { if (why == PICK_ICON) txt::set(&icon, path); }
```

| | |
|---|---|
| `enum Mode { FILE, DIR }` | Choose a file, or a folder ("Use this folder" confirms the current one). |
| `fn void start(int why, Mode m, String title, String start_dir, String[] filter = {})` | Open. `why` is any int you choose. `filter`: extensions with the dot, case-insensitive; empty = all files. `~` expands; a missing start dir walks up to an existing one, else $HOME. |
| `bool open` | Showing. Pass it into `frame_begin(... \|\| picker::open)`. |
| `fn void draw()` | Draw + handle input. Call on layer 1, after your other modals (it must be on top). |
| `fn bool take(int* why, String* path)` | True **once** after a confirm. `path` points into picker storage: copy it (`txt::set`) before the next pick. |
| `fn void cancel()` | Close without a result. |
| `char[1024] last_dir` | Folder of the last confirmed pick (`txt::view(&picker::last_dir)`); save it to start there next time. |
| `fn void add_place(String icon, String name, String path)` / `fn void clear_places()` | Your sidebar entries (max 16, hidden when the folder is missing). |
| `fn void set_ext_icon(String ext, String icon)` | Show files ending in `ext` with `icon` in AQUA (max 16). |
| `const int ID_PATH = 9001` | Input id used by the path bar: don't reuse ids ≥ 9000. |

## 14. Text buffers and strings (txt::)

Module `bmu::txt`. Buffers are `char[N]` holding UTF-8 + NUL.

| | |
|---|---|
| `fn String view(char[] b)` | The text (no copy; valid while `b` is). |
| `fn void set(char[] b, String s)` | Copy in, truncated to `N − 1` bytes (may cut a UTF-8 sequence at the very end). |
| `fn void append(char[] b, String s)` | |
| `fn bool empty(char[] b)` | |
| `fn ZString z(char[] b)` | As C string (for raylib/libc). |
| `fn char lower(char c)` | ASCII lowercase. |
| `fn bool ieq(String a, String b)`, `icontains(hay, needle)`, `istarts_with(s, prefix)`, `iends_with(s, suffix)` | ASCII case-insensitive. Empty needle ⇒ true. |
| `fn int icmp(String a, String b)` | Case-insensitive order (−1/0/1). |
| `fn int natcmp(String a, String b)` | Natural order: digit runs compare as numbers ("Proton 9" < "Proton 10"). |
| `fn String basename(String p)`, `fn String dirname(String p)` | "/a/b/c" → "c" / "/a/b"; trailing slashes ignored; dirname of "x" is ".", of "/x" is "/". |
| `fn String strip_ext(String name)` | "x.tar.gz" → "x.tar"; ".hidden" unchanged. |
| `fn String join(String a, String b)` | Path join, **temp**. `fn ZString zjoin(...)` the same as C string. |
| `fn void pretty_name(char[] out, String raw)` | Drops the extension, `_` → space, splits CamelCase when there are no spaces: "BlackMythWukong" → "Black Myth Wukong". |
| `fn void slug(char[] out, String name, String fallback = "item")` | Lowercase a–z0–9 with single dashes: "Empire Earth: Gold!" → "empire-earth-gold". |

## 15. Files and system (sys::)

Module `bmu::sys`. Linux x86_64 (glibc or musl; `Dirent` layout is hard-coded).

| | |
|---|---|
| `fn bool exists(String p)`, `is_dir`, `is_file`, `is_exec` | stat-based (symlinks followed). |
| `fn bool mkdirs(String p)` | `mkdir -p` (0755); true if the dir exists afterwards. Paths up to 1023 bytes. |
| `fn bool move(String from, String to)` | `rename(2)`: same file system only; won't replace a non-empty dir. |
| `fn void realpath(char[] out, String p)` | Resolve symlinks / `..`; the input when it does not exist. |
| `fn String home()`, `fn String env(String name)` | `$HOME` ("/" if unset), any variable ("" if unset). |
| `fn long now()` | Unix time in seconds. |
| `struct Entry { char[256] name; bool dir; }` | |
| `fn int list_dir(String dir, Entry[] out, bool hidden)` | Fill `out` (stops when full), skipping `.`/`..` and dot-files unless `hidden`; symlinks to dirs count as dirs; sorted dirs first then case-insensitive. Returns the count, −1 if it can't be opened. Big arrays: `mem::talloc_array(sys::Entry, 512)` inside `@pool`. |
| `fn String? read_temp(String path)` | Whole file, temp. `if (try s = sys::read_temp(p)) ...` |
| `fn String read_tail(String path, usz max)` | Last `max` bytes, temp ("" on error). Logs. |
| `fn bool write_file(String path, String data)` | Create/replace. |
| `c_fork c_setsid c_execvpe c_dup2 c_open c_close c_write c_chdir c_waitpid c_kill c_access c_mkdir c_exit c_opendir c_readdir c_closedir c_realpath c_time c_usleep c_rename environ` | Raw libc. Constants `O_RDONLY O_WRONLY O_CREAT O_TRUNC O_APPEND WNOHANG SIGTERM SIGKILL X_OK DT_*`. See COOKBOOK "Run a program". |

## 16. Limits

| what | limit |
|---|---|
| input text | `buf.len − 1` bytes; undo/redo 48 steps of ≤1023 bytes |
| dropdown | 64 items, 8 KB of item text |
| context menu | 32 rows (items + separators), 4 KB of label text |
| tooltip / toast | 255 / 511 bytes |
| picker | 4096 entries per folder, 8 filter extensions, 16 places, 16 extension icons, 1023-byte paths |
| glyphs | baked set only (§2); 1024 codepoints total |
| font atlases | default body-size atlas + 32 LRU-cached sizes; native sizes 1–192 physical px, larger sizes scale the 192 px atlas (§2) |
| file operations | 16384 top-level items per job, 255-byte names, 4095-byte paths, 128 folder levels below an item, one operation per `fileop::Job`; 4 MiB copy steps (cancel/progress granularity); 1 MiB fallback buffer per job |
| recursive search | 16384 hits, 4 MiB of hit paths, 64 MiB of queued folders, 64 folder levels, 255-byte queries |
| image loader | 4095-byte paths; 32 MiB compressed file; 32,000,000 source pixels; 16384 px source edge; 1600 px preview edge; one pending request and one ready result per loader |
| clip | one level (`begin_clip` doesn't nest) |
| layers | 0 and 1 for app use (more work too: any int, one is active); 98 = context menu, 99 = dropdown popup |

## Async images (`bmu::image`)

Zero-initialize `image::Loader` at a stable address; do not copy it after its first request.
All methods are called by one owning/UI thread. No window or GPU context is needed to decode.

| call/type | contract |
|---|---|
| `loader.request(String path) -> bool` | Cancel previous work/result, copy path, lazily start worker. False for empty/oversized path or worker initialization failure. PNG, JPEG, BMP, GIF; filename extensions are case-insensitive. |
| `loader.take(image::Result* out) -> bool` | Poll once per frame; true transfers ownership of one result. On `READY`, unload `out.pixels` exactly once with `rl::unload_image`; `width`/`height` are original dimensions. |
| `loader.cancel()` | Invalidate in-flight work, clear pending request and unclaimed result. Does not wait for decoding. |
| `loader.close()` | Cancel, join worker, free unclaimed pixels; idempotent, reusable afterwards. May block on in-flight file I/O/decode. |
| `image::Status` | `READY`, `READ_ERROR`, `INVALID_IMAGE`, `TOO_LARGE`, `NO_MEMORY` (compressed-input allocation failure). |

The worker reads regular files, checks headers before decoding, then downsamples preserving aspect ratio.
GIF uses the first frame; no EXIF rotation. Latest request wins; stale results are freed without delivery.
Upload textures on the UI thread only. No thumbnails or global cache. Full source bitmap, decoder workspace,
and resize buffers are temporary: the preview limit is **not** a total-memory cap. Decoder allocation failure
may report `INVALID_IMAGE`; `NO_MEMORY` only identifies the loader's own input allocation failure.
Headers and decoding use the stb_image symbols from the bundled raylib static archive.

## Background file operations (`bmu::fileop`)

Copy, move, trash or delete on a worker thread with progress, name-conflict questions and safe cancel (Linux,
no raylib). Zero-initialize `fileop::Job` at a stable address (a global); all methods are UI-thread-only and cheap
(a mutex lock, no I/O), so polling `status()` every frame is fine.

| call/type | contract |
|---|---|
| `job.start(Kind kind, String src_dir, String[] names, String dst_dir = "", bool permanent_fallback = false) -> bool` | Copies the inputs and starts the worker. `names` are plain entry names (no `/`) in `src_dir`; directories must be absolute (pass resolved paths). `COPY`/`MOVE` need `dst_dir`. `TRASH` uses the home trash; with `permanent_fallback` items on another filesystem are deleted permanently instead of failing. `DELETE` is permanent; deleting inside the trash's `files/` folder also removes the items' `.trashinfo` records. `COUNT` changes nothing: it only fills `files_total` (files, folders, links) and `bytes_total` (sum of file sizes), e.g. for a "delete 1,234 items, 4.2 GB?" question; cancel it with `close()` when the question goes away. `RESTORE` takes names in a trash's `files/` folder as `src_dir`/`names` and moves each item back to the path in its `info/NAME.trashinfo` record (recreating missing parent folders; existing targets go through the usual conflict answers), then removes the record. False (nothing started) when busy, input invalid, or out of memory. |
| `job.start_elevated(kind, src_dir, names, dst_dir, char[] password, permanent_fallback = false) -> bool` | Same job as root: runs `sudo -k -S -p "" -- <this program> --bmu-fileop-helper <token>`. The password is written to sudo once (first stdin line) and wiped; `-k` means sudo neither uses nor caches credentials, so every elevated job asks again. Not for `TRASH` / `RESTORE`. Progress, conflicts, cancel and rollback behave as with `start`. A rejected password ends `FAILED` with error `"Wrong password"`; sudo's own refusal text is passed on. Wipe your password buffer (`ui::wipe`) after the call. |
| `fileop::is_helper(args)`, `fileop::helper_main(args) -> int` | Apps that use `start_elevated` must begin `main` with `if (fileop::is_helper(args)) return fileop::helper_main(args);` (before settings, windows or anything else): that is the only code running as root. The helper reads one job, runs it with the normal engine and exits; files it creates get the target folder's owner. |
| `fileop::elevate_cmd` | `String[]`, default `{ "sudo", "-k", "-S", "-p", "", "--" }`; tests set `{}` to run the helper unprivileged. |
| `job.busy() -> bool` | From `start` until `finished` reaped it. |
| `job.status(Progress* out)` | Snapshot: `state`, `kind`, `items`, `files_done/total`, `bytes_done/total`, `skipped`, `can_cancel`, `current`, `conflict`, `conflict_dir`, `error`, `err` (errno of the error: 13 EACCES / 1 EPERM = permission denied, a reason to offer `start_elevated`). `IDLE` when no job. |
| `job.answer(Answer a, bool all = false)` | Reply in state `CONFLICT`: `REPLACE`, `SKIP`, `KEEP_BOTH` ("name (2).ext"); `all` reuses it for later conflicts of this job. |
| `job.cancel()` | Ask the worker to stop and roll back; ignored while `can_cancel` is false. |
| `job.finished(Progress* out) -> bool` | True **once** after the worker ended: joins it, frees its memory, returns the final progress (`DONE`, `CANCELLED`, `FAILED` + `error`). Poll every frame while busy. |
| `job.close()` | Cancel and wait (blocks during rollback). Call on shutdown. |
| `fileop::can_trash(String path) -> bool` | Same filesystem as the home trash (one `lstat` + `stat`): call on the key press, not per frame. |
| `fileop::trash_dir(char[] out)` | `$XDG_DATA_HOME/Trash`, default `~/.local/share/Trash`. |
| `fileop::trash_info(String files_dir, String name, char[] path, char[] date = {}) -> bool` | Where a trashed item came from: reads `info/NAME.trashinfo` next to `files_dir`, fills the decoded absolute `path` and optionally `date` ("YYYY-MM-DD hh:mm:ss"). One small file read: call on an event (hover change), not per frame. |
| `fileop::State` | `IDLE`, `SCANNING` (planning + counting), `CONFLICT` (waiting for `answer`), `RUNNING`, `FINISHING` (commit or rollback, not cancellable), `DONE`, `CANCELLED`, `FAILED`. |

How it stays safe (COPY / MOVE are all-or-nothing):
- Every item is checked and every conflict is answered **before** anything is written. A folder is never put inside
  itself, and a folder that contains the source is never replaced.
- Same-filesystem moves are `rename(2)`: instant, nothing is copied. Copies and cross-filesystem moves are written
  to hidden temporaries (`.sms-part-PID-N`) in the target folder using `copy_file_range` (reflinks where the
  filesystem supports them), falling back to read/write. Permissions, timestamps and symlinks are kept; FIFOs,
  sockets and devices are skipped and counted in `skipped`.
- Cancel or an error before the commit removes the temporaries, renames moved items back and restores replaced
  ones; sources are never touched. The commit renames temporaries into place without overwriting
  (`renameat2(RENAME_NOREPLACE)`); a replaced target is moved aside first and deleted only afterwards.
- Cross-filesystem moves `syncfs` the target before deleting the sources. If the commit fails part way, finished
  items stay, the rest is undone and no source is deleted: nothing is lost, at worst something exists twice.
- `TRASH` follows the freedesktop.org Trash spec (`files/` + `info/NAME.trashinfo`, collisions become `NAME.2`);
  only the home trash, no per-volume `.Trash-UID` folders (RESTORE refuses relative recorded paths). Trash/delete/restore cancel stops between items (no undo); restoring across filesystems is refused.
- Hard links are copied as separate files; owners are not preserved. Filesystems without `RENAME_NOREPLACE` use
  check-then-rename (a tiny race).

## Recursive name search (`bmu::find`)

Search a folder tree for entry names on a worker thread (Linux, no raylib). Zero-initialize `find::Finder` at a
stable address; methods are UI-thread-only.

| call | contract |
|---|---|
| `finder.start(String root, String query, bool hidden = false) -> bool` | Breadth-first walk of absolute `root` for names containing `query` (case-insensitive). `hidden` includes dot-entries. False when already started (call `close()` first), empty query, or no memory. |
| `finder.results() -> int` | Hits so far (one lock). Hits below it never change until `close()`: read them without locking. |
| `finder.rel(i)`, `.name(i)`, `.folder(i)`, `.is_dir(i)` | Relative path, entry name, relative folder (`""` = root) and folder flag of hit `i`. |
| `finder.searching() -> bool` | The walk is still running. |
| `finder.limited() -> bool` | It stopped at a limit (see §16) or skipped too-deep / too-long paths. |
| `finder.close()` | Cancel (stops within one folder entry), join, free the results. Call before a new `start` and on exit. |

Never follows symlinks; stays on the root's filesystem like `find -xdev` (one `fstat` per folder, none per file;
`DT_UNKNOWN` entries cost one `lstat`). Debounce typing (e.g. 150 ms) and restart with `close()` + `start()`.

## 17. Low level: without the app layer

If you manage the window yourself (or embed bmu into a raylib game):

```c3
// sketch
rl::init_window(1280, 800, "x");
ui::set_scale(ui::auto_scale());
ui::load_font();
ui::map_layout();
while (!rl::window_should_close())
{
	ui::begin_frame();                 // cursor, consumed, now, layer; top=99 if popup
	if (!ui::popup_open) ui::top = modal ? 1 : 0;
	rl::begin_drawing();
	rl::clear_background(ui::BG);
	rl::begin_mode2d({ .zoom = ui::scale });
	// ... widgets ...
	ui::end_frame();                   // popup, tooltip, toast, cursor
	rl::end_mode2d();
	rl::end_drawing();
}
```

`fn void begin_frame()` / `fn void end_frame()` are the input/overlay halves of `frame_begin`/`frame_end`.
Use `ui::scissor` (logical px) rather than `rl::begin_scissor_mode`. After any render-to-texture inside the frame,
restart `rl::begin_mode2d` with the zoom.
