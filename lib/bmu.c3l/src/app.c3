module bmu::ui;
import std::io, std::math, std::core::string;
import raylib6::rl;
import bmu::txt;

// App layer: window + frame loop + UI zoom + `--shot` screenshots. Optional - the
// lower-level calls (begin_frame/end_frame, set_scale, load_font...) keep working.
//
//   ui::open("My app", 1280, 800);
//   defer ui::close();
//   ui::app_args(args);
//   while (ui::running())
//   {
//       ui::frame_begin(my_modal || picker::open);
//       ... layer 0 widgets ...
//       ui::layer = 1; ... modal widgets ...; ui::layer = 0;
//       ui::frame_end();
//   }

int base_w = 1280;      // window size in logical px (scaled by `scale`)
int base_h = 800;
int min_base_w = 800;
int min_base_h = 500;
Color clear_color = BG;
bool zoom_toast = true; // frame_begin's zoom shortcuts show "UI scale N%"
bool zoom_shift_only;   // reserve plain Ctrl +/-/0 for app content zoom
bool zoom_changed;      // set for one frame when the user changed the scale
bool scale_auto;        // `scale` is auto_scale(): re-picked when the compositor scale (`dpi`) becomes known/changes

char[1024] shot_path;   // --shot FILE: save a PNG after `shot_frames` frames, then quit
int shot_frames = 3;
int frame_count;
int stable_frames;      // frames since the window was last resized (a tiling WM resizes right after mapping)
bool quit;              // set to true to leave the loop (running() returns false)
bool hold_close;        // the window's close button does not quit: it sets close_requested instead
bool close_requested;   // the user tried to close while hold_close (the app clears it, e.g. after asking)
extern char[256] wayland_app_id @cname("rlWaylandAppId"); // bmu raylib patch: GLFW_WAYLAND_APP_ID hint

<*
 Open a resizable window of w x h LOGICAL px (clamped to 90% of the monitor), set
 the UI scale (`ui_scale` > 0, else auto_scale()), load the font, map the keyboard
 layout, 60 FPS (sleep-paced, no vsync), no Esc-to-quit, raylib log level WARNING.
 `app_id` is the Wayland app_id (default: `title`): shells match it to `<app_id>.desktop` for the
 window's taskbar / switcher icon, so make it the .desktop file's name.
*>
fn void open(String title, int w = 1280, int h = 800, int min_w = 800, int min_h = 500, float ui_scale = 0, String app_id = "") => @pool()
{
	base_w = w; base_h = h; min_base_w = min_w; min_base_h = min_h;
	set_app_id(app_id.len ? app_id : title);
	rl::set_trace_log_level(rl::RLTraceLogLevel.WARNING);
	// No VSYNC_HINT: on Wayland the first synced swap stalls ~0.5 s (compositors never tear anyway); frames are
	// paced by set_target_fps with a sleep-only wait (bmu's raylib patch).
	// WINDOW_HIGHDPI: the framebuffer follows the compositor's (fractional) output scale, so a 1.5x output gets
	// a native-resolution buffer instead of a 1x one stretched (blurred) by the compositor. `dpi` arrives with
	// the first frames (Wayland tells a surface its scale only after it is mapped).
	rl::set_config_flags(rl::RLConfigFlag.WINDOW_RESIZABLE | rl::RLConfigFlag.MSAA_4X_HINT | rl::RLConfigFlag.WINDOW_HIGHDPI);
	rl::init_window(w, h, title.zstr_tcopy());
	scale_auto = ui_scale <= 0;
	sync_dpi();
	set_scale(ui_scale > 0 ? ui_scale : auto_scale());
	fit_window(true);
	rl::set_exit_key(rl::RLKeyboardKey.NONE);
	rl::set_target_fps(60);
	load_font();
	map_layout();
}

<* Wayland app_id for the next window (open() calls it; cut to 255 bytes). Has no effect on an open window. *>
fn void set_app_id(String id)
{
	txt::set(&wayland_app_id, id);
}

<* Re-apply the minimum window size for the current scale; `resize` also sets the initial size. *>
fn void fit_window(bool resize)
{
	rl::set_window_min_size((int)((float)min_base_w * scale), (int)((float)min_base_h * scale));
	if (!resize) return;
	int m = 0; // Wayland: a window can't learn its output before it is shown; size against the primary one
	int w = math::min((int)((float)base_w * scale), (int)((float)rl::get_monitor_width(m) * 0.9f));
	int h = math::min((int)((float)base_h * scale), (int)((float)rl::get_monitor_height(m) * 0.9f));
	if (w > 0 && h > 0) rl::set_window_size(w, h);
}

fn void close()
{
	unload_font();
	rl::close_window();
}

<*
 Parse the app-layer command line flags and ignore everything else:
   --shot FILE   render a few frames, save the window as PNG to FILE, exit
   --frames N    frames before the shot (default 3; it also waits until the window
                 size has been stable for 5 frames, max 300 frames)
   --scale S     UI scale for this run (1, 1.5, 2...)
*>
fn void app_args(String[] args)
{
	for (usz i = 1; i + 1 < args.len; i++)
	{
		switch (args[i])
		{
			case "--shot": txt::set(&shot_path, args[i + 1]);
			case "--frames": if (try n = args[i + 1].to_int()) shot_frames = math::max(n, 1);
			case "--scale": if (try f = args[i + 1].to_float()) { scale_auto = false; set_scale(f); fit_window(true); }
		}
	}
}

