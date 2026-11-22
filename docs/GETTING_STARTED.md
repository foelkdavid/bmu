# Getting started

## What you need

- C3 compiler 0.8.x (`c3c --version`).
- Linux x86_64. raylib 6 ships prebuilt and statically linked in `lib/raylib6.c3l` (X11 build: on Wayland it runs
  under XWayland). Linked system libs: X11, Xrandr, Xinerama, Xi, Xcursor, libm.
- Nothing else: no GTK, no portals, no zenity. The font is embedded.

## Try it

```sh
cd ../bmu
c3c build example-hello   && ./build/example-hello
c3c build example-gallery && ./build/example-gallery      # every widget + the file picker
```

## A new app

```sh
../bmu/tools/new-app.sh ../my-app "My App"
cd ../my-app && c3c build && ./build/my-app
```

This copies `template/`, links bmu in as a git submodule at `bmu/` (like vpt-engine is `engine/` in Depths),
builds, and makes the first commit. To add bmu to an **existing** project by hand:

1. Make `bmu/` point at this repo: `git submodule add <bmu repo> bmu` (or a symlink
   `ln -s ../bmu bmu` for a project without git).
2. In `project.json`:

```json
"dependency-search-paths": ["bmu/lib"],
"targets": { "my-app": { "type": "executable", "sources": ["src/**"], "dependencies": ["raylib6", "bmu"] } }
```

3. Import what you use: `import std::math; import raylib6::rl; import bmu::ui, bmu::txt, bmu::sys, bmu::picker;`

## How an app is structured

```c3
module getting_started;
import std::core::string;
import raylib6::rl;
import bmu::ui, bmu::txt;

const int ID_TODO = 1;          // input ids: unique per field

char[256] new_todo;             // text field buffer
char[256][32] todos;            // app state: plain globals
bool[32] done;
int count;

fn void main(String[] args)
{
	ui::open("Todo", 520, 640, 400, 400);
	defer ui::close();
	ui::app_args(args);
	while (ui::running()) frame();
}

fn void frame() => @pool()      // @pool: temp strings are freed every frame
{
	ui::frame_begin();
	float w = ui::sw();
	ui::text("Todo", 20, 18, 24, ui::YELLOW);
	bool enter = false;
	ui::input(ID_TODO, { 20, 60, w - 140, 36 }, &new_todo, "What needs doing?", &enter, ui::I_PLUS);
	if ((ui::button({ w - 110, 60, 90, 36 }, "Add", PRIMARY) || enter) && !txt::empty(&new_todo) && count < 32)
	{
		txt::set(&todos[count++], txt::view(&new_todo));
		new_todo[0] = 0;
	}
	for (int i = 0; i < count; i++)
	{
		float y = 116 + (float)i * 32;
		ui::checkbox(20, y, txt::view(&todos[i]), &done[i]);
	}
	ui::text(string::tformat("%d item%s", count, count == 1 ? "" : "s"), 20, ui::sh() - 28, 13, ui::GRAY);
	ui::frame_end();
}
```

Build and look at it without clicking around: `./build/my-app --shot out.png` saves what the window shows.

## Next

- [QUICK_REFERENCE.md](QUICK_REFERENCE.md): all calls on one page.
- [COOKBOOK.md](COOKBOOK.md): forms, lists, dialogs, tabs, the file picker, settings files, shortcuts, drag & drop.
- [CONCEPTS.md](CONCEPTS.md): layers, logical pixels, ids.
- botexe (`../botexe`) is a complete real app built on bmu.
