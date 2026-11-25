module bmu::tests;
import std::io, std::core::string, libc;
import bmu::txt, bmu::sys, bmu::fileop;

// Headless checks of bmu::fileop in a private temporary folder (also used as XDG_DATA_HOME for the trash).

extern fn ZString mkdtemp(char* template) @cname("mkdtemp");
extern fn CInt setenv(ZString name, ZString value, CInt overwrite) @cname("setenv");
extern fn CInt symlink(ZString target, ZString path) @cname("symlink");
extern fn sz readlink(ZString path, char* buf, usz n) @cname("readlink");
extern fn CInt lstat(ZString path, libc::Stat* st) @cname("lstat");

char[256] root;
fileop::Job job;
fileop::Busy busy;   // ~130 KB: global, like in an app

fn String at(String rel) => txt::join(txt::view(&root), rel);

fn void put(String rel, String data) => @pool() { sys::write_file(at(rel), data); }

fn String get(String rel)
{
	String? s = sys::read_temp(at(rel));
	if (catch s) return "<missing>";
	return s.copy(tmem);
}

fn bool there(String rel) => @pool()
{
	libc::Stat st;
	return lstat(at(rel).zstr_tcopy(), &st) == 0;
}

<* Run a job to the end, answering conflicts with `reply`; returns the final progress. *>
fn fileop::Progress run(fileop::Kind kind, String src, String[] names, String dst = "", fileop::Answer reply = KEEP_BOTH, bool cancel_on_conflict = false) => @pool()
{
	fileop::Progress p;
	if (!job.start(kind, at(src), names, dst.len ? at(dst) : "")) { p.state = FAILED; txt::set(&p.error, "start refused"); return p; }
	for (int spins = 0; spins < 20000; spins++)
	{
		if (job.finished(&p)) return p;
		job.status(&p);
		if (p.state == CONFLICT)
		{
			if (cancel_on_conflict) { job.cancel(); } else { job.answer(reply, true); }
		}
		sys::c_usleep(500);
	}
	job.close();
	p.state = FAILED;
	txt::set(&p.error, "timeout");
	return p;
}

fn bool no_temporaries(String rel) => @pool()
{
	sys::Entry[64] list;
	int n = sys::list_dir(at(rel), &list, true);
	for (int i = 0; i < n; i++) if (txt::view(&list[i].name).starts_with(".sms-")) return false;
	return true;
}

