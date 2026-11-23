module bmu::tests;
import std::io, std::core::string, libc;
import bmu::txt, bmu::sys, bmu::fileop, bmu::archive;

// Headless checks of bmu::archive (index + EXTRACT jobs) in a private temporary folder.
// Fixtures are made at test time with bsdtar / gzip / python3 (skipped with a note when missing).

char[256] aroot;
archive::Index aindex;

struct Ts { long sec; long nsec; }
extern fn CInt clock_gettime(CInt clk, Ts* ts);
fn long clock_us() { Ts t; clock_gettime(1, &t); return t.sec * 1000000 + t.nsec / 1000; }

fn String ap(String rel) => txt::join(txt::view(&aroot), rel);

fn bool sh(String cmd) => @pool() { return libc::system(cmd.zstr_tcopy()) == 0; }

fn archive::Phase index_of(String rel)
{
	aindex.close();
	if (!aindex.start(ap(rel))) return FAILED;
	for (int spins = 0; spins < 20000 && aindex.phase() == LOADING; spins++) sys::c_usleep(500);
	return aindex.phase();
}

fn String listing(String inner, bool hidden = false)
{
	sys::Entry[64] out;
	int n = aindex.list(inner, &out, hidden);
	DString s;
	s.init(tmem);
	for (int i = 0; i < n; i++)
	{
		if (i) s.append(",");
		s.append(txt::view(&out[i].name));
		if (out[i].dir) s.append("/");
	}
	return s.str_view();
}

fn fileop::Progress extract_run(String arc, String inner, String[] names, String dst, bool smart, fileop::Answer reply = KEEP_BOTH, bool cancel = false) => @pool()
{
	fileop::Job j;
	fileop::Progress p;
	if (!j.extract(ap(arc), inner, names, ap(dst), smart)) { p.state = FAILED; txt::set(&p.error, "start refused"); return p; }
	if (cancel) j.cancel();
	for (int spins = 0; spins < 40000; spins++)
	{
		if (j.finished(&p)) return p;
		j.status(&p);
		if (p.state == CONFLICT) j.answer(reply, true);
		sys::c_usleep(500);
	}
	j.close();
	p.state = FAILED;
	txt::set(&p.error, "timeout");
	return p;
}

fn String aget(String rel)
{
	String? s = sys::read_temp(ap(rel));
	if (catch s) return "<missing>";
	return s.copy(tmem);
}

fn bool athere(String rel) => @pool()
{
	libc::Stat st;
	return lstat(ap(rel).zstr_tcopy(), &st) == 0;
}

fn bool no_staging(String rel) => @pool()
{
	sys::Entry[64] list;
	int n = sys::list_dir(ap(rel), &list, true);
	for (int i = 0; i < n; i++) if (txt::view(&list[i].name).starts_with(".sms-")) return false;
	return true;
}