<* Loop condition. With `hold_close`, a close request sets `close_requested` and keeps running. *>
fn bool running()
{
	if (quit) return false;
	if (!rl::window_should_close()) return true;
	if (!hold_close) return false;
	close_requested = true;
	return true;
}

<*
 Start a frame: input state (begin_frame), Ctrl +/-/0 zoom (with Shift if zoom_shift_only), input layer (`modal`
 true = only layer 1 reacts), begin_drawing, clear, 2D zoom by `px` (UI scale x compositor scale).
*>
fn void frame_begin(bool modal = false)
{
	begin_frame();
	if (dpi_changed && scale_auto)
	{
		set_scale(auto_scale());
		// Min size only: a size request on a mapped Wayland window overrides the compositor's tile/configure size
		// (GLFW resizes the buffer right away), leaving the window smaller than its slot.
		fit_window(false);
	}
	if (!popup_open && menu_id < 0) top = modal ? 1 : 0;
	zoom_changed = false;
	if (ctrl_down() && (!zoom_shift_only || shift_down()))
	{
		float s = scale + (float)zoom_step() * 0.25f;
		bool reset = rl::is_key_pressed(rl::RLKeyboardKey.ZERO);
		if (reset) s = auto_scale();
		if (s != scale) zoom(s);
		if (reset) scale_auto = true;
	}
	rl::begin_drawing();
	rl::clear_background(clear_color);
	rl::begin_mode2d({ .offset = { 0, 0 }, .target = { 0, 0 }, .rotation = 0, .zoom = px }); // mode2d drops raylib's DPI matrix
	layer = 0;
}

<* Change UI scale like the zoom shortcuts (only a real change sets zoom_changed/min size/toast). *>
fn void zoom(float s)
{
	float previous = scale;
	set_scale(s);
	scale_auto = false;
	if (previous == scale) return;
	fit_window(false);
	zoom_changed = true;
	if (zoom_toast) @pool() { toast(string::tformat("UI scale %d%%", (int)(scale * 100 + 0.5f))); };
}

<* Finish the frame: popups, tooltip, toast, cursor, present; handles --shot. *>
fn void frame_end()
{
	end_frame();
	rl::end_mode2d();
	rl::end_drawing();
	frame_count++;
	stable_frames = rl::is_window_resized() ? 0 : stable_frames + 1;
	if (shot_path[0] && frame_count >= shot_frames && (stable_frames >= 5 || frame_count > 300)) @pool()
	{
		// not rl::take_screenshot: it keeps only the file NAME and saves into the cwd
		rl::RLImage img = rl::load_image_from_screen();
		ZString p = ((ZString)&shot_path).str_view().zstr_tcopy();
		bool ok = rl::export_image(img, p);
		rl::unload_image(img);
		io::printfn(ok ? "saved %s" : "could not save %s", p);
		quit = true;
	};
}

// Runtime facts for an "About" page or a bug report. Call after open(), on the UI thread (GL context).
alias GlGetStringFn @private = fn ZString(CUInt name);
extern GlGetStringFn glad_get_string @cname("glad_glGetString") @private;
extern fn CInt glfw_get_platform() @cname("glfwGetPlatform") @private;
extern fn ZString glfw_version_string() @cname("glfwGetVersionString") @private;

<* Windowing backend in use: "Wayland", "X11", "Win32", "Cocoa", "null" or "unknown". *>
fn String backend()
{
	switch (glfw_get_platform())
	{
		case 0x00060003: return "Wayland";
		case 0x00060004: return "X11";
		case 0x00060001: return "Win32";
		case 0x00060002: return "Cocoa";
		case 0x00060005: return "null";
		default: return "unknown";
	}
}

<* GLFW's compile-time version string, e.g. "3.4.0 Wayland EGL OSMesa monotonic". *>
fn String glfw_version() => glfw_version_string().str_view();

fn String gl_string(CUInt name) @private
{
	if (!glad_get_string) return "unknown";
	ZString s = glad_get_string(name);
	return s ? s.str_view() : "unknown";
}

<* GPU / driver name (GL_RENDERER) and OpenGL version (GL_VERSION). *>
fn String gpu() => gl_string(0x1F01);
fn String gl_version() => gl_string(0x1F02);

extern fn CInt bmu_set_clipboard_data(CInt count, ZString* mimes, void** datas, usz* sizes) @cname("bmuSetClipboardData") @private;

<*
 Put data in other formats on the clipboard, e.g. { "image/png", "text/uri-list" } with the PNG bytes and
 "file:///path\r\n". Up to 4 formats; the bytes are copied. Call from a user action (click / key) on the UI
 thread. Wayland: the data is served while the app runs (a clipboard manager keeps it afterwards).
 Text keeps working through rl::set_clipboard_text, which replaces this.
*>
fn bool clipboard_set_data(String[] mimes, char[][] datas) => @pool()
{
	if (!mimes.len || mimes.len != datas.len || mimes.len > 4) return false;
	ZString[4] m;
	void*[4] d;
	usz[4] n;
	foreach (i, mime : mimes)
	{
		m[i] = mime.zstr_tcopy();
		d[i] = datas[i].ptr;
		n[i] = datas[i].len;
	}
	return bmu_set_clipboard_data((CInt)mimes.len, &m, &d, &n) == 1;
}

