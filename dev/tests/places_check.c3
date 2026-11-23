module bmu::tests;
import std::core::string, libc;
import bmu::txt, bmu::sys, bmu::places;

<* Shared places file: load/add/remove/downloads round trip in a temporary XDG_CONFIG_HOME. *>
fn void check_places() => @pool()
{
	String root = string::tformat("/tmp/bmu-places-check-%d", sys::now());
	String old = sys::env("XDG_CONFIG_HOME").tcopy();
	libc::setenv("XDG_CONFIG_HOME", root.zstr_tcopy(), 1);
	expect(!places::load(), "places: missing file");
	expect(places::count == 0 && places::downloads, "places: defaults");
	expect(places::add("/a/b"), "places: add");
	expect(places::add("/a/b") && places::count == 1, "places: add twice keeps one");
	expect(!places::add("relative"), "places: relative refused");
	expect(!places::add("/x\ny"), "places: newline refused");
	expect(places::add("/c"), "places: add second");
	places::set_downloads(false);
	expect(sys::is_file(txt::join(root, "bmu/places")), "places: file written");
	places::count = 0;
	places::downloads = true;
	expect(places::load(), "places: reload");
	expect(places::count == 2 && !places::downloads, "places: reloaded state");
	if (places::count == 2) { expect_str(places::path(0), "/a/b", "places: order 0"); expect_str(places::path(1), "/c", "places: order 1"); }
	places::remove(0);
	places::load();
	expect(places::count == 1 && places::path(0) == "/c", "places: remove saved");
	for (int i = 0; i < places::MAX + 2; i++) places::add(string::tformat("/p%d", i));
	expect(places::count == places::MAX, "places: bounded");
	if (old.len) { libc::setenv("XDG_CONFIG_HOME", old.zstr_tcopy(), 1); } else { libc::unsetenv("XDG_CONFIG_HOME"); }
	places::file = {};
	libc::system(string::tformat("rm -rf '%s'", root).zstr_tcopy());
}