fn void check_archive() => @pool()
{
	expect(archive::is_archive("a.ZIP") && archive::is_archive("b.tar.gz") && archive::is_archive("c.7z") && archive::is_archive("d.gz"), "archive: extensions");
	expect(!archive::is_archive("notes.txt") && !archive::is_archive("zip"), "archive: non-archives");
	expect_str(archive::stem("foo.tar.gz"), "foo", "archive: stem tar.gz");
	expect_str(archive::stem("bar.zip"), "bar", "archive: stem zip");
	expect_str(archive::stem("notes.txt.xz"), "notes.txt", "archive: stem raw");
	expect_str(archive::stem(".zip"), ".zip", "archive: stem never empty");
	char[64] nb;
	expect(archive::normalize("./a//b/./c/", &nb) == 5 && txt::view(&nb) == "a/b/c", "archive: normalize");
	expect(archive::normalize("/abs/x", &nb) == 5 && txt::view(&nb) == "abs/x", "archive: leading slash dropped");
	expect(archive::normalize("a/../../x", &nb) == -1, "archive: dot-dot rejected");
	expect(archive::normalize("./", &nb) == 0, "archive: root");
	if (!archive::load()) { io::printn("note: libarchive not installed, archive checks skipped"); return; }
	if (!sh("command -v bsdtar >/dev/null && command -v gzip >/dev/null && command -v python3 >/dev/null"))
	{
		io::printn("note: bsdtar / gzip / python3 missing, archive fixture checks skipped");
		return;
	}
	txt::set(&aroot, "/tmp/bmu-archive-XXXXXX");
	if (!mkdtemp(&aroot)) { expect(false, "archive: mkdtemp"); return; }
	String r = txt::view(&aroot);
	sys::mkdirs(ap("src/dir/sub"));
	sys::mkdirs(ap("one/solo/inner"));
	sys::mkdirs(ap("out"));
	sys::mkdirs(ap("outside"));
	sys::write_file(ap("src/top.txt"), "top");
	sys::write_file(ap("src/.hidden"), "h");
	sys::write_file(ap("src/dir/a.txt"), "aaa");
	sys::write_file(ap("src/dir/sub/b.txt"), "bb");
	sys::write_file(ap("one/solo/inner/c.txt"), "c");
	expect(sh(string::tformat("cd '%s/src' && bsdtar --format zip -cf ../t.zip top.txt .hidden dir", r)), "archive: make zip");
	expect(sh(string::tformat("cd '%s/src' && bsdtar -czf ../t.tar.gz top.txt .hidden dir", r)), "archive: make tar.gz");
	expect(sh(string::tformat("cd '%s/src' && bsdtar -cJf ../t.tar.xz top.txt .hidden dir", r)), "archive: make tar.xz");
	expect(sh(string::tformat("cd '%s/src' && bsdtar --format 7zip -cf ../t.7z top.txt .hidden dir", r)), "archive: make 7z");
	// Only a deep file: its folders exist implicitly.
	expect(sh(string::tformat("cd '%s/src' && bsdtar --format zip -cf ../implied.zip dir/sub/b.txt", r)), "archive: make implied zip");
	expect(sh(string::tformat("cd '%s/one' && bsdtar -czf ../one.tgz solo", r)), "archive: make single-top tgz");
	expect(sh(string::tformat("gzip -c '%s/src/top.txt' > '%s/top.txt.gz'", r, r)), "archive: make bare gz");

	foreach (arc : (String[]){ "t.zip", "t.tar.gz", "t.tar.xz", "t.7z" })
	{
		expect(index_of(arc) == READY, string::tformat("archive: index %s", arc));
		expect_str(listing(""), "dir/,top.txt", string::tformat("archive: root of %s", arc));
		expect_str(listing("", true), "dir/,.hidden,top.txt", string::tformat("archive: hidden in %s", arc));
		expect_str(listing("dir"), "sub/,a.txt", string::tformat("archive: folder of %s", arc));
		int b = aindex.find("dir/sub/b.txt");
		expect(b >= 0 && aindex.size(b) == 2 && !aindex.is_dir(b) && aindex.name(b) == "b.txt", string::tformat("archive: entry of %s", arc));
		expect(aindex.has_dir("dir/sub") && !aindex.has_dir("top.txt") && !aindex.has_dir("nope"), string::tformat("archive: has_dir %s", arc));
	}
	expect(index_of("implied.zip") == READY && listing("") == "dir/" && listing("dir") == "sub/" && listing("dir/sub") == "b.txt", "archive: implied folders");
	expect(index_of("top.txt.gz") == READY && listing("") == "top.txt", "archive: bare gz is one entry");
	expect(index_of("missing.zip") == FAILED && aindex.error_text().len > 0, "archive: missing file fails");
	sys::write_file(ap("junk.zip"), "this is not an archive");
	expect(index_of("junk.zip") == FAILED, "archive: junk fails");
	aindex.close();

	// Extract here (smart): several top-level items -> folder named after the archive.
	fileop::Progress p = extract_run("t.tar.gz", "", {}, "out", true);
	expect(p.state == DONE, string::tformat("archive: smart extract (%s)", txt::view(&p.error)));
	expect(aget("out/t/top.txt") == "top" && aget("out/t/dir/sub/b.txt") == "bb" && athere("out/t/.hidden"), "archive: smart folder contents");
	expect(no_staging("out"), "archive: no staging left");
	// A single top-level item is placed as is.
	p = extract_run("one.tgz", "", {}, "out", true);
	expect(p.state == DONE && aget("out/solo/inner/c.txt") == "c" && !athere("out/one"), "archive: smart single item");
	// Again: conflict, keep both.
	p = extract_run("one.tgz", "", {}, "out", true, KEEP_BOTH);
	expect(p.state == DONE && aget("out/solo (2)/inner/c.txt") == "c", "archive: conflict keep both");
	p = extract_run("one.tgz", "", {}, "out", true, SKIP);
	expect(p.state == DONE && p.skipped == 1 && !athere("out/solo (3)") && no_staging("out"), "archive: conflict skip");
	// Subset of a folder, relative to it (zip, 7z).
	sys::mkdirs(ap("sub1"));
	p = extract_run("t.zip", "dir", { "sub" }, "sub1", false);
	expect(p.state == DONE && aget("sub1/sub/b.txt") == "bb" && !athere("sub1/a.txt") && !athere("sub1/dir"), "archive: subset relative to folder");
	sys::mkdirs(ap("sub2"));
	p = extract_run("t.7z", "", { "top.txt", "dir" }, "sub2", false);
	expect(p.state == DONE && aget("sub2/top.txt") == "top" && aget("sub2/dir/a.txt") == "aaa" && !athere("sub2/.hidden"), "archive: 7z names");
	sys::mkdirs(ap("raw"));
	p = extract_run("top.txt.gz", "", {}, "raw", true);
	expect(p.state == DONE && aget("raw/top.txt") == "top", "archive: bare gz extracts");
	p = extract_run("junk.zip", "", {}, "raw", true);
	expect(p.state == FAILED && p.error[0] && no_staging("raw"), "archive: junk extract fails cleanly");

	// Malicious entries: '..', absolute path, write through a symlink. Nothing may land outside the target.
	String py = string::tformat("import tarfile,io,sys\nt=tarfile.open(sys.argv[1],'w')\ndef add(n,d=b'x',link=None):\n i=tarfile.TarInfo(n)\n if link: i.type=tarfile.SYMTYPE; i.linkname=link; t.addfile(i)\n else: i.size=len(d); t.addfile(i,io.BytesIO(d))\nadd('../up.txt')\nadd('%s/outside/abs.txt')\nadd('lnk',link='%s/outside')\nadd('lnk/through.txt')\nadd('rel',link='../outside')\nadd('rel/through2.txt')\nadd('ok.txt')\nt.close()\n", r, r);
	sys::write_file(ap("mk.py"), py);
	expect(sh(string::tformat("python3 -I '%s/mk.py' '%s/evil.tar'", r, r)), "archive: make evil tar");
	sys::mkdirs(ap("victim"));
	p = extract_run("evil.tar", "", {}, "victim", false);
	sys::Entry[8] o;
	expect(sys::list_dir(ap("outside"), &o, true) == 0, "archive: nothing written outside");
	expect(!athere("up.txt"), "archive: dot-dot not written");
	expect(no_staging("victim"), "archive: evil leaves no staging");
	if (p.state == DONE) expect(aget("victim/ok.txt") == "x" && aget("victim/abs.txt") == "<missing>", "archive: evil safe parts");

	// Cancel right away: rolled back, nothing left.
	expect(sh(string::tformat("cd '%s' && head -c 33554432 /dev/urandom > big.bin && bsdtar -cf big.tar big.bin && rm big.bin", r)), "archive: make big tar");
	sys::mkdirs(ap("cancel"));
	p = extract_run("big.tar", "", {}, "cancel", true, KEEP_BOTH, true);
	sys::Entry[8] c;
	expect(p.state == CANCELLED && sys::list_dir(ap("cancel"), &c, true) == 0, "archive: cancel leaves nothing");

	// Closing an index while libarchive skips a slow (bzip2) entry returns at once: our reader stops it.
	expect(sh(string::tformat("cd '%s' && head -c 8388608 /dev/urandom > slow.bin && bsdtar -cjf slow.tar.bz2 slow.bin && rm slow.bin", r)), "archive: make slow tar.bz2");
	long full_us = clock_us();
	expect(index_of("slow.tar.bz2") == READY, "archive: slow index");
	full_us = clock_us() - full_us;
	aindex.close();
	expect(aindex.start(ap("slow.tar.bz2")), "archive: slow index restart");
	sys::c_usleep(20000);
	long t = clock_us();
	aindex.close();
	t = clock_us() - t;
	expect(t < 50000 && t * 4 < full_us, string::tformat("archive: close interrupts reading (%d us, full read %d us)", t, full_us));

	fileop::Job cleanup;
	if (cleanup.start(DELETE, "/tmp", { txt::basename(r) })) { while (!cleanup.finished(&p)) sys::c_usleep(500); }
	expect(!sys::exists(r), "archive: cleanup");
}
