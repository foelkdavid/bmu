module bmu::tests;
import std::io, std::core::string, libc;
import bmu::txt, bmu::sys, bmu::ui, bmu::fileop;

// Headless checks (no window): txt helpers, sys file helpers, text-edit primitives.
//   c3c build bmu-check && ./build/bmu-check     -> ALL BMU CHECKS PASSED

int failed;
int passed;

macro void expect(bool ok, String what)
{
	if (ok) { passed++; return; }
	failed++;
	io::printfn("FAIL  %s", what);
}

macro void expect_str(String got, String want, String what)
{
	if (got == want) { passed++; return; }
	failed++;
	io::printfn("FAIL  %s: got \"%s\", want \"%s\"", what, got, want);
}

fn int main(String[] args)
{
	if (fileop::is_helper(args)) return fileop::helper_main(args);
	check_txt();
	check_sys();
	check_edit();
	check_fileop();
	check_find();
	check_elevated();
	check_archive();
	check_app_id();
	check_places();
	if (failed) { io::printfn("%d FAILED, %d passed", failed, passed); libc::exit(1); }
	io::printfn("ALL BMU CHECKS PASSED (%d)", passed);
	return 0;
}

fn void check_txt() => @pool()
{
	char[8] small;
	txt::set(&small, "abcdefghij");
	expect_str(txt::view(&small), "abcdefg", "set truncates to N-1");
	txt::set(&small, "ab");
	txt::append(&small, "cd");
	expect_str(txt::view(&small), "abcd", "append");
	expect(txt::empty(&&(char[4]){}), "empty buffer");

	expect(txt::ieq("HeLLo", "hello"), "ieq");
	expect(txt::icontains("Empire Earth", "EARTH"), "icontains");
	expect(txt::icontains("x", ""), "icontains empty needle");
	expect(txt::iends_with("Game.EXE", ".exe"), "iends_with");
	expect(txt::istarts_with("Play Game", "play "), "istarts_with");
	expect(txt::icmp("apple", "Banana") < 0, "icmp");
	expect(txt::natcmp("Proton 9.0", "Proton 10.0") < 0, "natcmp numbers");
	expect(txt::natcmp("b", "a") > 0, "natcmp letters");

	expect_str(txt::basename("/a/b/c.exe"), "c.exe", "basename");
	expect_str(txt::basename("/a/b/"), "b", "basename trailing slash");
	expect_str(txt::dirname("/a/b/c.exe"), "/a/b", "dirname");
	expect_str(txt::dirname("/a"), "/", "dirname root");
	expect_str(txt::dirname("rel"), ".", "dirname relative");
	expect_str(txt::strip_ext("x.tar.gz"), "x.tar", "strip_ext");
	expect_str(txt::strip_ext(".hidden"), ".hidden", "strip_ext dotfile");
	expect_str(txt::join("/a/", "b"), "/a/b", "join slash");
	expect_str(txt::join("/a", "b"), "/a/b", "join");

	char[64] out;
	txt::pretty_name(&out, "The_Elder_Scrolls_III.exe");
	expect_str(txt::view(&out), "The Elder Scrolls III", "pretty_name underscores");
	txt::pretty_name(&out, "BlackMythWukong");
	expect_str(txt::view(&out), "Black Myth Wukong", "pretty_name camel case");
	txt::slug(&out, "Empire Earth: Gold!");
	expect_str(txt::view(&out), "empire-earth-gold", "slug");
	txt::slug(&out, "???", "game");
	expect_str(txt::view(&out), "game", "slug fallback");
}