fn void check_fileop() => @pool()
{
	txt::set(&root, "/tmp/bmu-fileop-XXXXXX");
	if (!mkdtemp(&root)) { expect(false, "fileop: mkdtemp"); return; }
	setenv("XDG_DATA_HOME", at("data").zstr_tcopy(), 1);
	sys::mkdirs(at("a/tree/sub"));
	sys::mkdirs(at("b"));
	put("a/one.txt", "one");
	put("a/tree/x.txt", "x");
	put("a/tree/sub/y.txt", "yy");
	symlink("x.txt", at("a/tree/link").zstr_tcopy());

	// Per-item progress: read before finished() reaps the job.
	sys::mkdirs(at("items"));
	fileop::ItemProgress[3] ip;
	int got = -1;
	if (job.start(COPY, at("a"), { "one.txt", "tree" }, at("items")))
	{
		expect(job.item_count() == 2, "fileop: item_count");
		fileop::Progress q;
		for (int spins = 0; spins < 20000; spins++)
		{
			job.status(&q);
			if (q.state == DONE || q.state == FAILED) break;
			sys::c_usleep(500);
		}
		got = job.item_status(0, &ip);
		expect(job.item_status(2, &ip) == 0, "fileop: item_status past the end");
		while (!job.finished(&q)) sys::c_usleep(500);
	}
	expect(got == 2, "fileop: item_status fills both items");
	expect(ip[0].state == DONE && ip[1].state == DONE, "fileop: items done");
	expect_str(txt::view(&ip[1].name), "tree", "fileop: item name");
	expect(ip[0].files_total == 1 && ip[0].bytes_done == 3 && ip[0].bytes_total == 3, "fileop: file item counts");
	expect(ip[1].files_total == 5 && ip[1].files_done == 5 && ip[1].bytes_total == 3 && ip[1].bytes_done == 3, "fileop: tree item counts (dir, sub, 2 files, link)");
	expect(job.item_count() == 0, "fileop: no items when idle");

	// Copy a file and a folder tree (with a symlink); sources stay.
	fileop::Progress p = run(COPY, "a", { "one.txt", "tree" }, "b");
	expect(p.state == DONE, "fileop: copy done");
	expect_str(get("b/one.txt"), "one", "fileop: copied file");
	expect_str(get("b/tree/sub/y.txt"), "yy", "fileop: copied nested file");
	char[64] lt;
	sz ln = readlink(at("b/tree/link").zstr_tcopy(), &lt, 63);
	expect(ln == 5 && lt[:5] == "x.txt", "fileop: symlink copied as link");
	expect(p.bytes_total == 6 && p.bytes_done == 6, "fileop: byte totals");
	expect(there("a/one.txt") && there("a/tree/x.txt"), "fileop: copy keeps sources");
	expect(no_temporaries("b"), "fileop: no temporaries after copy");

	// Same-folder copy gets a "(copy)" name.
	p = run(COPY, "a", { "one.txt" }, "a");
	expect(p.state == DONE && get("a/one (copy).txt") == "one", "fileop: same-folder copy name");

	// Conflicts: keep both, skip, replace.
	put("a/one.txt", "new");
	p = run(COPY, "a", { "one.txt" }, "b", KEEP_BOTH);
	expect(p.state == DONE && get("b/one (2).txt") == "new" && get("b/one.txt") == "one", "fileop: keep both");
	p = run(COPY, "a", { "one.txt" }, "b", SKIP);
	expect(p.state == DONE && p.skipped == 1 && get("b/one.txt") == "one", "fileop: skip");
	p = run(COPY, "a", { "one.txt" }, "b", REPLACE);
	expect(p.state == DONE && get("b/one.txt") == "new", "fileop: replace file");
	p = run(COPY, "a", { "one.txt" }, "b", cancel_on_conflict: true);
	expect(p.state == CANCELLED && get("b/one.txt") == "new", "fileop: cancel at conflict changes nothing");
	expect(no_temporaries("b"), "fileop: no temporaries after replace/cancel");

	// Replace a folder with a file of the same name (moved aside, deleted after the commit).
	put("a/tree2", "file now");
	sys::mkdirs(at("b/tree2/deep"));
	p = run(COPY, "a", { "tree2" }, "b", REPLACE);
	expect(p.state == DONE && get("b/tree2") == "file now", "fileop: replace folder by file");

	// Folder into itself and replacing an ancestor of the source are refused without changes.
	p = run(COPY, "a", { "tree" }, "a/tree/sub");
	expect(p.state == FAILED && !there("a/tree/sub/tree"), "fileop: refuse copy into itself");
	sys::mkdirs(at("c/c"));
	put("c/c/keep.txt", "k");
	p = run(MOVE, "c/c", { "keep.txt" }, "c");
	expect(p.state == DONE && there("c/keep.txt"), "fileop: move up");
	put("c/c/c", "inner");
	p = run(MOVE, "c/c", { "c" }, "c", REPLACE);
	expect(p.state == FAILED && get("c/c/c") == "inner", "fileop: refuse replacing a folder containing the source");

	// Same-filesystem move is a rename.
	p = run(MOVE, "a", { "tree" }, "b", KEEP_BOTH);
	expect(p.state == DONE && !there("a/tree") && get("b/tree (2)/sub/y.txt") == "yy", "fileop: move (rename)");

	// Cross-filesystem move (when /dev/shm is a different filesystem): copy, sync, delete sources.
	libc::Stat s1, s2;
	if (libc::stat("/dev/shm", &s2) == 0 && libc::stat(txt::z(&root), &s1) == 0 && s1.st_dev != s2.st_dev)
	{
		char[64] other;
		txt::set(&other, "/dev/shm/bmu-fileop-XXXXXX");
		if (mkdtemp(&other))
		{
			p = run(MOVE, "b", { "tree" }, "", KEEP_BOTH);
			expect(p.state == FAILED, "fileop: move needs a target");
			if (job.start(MOVE, at("b"), { "tree" }, txt::view(&other)))
			{
				while (!job.finished(&p)) sys::c_usleep(500);
				String moved = txt::join(txt::view(&other), "tree/sub/y.txt");
				expect(p.state == DONE && sys::is_file(moved) && !there("b/tree"), "fileop: cross-filesystem move");
				expect(p.remove_total > 0 && p.removed == p.remove_total, "fileop: cross-filesystem move counts removed sources");
			}
			if (job.start(DELETE, "/dev/shm", { txt::basename(txt::view(&other)) })) { while (!job.finished(&p)) sys::c_usleep(500); }
		}
	}

	// Cancel right after start: either finished or fully rolled back, never half.
	sys::mkdirs(at("big"));
	for (int i = 0; i < 40; i++) put(string::tformat("big/f%d", i), "0123456789");
	if (job.start(COPY, at("."), { "big" }, at("b")))
	{
		job.cancel();
		while (!job.finished(&p)) sys::c_usleep(500);
		expect((p.state == CANCELLED && !there("b/big")) || (p.state == DONE && there("b/big/f39")), "fileop: cancel is all-or-nothing");
		expect(no_temporaries("b"), "fileop: no temporaries after cancel");
	}

	// COUNT adds up without changing anything (big: 40 files of 10 bytes + the folder).
	p = run(COUNT, ".", { "big" });
	expect(p.state == DONE && p.files_total == 41 && p.bytes_total == 400 && there("big/f0"), "fileop: count");

	// Trash (freedesktop layout under XDG_DATA_HOME) and permanent delete.
	expect(fileop::can_trash(at("a/one.txt")), "fileop: can_trash same filesystem");
	p = run(TRASH, "a", { "one.txt" });
	expect(p.state == DONE && !there("a/one.txt") && get("data/Trash/files/one.txt") == "new", "fileop: trash moves file");
	String info = get("data/Trash/info/one.txt.trashinfo");
	expect(info.starts_with("[Trash Info]\nPath=/tmp/bmu-fileop-") && info.contains("DeletionDate="), "fileop: trashinfo written");
	put("a/one.txt", "again");
	p = run(TRASH, "a", { "one.txt" });
	expect(p.state == DONE && get("data/Trash/files/one.txt.2") == "again", "fileop: trash name collision");
	p = run(DELETE, "data/Trash/files", { "one.txt" });
	expect(p.state == DONE && !there("data/Trash/files/one.txt") && !there("data/Trash/info/one.txt.trashinfo") && there("data/Trash/info/one.txt.2.trashinfo"), "fileop: delete in trash removes its info");
	p = run(DELETE, "b", { "tree2", "one.txt" });
	expect(p.state == DONE && p.files_done == 2 && !there("b/tree2") && !there("b/one.txt"), "fileop: delete");

	// Restore: back to the original path (parent recreated), record removed; conflicts keep both.
	sys::mkdirs(at("r/deep"));
	put("r/deep/doc.txt", "doc");
	p = run(TRASH, "r/deep", { "doc.txt" });
	expect(p.state == DONE && !there("r/deep/doc.txt"), "fileop: trash before restore");
	p = run(DELETE, "r", { "deep" });
	p = run(RESTORE, "data/Trash/files", { "doc.txt" });
	expect(p.state == DONE && get("r/deep/doc.txt") == "doc" && !there("data/Trash/files/doc.txt") && !there("data/Trash/info/doc.txt.trashinfo"), "fileop: restore recreates folder");
	p = run(TRASH, "r/deep", { "doc.txt" });
	put("r/deep/doc.txt", "newer");
	p = run(RESTORE, "data/Trash/files", { "doc.txt" }, reply: KEEP_BOTH);
	expect(p.state == DONE && get("r/deep/doc.txt") == "newer" && get("r/deep/doc (2).txt") == "doc", "fileop: restore keep both");
	put("r/deep/x.txt", "x1");
	p = run(TRASH, "r/deep", { "x.txt" });
	put("r/deep/x.txt", "x2");
	p = run(RESTORE, "data/Trash/files", { "x.txt" }, reply: REPLACE);
	expect(p.state == DONE && get("r/deep/x.txt") == "x1" && no_temporaries("r/deep"), "fileop: restore replace");
	p = run(RESTORE, "data/Trash/files", { "missing.txt" });
	expect(p.state == FAILED, "fileop: restore without record fails");
	put("r/sp ace%.txt", "s");
	p = run(TRASH, "r", { "sp ace%.txt" });
	char[4096] origin;
	char[32] when;
	expect(fileop::trash_info(at("data/Trash/files"), "sp ace%.txt", &origin, &when) && txt::view(&origin) == at("r/sp ace%.txt") && txt::view(&when).len == 19 && when[10] == ' ', "fileop: trash_info path and date");
	expect(!fileop::trash_info(at("data/Trash/files"), "nope", &origin), "fileop: trash_info missing record");
	p = run(RESTORE, "data/Trash/files", { "sp ace%.txt" });
	expect(p.state == DONE && get("r/sp ace%.txt") == "s", "fileop: restore decodes percent-encoding");

	// Busy registry: a job paused at a name conflict is visible to readers; it disappears when the job ends.
	setenv("XDG_RUNTIME_DIR", at("run").zstr_tcopy(), 1);
	sys::mkdirs(at("run"));
	sys::mkdirs(at("busy/src"));
	sys::mkdirs(at("busy/dst"));
	put("busy/src/one", "1");
	put("busy/src/two", "2");
	put("busy/dst/two", "old");
	expect(busy.open(), "fileop: busy open");
	expect(!busy.has_dir(at("busy/src")), "fileop: busy empty at first");
	put("run/bmu-fileop/999999999-1", "bmu-fileop1\0" "1\0" "999999999\0/nowhere\0ghost\0");
	if (job.start(COPY, at("busy/src"), { "one", "two" }, at("busy/dst")))
	{
		for (int spins = 0; spins < 20000 && !job.finished(&p); spins++)
		{
			job.status(&p);
			if (p.state == CONFLICT) break;
			sys::c_usleep(500);
		}
		busy.poll();
		fileop::BusyHit h = busy.find(at("busy/src"), "two");
		expect(busy.has_dir(at("busy/src")) && h.found && h.own && h.kind == COPY && h.item == 1 && h.job == job.id(), "fileop: busy finds a running item");
		expect(!busy.find(at("busy/src"), "three").found && !busy.find(at("busy"), "two").found, "fileop: busy misses others");
		expect(!busy.has_dir("/nowhere") && !there("run/bmu-fileop/999999999-1"), "fileop: busy drops records of dead processes");
		job.answer(SKIP, true);
		while (!job.finished(&p)) sys::c_usleep(500);
		busy.poll();
		expect(!busy.find(at("busy/src"), "two").found && busy.count == 0, "fileop: busy record removed at the end");
	}
	else { expect(false, "fileop: busy job start"); }
	busy.close();

	// cancel_item: one item left out (asked while the job waits on a conflict), the rest is copied.
	sys::mkdirs(at("drop/src"));
	sys::mkdirs(at("drop/dst"));
	put("drop/src/keep1", "k1");
	put("drop/src/gone", "gone!");
	put("drop/src/keep2", "k2");
	put("drop/dst/keep2", "old");
	expect(!job.cancel_item(0), "fileop: cancel_item refused when idle");
	if (job.start(COPY, at("drop/src"), { "keep1", "gone", "keep2" }, at("drop/dst")))
	{
		for (int spins = 0; spins < 20000; spins++)
		{
			job.status(&p);
			if (p.state == CONFLICT) break;
			sys::c_usleep(500);
		}
		expect(job.cancel_item(1), "fileop: cancel_item accepted");
		expect(!job.cancel_item(1), "fileop: cancel_item only once");
		fileop::ItemProgress[3] dip;
		job.answer(KEEP_BOTH, true);
		for (int spins = 0; spins < 20000; spins++)
		{
			job.status(&p);
			if (p.state == DONE || p.state == FAILED) break;
			sys::c_usleep(500);
		}
		job.item_status(0, &dip);
		while (!job.finished(&p)) sys::c_usleep(500);
		expect(p.state == DONE && p.dropped == 1 && p.bytes_total == 4 && p.bytes_done == 4, "fileop: dropped item left out of the totals");
		expect(dip[1].state == CANCELLED && dip[0].state == DONE && dip[2].state == DONE, "fileop: item states after cancel_item");
		expect(!there("drop/dst/gone") && get("drop/dst/keep1") == "k1" && get("drop/dst/keep2 (2)") == "k2", "fileop: the rest was copied");
		expect(no_temporaries("drop/dst"), "fileop: no temporaries after cancel_item");
	}
	else { expect(false, "fileop: cancel_item job start"); }

	// cancel_item while the item is being copied (or right after: then it is undone before the commit).
	sys::mkdirs(at("drop2/dst"));
	sys::mkdirs(at("drop2/src"));
	put("drop2/src/small", "s");
	{
		char[] big = mem::new_array(char, 64 * 1024 * 1024);
		defer free(big);
		sys::write_file(at("drop2/src/big"), (String)big);
	}
	if (job.start(COPY, at("drop2/src"), { "big", "small" }, at("drop2/dst")))
	{
		fileop::ItemProgress[2] dip;
		bool asked;
		for (int spins = 0; spins < 40000 && !asked; spins++)
		{
			job.status(&p);
			if (p.state == DONE || p.state == FAILED) break;
			if (job.item_status(0, &dip) == 2 && dip[0].state != WAITING) asked = job.cancel_item(0);
			sys::c_usleep(100);
		}
		for (int spins = 0; spins < 40000; spins++)
		{
			job.status(&p);
			if (p.state == DONE || p.state == FAILED) break;
			sys::c_usleep(500);
		}
		job.item_status(0, &dip);
		while (!job.finished(&p)) sys::c_usleep(500);
		expect(asked, "fileop: cancel_item while copying accepted");
		expect(p.state == DONE && dip[0].state == CANCELLED && !there("drop2/dst/big") && get("drop2/dst/small") == "s", "fileop: item left out mid-copy, the rest copied");
		expect(p.bytes_total == 1 && p.bytes_done == 1 && no_temporaries("drop2/dst"), "fileop: totals and temporaries after a mid-copy drop");
	}
	else { expect(false, "fileop: mid-copy drop start"); }

	expect(!job.start(COPY, "relative", { "x" }, "/tmp"), "fileop: refuse relative source");
	expect(!job.start(COPY, "/tmp", { "a/b" }, "/tmp"), "fileop: refuse names with slash");
	expect(!job.busy(), "fileop: idle after refusals");

	if (job.start(DELETE, "/tmp", { txt::basename(txt::view(&root)) })) { while (!job.finished(&p)) sys::c_usleep(500); }
	expect(!sys::exists(txt::view(&root)), "fileop: cleanup");
}
