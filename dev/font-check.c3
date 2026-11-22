module bmu::font_check;
import std::io, std::math, libc;
import raylib6::rl;
import bmu::ui;

// Windowed font regression / timing probe. Run with a visible window.
fn void expect(bool ok, String what)
{
	if (ok) return;
	io::eprintfn("FAIL: %s", what);
	libc::exit(1);
}

fn void check_zoom()
{
	float saved = ui::scale;
	ui::zoom_toast = false;
	ui::zoom(1);
	ui::zoom_changed = false;
	ui::zoom(1);
	expect(!ui::zoom_changed, "same zoom is not a change");
	ui::zoom(1.25f);
	expect(ui::zoom_changed && ui::scale == 1.25f, "zoom changes scale");
	ui::zoom(9);
	expect(ui::scale == 3, "zoom clamps at maximum");
	ui::zoom_changed = false;
	ui::zoom(4);
	expect(!ui::zoom_changed, "clamped zoom is not a change");
	ui::zoom(saved);
	ui::zoom_toast = true;
	ZString plus = ui::glfw_key_name(ui::plus_key, 0);
	ZString minus = ui::glfw_key_name(ui::minus_key, 0);
	expect(plus && (plus[0] == '+' || plus[0] == '='), "plus key follows printable layout");
	expect(minus && minus[0] == '-', "minus key follows printable layout");
}

fn void check_fonts()
{
	float saved_scale = ui::scale;
	foreach (float s : { 0.75f, 1.0f, 1.25f, 1.5f, 2.0f, 3.0f })
	{
		ui::set_scale(s);
		foreach (float size : { 12.0f, 15.0f, 17.0f, 20.0f, 25.0f, 32.0f })
		{
			rl::RLFont* face = ui::sized_font(size);
			expect(face.base_size == (int)math::round(size * s), "native physical pixel size");
			expect(face.texture.mipmaps == 1, "no blurry mipmap downsampling");
			expect(math::abs(ui::text_size(size) * s - (float)face.base_size) < 0.001f, "one texel per physical pixel");
			uint id = face.texture.id;
			expect(ui::sized_font(size).texture.id == id, "cache hit reuses atlas");
			float expected_width = rl::measure_text_ex(*face, "Wi café", ui::text_size(size), 0)[0];
			expect(math::abs(ui::text_w("Wi café", size) - expected_width) < 0.001f, "measurement uses drawing atlas");
		}
		float snapped = ui::text_pixel(12.37f) * s;
		expect(math::abs(snapped - math::round(snapped)) < 0.001f, "physical pixel alignment");
	}
	ui::set_scale(1);
	// Exceed capacity while drawing: eviction must flush queued glyphs safely.
	ui::frame_begin();
	for (int p = 8; p < 8 + ui::FONT_CACHE_SIZE + 8; p++)
	{
		ui::text("Eviction", 10, (float)p * 8, (float)p);
		expect(ui::sized_font((float)p).base_size == p, "LRU eviction retains requested size");
	}
	ui::frame_end();
	int cached;
	foreach (slot : ui::font_slots) if (slot) cached++;
	expect(cached <= ui::FONT_CACHE_SIZE, "bounded atlas count");
	expect(ui::sized_font(250).base_size == ui::FONT_MAX_PIXELS, "oversized text uses capped atlas");
	expect(ui::text_size(250) == 250, "oversized text keeps requested display size");
	foreach (i, a : ui::font_sizes)
	{
		if (!a.face.texture.id) continue;
		expect(a.face.glyphs != ui::font.glyphs, "cache does not alias base font");
		foreach (j, b : ui::font_sizes) if (i != j && b.face.texture.id) expect(a.face.glyphs != b.face.glyphs, "no atlas aliasing");
	}
	ui::unload_font();
	expect(!ui::has_font, "unload resets state");
	foreach (slot : ui::font_slots) expect(slot == 0, "unload clears lookup");
	foreach (a : ui::font_sizes) expect(a.face.texture.id == 0, "unload clears cached ownership");
	ui::unload_font(); // idempotent; load_font also unloads before reloading
	int[1] extra = { 0x03A9 };
	ui::load_font(&extra);
	rl::RLFont* extra_face = ui::sized_font(20);
	int glyph = rl::get_glyph_index(*extra_face, 0x03A9);
	expect(extra_face.glyphs[glyph].value == 0x03A9, "extra glyph survives lazy atlas creation");
	ui::set_scale(saved_scale);
	ui::load_font();
	io::printn("ALL FONT CHECKS PASSED");
}

fn void main(String[] args)
{
	double start = rl::get_time();
	ui::open("bmu font check", 800, 600);
	double startup = rl::get_time() - start;
	defer ui::close();
	ui::app_args(args);
	check_zoom();
	check_fonts();
	double cold;
	double warm;
	int frames;
	while (ui::running())
	{
		ui::frame_begin();
		start = rl::get_time();
		for (int i = 0; i < 10; i++)
		{
			float size = (float)(12 + i * 2);
			ui::text("Folder / filename 0123 — café", 20.3f, 12.2f + (float)i * 48, size);
			ui::text(ui::I_FOLDER, 640.3f, 12.2f + (float)i * 48, size, ui::YELLOW);
			ui::text_w("Folder / filename 0123 — café", size);
		}
		double elapsed = rl::get_time() - start;
		if (frames == 0) { cold = elapsed; } else { warm += elapsed; }
		frames++;
		if (frames >= 120) ui::quit = true;
		ui::frame_end();
	}
	io::printfn("font probe: open %.3f ms, first draw %.3f ms, warm draw+measure %.3f ms (%d frames)",
		startup * 1000, cold * 1000, warm * 1000 / (double)math::max(1, frames - 1), frames);
}
