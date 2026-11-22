# Troubleshooting

Symptom → cause → fix.

| symptom | cause | fix |
|---|---|---|
| `Did you mean the alias 'Rect' in module std::math::geometry?` | naming the `Rect` type needs std::math | `import std::math;` |
| `'ui::button' could not be found` / `'ui' ... not imported` | missing import, or module not in project | `import gruvkit::ui;` and `"dependencies": ["raylib6", "gruvkit"]`, `"dependency-search-paths": ["gruvkit/lib"]` |
| `Library 'gruvkit' not found` | search path wrong | the path must contain `gruvkit.c3l/` (e.g. `gruvkit/lib`); check the submodule/symlink exists |
| nothing reacts to clicks | a modal state is stuck: `frame_begin(true)` while nothing is drawn on layer 1, or you drew on layer 1 without passing `modal` | pass exactly "is a modal visible" to `frame_begin`; reset `ui::layer = 0` after modals |
| the main window still reacts behind my dialog | dialog drawn on layer 0, or `frame_begin` not told | `ui::layer = 1;` before it, `frame_begin(dialog_open \|\| picker::open)` |
| dialog closes by itself / two widgets fire | the click went to a widget drawn earlier | draw the topmost thing last; set `ui::consumed = true` when your own code eats a click |
| typing in a field also triggers my shortcuts | global keys not guarded | `if (ui::focus >= 0) return;` before single-key shortcuts; Ctrl shortcuts with `ui::letter` |
| Ctrl+Z on a German keyboard does Ctrl+Y | used `rl::KeyboardKey.Z` (US position) | `ui::ctrl_down() && ui::letter('z')` |
| text field forgets what I typed | the buffer is a local variable (re-created every frame) | make the `char[N]` a global or a field of long-lived state |
| caret jumps / two fields edit together | two inputs share an id, or an id changes per frame | unique constant ids; picker uses 9000+ |
| dropdown selection "lags" one frame | by design: the popup is drawn after your code | react to the dropdown's `true` return, not to the click |
| icon shows as `?` | glyph not baked into the font atlas | add its codepoint via `ui::load_font(extra)` (API §2) |
| everything tiny / huge on a monitor | auto scale guess | Ctrl +/−/0, or `ui::open(..., ui_scale: 1.25f)`, `--scale 1.25` |
| clipped area is offset / wrong size | used `rl::begin_scissor_mode` (physical px) | `ui::begin_clip(r)` or `ui::scissor(...)` |
| layout off the window edge | used `rl::get_screen_width()` | `ui::sw()`, `ui::sh()` (logical) |
| memory grows every frame | temp strings in the loop without a pool | per-frame code in a function declared `=> @pool()` |
| `picker::take` path is garbage later | it points into picker storage | copy it with `txt::set(&mine, path)` right away |
| picker filter strings corrupt | filter array was a local/temp | make the `String[N]` filter global or const |
| `--shot` writes nothing | app does not call `ui::app_args(args)`, or the loop isn't `ui::running()`/`frame_end` | use the app layer; the file path is relative to the cwd |
| `--shot` / the app hangs with no output on River | window on a hidden tag blocks buffer swaps | run it in the foreground on a visible tag |
| window ignores the size I asked for | a tiling WM (River) decides the size | expected; design for any size via `sw()`/`sh()` |
