module bmu::tests;
import std::io, std::core::string, libc;
import bmu::txt, bmu::sys, bmu::find, bmu::fileop;

// Headless checks of bmu::find in a private temporary folder.

find::Finder finder;

fn int search_all(String root, String query, bool hidden = false)
{
	if (!finder.start(root, query, hidden)) return -1;
	for (int spins = 0; spins < 20000 && finder.searching(); spins++) sys::c_usleep(500);
	return finder.results();
}

fn bool has_hit(String rel)
{
	int n = finder.results();
	for (int i = 0; i < n; i++) if (finder.rel(i) == rel) return true;
	return false;
}

fn void check_find() => @pool()
{
	char[64] dir;
	txt::set(&dir, "/tmp/bmu-find-XXXXXX");
	if (!mkdtemp(&dir)) { expect(false, "find: mkdtemp"); return; }
	String root = txt::view(&dir);
	sys::mkdirs(txt::join(root, "a/b/c"));
	sys::mkdirs(txt::join(root, ".hid"));
	sys::mkdirs(txt::join(root, "Notes"));
	sys::write_file(txt::join(root, "note.txt"), "x");
	sys::write_file(txt::join(root, "a/b/c/deep-NOTE.md"), "x");
	sys::write_file(txt::join(root, ".hid/note-hidden"), "x");
	sys::write_file(txt::join(root, "a/other.txt"), "x");
	symlink("/", txt::join(root, "a/loop").zstr_tcopy());

	int n = search_all(root, "note");
	expect(n == 3, "find: three visible matches");
	expect(has_hit("note.txt") && has_hit("Notes") && has_hit("a/b/c/deep-NOTE.md"), "find: case-insensitive, recursive");
	expect(!has_hit(".hid/note-hidden"), "find: hidden skipped");
	expect(finder.rel(n - 1) == "a/b/c/deep-NOTE.md", "find: breadth-first (deep match last)");
	int deep = n - 1;
	expect(finder.name(deep) == "deep-NOTE.md" && finder.folder(deep) == "a/b/c" && !finder.is_dir(deep), "find: name and folder of hit");
	int notes = -1;
	for (int i = 0; i < n; i++) if (finder.rel(i) == "Notes") notes = i;
	expect(notes >= 0 && finder.is_dir(notes) && finder.folder(notes) == "", "find: folder hit at root");
	expect(!finder.limited(), "find: not limited");
	finder.close();

	n = search_all(root, "note", true);
	expect(n == 4 && has_hit(".hid/note-hidden"), "find: hidden included on request");
	finder.close();
	n = search_all(root, "loop");
	expect(n == 1 && !finder.is_dir(0), "find: symlink not followed");
	finder.close();
	expect(!finder.start(root, ""), "find: empty query refused");
	expect(finder.results() == 0 && !finder.searching(), "find: idle after close");

	// Cancel right away from / (stops quickly, nothing leaks).
	if (finder.start("/", "zzzz-unlikely")) finder.close();
	expect(!finder.searching(), "find: close cancels");

	fileop::Job cleanup;
	fileop::Progress p;
	if (cleanup.start(DELETE, "/tmp", { txt::basename(root) })) { while (!cleanup.finished(&p)) sys::c_usleep(500); }
	expect(!sys::exists(root), "find: cleanup");
}
