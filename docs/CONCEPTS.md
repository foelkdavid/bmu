# How gruvkit thinks

Five ideas explain every call. Read this once; the rest is lookup.

## Immediate mode

There is no widget tree. Each frame your code calls `ui::button(...)`, the button draws itself and returns whether it
was clicked in this frame. App state lives in **your** variables (globals or structs); widgets only read and write them:

```c3
// sketch
bool dark = true;                                  // your state
ui::checkbox(20, 20, "Dark mode", &dark);          // widget edits it
if (dark) ui::panel({ 0, 0, 100, 100 }, ui::BG_HARD);
```

Consequences:
- To hide a widget, don't call it. To disable a button, pass `enabled = false`.
- Layout is code: compute rects from `ui::sw()`/`ui::sh()` every frame and the UI follows window resizes.
- Order matters: things drawn later are on top, and the **first** widget to take a click wins (`ui::consumed`).
  Overlays that should win (popups, tooltips, toasts) are drawn by `frame_end`.

## Logical pixels

All coordinates are logical px. `ui::scale` (0.75–3, Ctrl +/−/0, default from the monitor: 1.0 ≤1440p, 1.5 at 4K)
maps them to physical px through a raylib 2D camera zoom, and the mouse is scaled back. So a 36 px input is 36 px at
1080p and 54 physical px at 4K, and your layout code never changes.

- Window size: `ui::sw()`, `ui::sh()` (logical). Not `rl::get_screen_width()` (physical).
- Scissor: `ui::scissor` / `ui::begin_clip` (logical). Not `rl::begin_scissor_mode` (physical).
- Persist the user's zoom: when `ui::zoom_changed`, save `ui::scale`; pass it to `ui::open(..., ui_scale: saved)`.

## Layers and modals

Every widget asks `ui::live()`: "is the layer I'm drawn on the one that gets input (`ui::top`), and was the click not
used yet?". You choose the layer you draw on with `ui::layer`, and `frame_begin(modal)` chooses `top`:

```
frame_begin(modal = dialog_open || picker::open)  ->  top = modal ? 1 : 0
layer 0: main window widgets      (dead while a modal is open: no hover, no clicks)
layer 1: dialog(s), picker last   (live while a modal is open)
frame_end: dropdown popup (layer 99, owns input while open), tooltip, toast
```

So a modal is simply: draw it on layer 1 and tell `frame_begin` it is open. Nothing on layer 0 reacts behind it.
Your own keyboard shortcuts must check too: `ui::top == 0` for main-window keys, `ui::live()` inside a modal.

## Ids and focus

Text inputs and dropdowns keep state across frames (caret, selection, undo, open list), so they need a stable
identity: an `int` id you pick, unique among widgets drawn in the same frame. Define them as constants. Exactly one
input can be focused (`ui::focus`); the focused field owns the keyboard (letters, arrows, Enter, Esc), so global
shortcuts check `ui::focus < 0` first. The picker reserves ids ≥ 9000.

## Buffers, not strings

Editable text is a fixed `char[N]` that you own, passed as `&buf` and edited in place (no allocation, no lifetime
questions inside the frame loop). `txt::view(&buf)` gives a `String` view, `txt::set(&buf, s)` copies in. Pick `N`
for the use: 128 names, 256 short text, 1024 paths. Anything built per frame (`string::tformat`, `txt::join`) is
**temp memory**, freed at the end of the surrounding `@pool()`.

## The pieces

| module | file | what |
|---|---|---|
| `gruvkit::ui` | `app.c3` | window, loop, zoom keys, `--shot` |
| `gruvkit::ui` | `ui.c3` | font, colours, icons, widgets, input state |
| `gruvkit::picker` | `picker.c3` | file/folder chooser (uses ui, txt, sys) |
| `gruvkit::txt` | `txt.c3` | char buffer + string helpers (no raylib) |
| `gruvkit::sys` | `sys.c3` | POSIX file/process helpers (no raylib) |

`txt` and `sys` don't touch raylib: CLI tools and headless code can use them alone.