fn void check_sys() => @pool()
{
	String root = string::tformat("/tmp/bmu-check-%d", sys::now());
	expect(sys::mkdirs(txt::join(root, "x/y/z")), "mkdirs");
	expect(sys::is_dir(txt::join(root, "x/y")), "is_dir");
	expect(sys::write_file(txt::join(root, "b.txt"), "hello world"), "write_file");
	expect(sys::write_file(txt::join(root, "A.txt"), "a"), "write_file 2");
	expect(sys::is_file(txt::join(root, "b.txt")), "is_file");
	expect(!sys::is_exec(txt::join(root, "b.txt")), "is_exec false");
	expect_str(sys::read_tail(txt::join(root, "b.txt"), 5), "world", "read_tail");
	if (try s = sys::read_temp(txt::join(root, "b.txt"))) { expect_str(s, "hello world", "read_temp"); } else { expect(false, "read_temp"); }

	sys::Entry[8] e;
	int n = sys::list_dir(root, &e, false);
	expect(n == 3, "list_dir count");
	if (n == 3)
	{
		expect(e[0].dir && txt::view(&e[0].name) == "x", "list_dir dirs first");
		expect_str(txt::view(&e[1].name), "A.txt", "list_dir case-insensitive order");
	}
	expect(sys::list_dir(txt::join(root, "missing"), &e, false) == -1, "list_dir missing = -1");
	expect(sys::move(txt::join(root, "A.txt"), txt::join(root, "c.txt")), "move");
	expect(!sys::exists(txt::join(root, "A.txt")) && sys::exists(txt::join(root, "c.txt")), "move result");
	expect(sys::home().len > 0, "home");
	char[1024] rp;
	sys::realpath(&rp, txt::join(root, "x/y/.."));
	expect_str(txt::view(&rp), txt::join(root, "x"), "realpath");
	// Exercise sorting above the small-list threshold, plus empty and bounded slices.
	String large = txt::join(root, "large");
	expect(sys::mkdirs(large), "large listing mkdir");
	expect(sys::list_dir(large, &e, true) == 0, "list_dir empty");
	for (int i = 127; i >= 0; i--)
	{
		expect(sys::write_file(txt::join(large, string::tformat("file-%03d", i)), ""), "large listing fixture");
	}
	expect(sys::mkdirs(txt::join(large, "z-folder")), "large listing dir");
	sys::Entry[160] many;
	int count = sys::list_dir(large, &many, true);
	expect(count == 129 && many[0].dir, "large listing dirs first");
	bool ordered = count == 129;
	for (int i = 2; i < count; i++)
	{
		if (txt::icmp(txt::view(&many[i - 1].name), txt::view(&many[i].name)) > 0) ordered = false;
	}
	expect(ordered, "large listing sorted");
	expect(sys::list_dir(large, e[:1], true) == 1, "list_dir bounded output");
	expect(sys::list_dir(large, e[:0], true) == 0, "list_dir zero capacity");
	// clean up
	libc::system(string::tformat("rm -rf '%s'", root).zstr_tcopy());
}

fn void check_edit()
{
	char[16] b;
	txt::set(&b, "foo bar/baz");
	expect(ui::word_left(&b, 11) == 8, "word_left");
	expect(ui::word_right(&b, 0) == 3, "word_right");
	expect(ui::word_left(&b, 4) == 0, "word_left skips separator");

	txt::set(&b, "aé");   // é = 2 bytes
	expect(ui::next_char(&b, 1) == 3, "next_char utf-8");
	expect(ui::prev_char(&b, 3) == 1, "prev_char utf-8");

	txt::set(&b, "ac");
	ui::caret = 1;
	expect(ui::insert_byte(&b, 'b'), "insert_byte");
	expect_str(txt::view(&b), "abc", "insert_byte result");
	expect(ui::caret == 2, "insert_byte moves caret");
	ui::caret = 3;
	expect(ui::insert_codepoint(&b, 0x20AC), "insert_codepoint €");
	expect_str(txt::view(&b), "abc€", "insert_codepoint result");
	ui::remove_range(&b, 1, 3);
	expect_str(txt::view(&b), "a€", "remove_range");

	char[4] tiny;
	txt::set(&tiny, "ab");
	ui::caret = 2;
	expect(!ui::insert_byte(&tiny, 'c'), "insert_byte refuses when full");
}

fn void check_app_id() => @pool()
{
	ui::set_app_id("myapp");
	expect_str(txt::view(&ui::wayland_app_id), "myapp", "app_id reaches the raylib hint");
	char[300] long_id;
	long_id[..] = 'x';
	ui::set_app_id((String)long_id[..]);
	expect(txt::view(&ui::wayland_app_id).len == 255, "app_id cut to 255 bytes");
	ui::set_app_id("");
	expect(txt::empty(&ui::wayland_app_id), "app_id cleared");
}
