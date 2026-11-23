module bmu::tests;
import std::io, std::core::string, libc;
import bmu::txt, bmu::sys, bmu::fileop;

// Elevated jobs without sudo: elevate_cmd = {} runs this test binary as its own helper (unprivileged), so the
// whole protocol (password line, token, job, progress, conflicts, cancel, errors) is exercised.

fileop::Job ejob;

fn fileop::Progress erun(fileop::Kind kind, String src, String[] names, String dst, fileop::Answer reply = KEEP_BOTH, bool cancel_on_conflict = false)
{
	fileop::Progress p;
	char[16] pw;
	txt::set(&pw, "not-needed");
	if (!ejob.start_elevated(kind, src, names, dst, &pw)) { p.state = FAILED; return p; }
	for (int spins = 0; spins < 40000; spins++)
	{
		if (ejob.finished(&p)) return p;
		ejob.status(&p);
		if (p.state == CONFLICT)
		{
			if (cancel_on_conflict) { ejob.cancel(); } else { ejob.answer(reply, true); }
		}
		sys::c_usleep(500);
	}
	ejob.close();
	p.state = FAILED;
	return p;
}

fn void check_elevated() => @pool()
{
	String[] saved = fileop::elevate_cmd;
	fileop::elevate_cmd = {};
	defer fileop::elevate_cmd = saved;
	char[64] dir;
	txt::set(&dir, "/tmp/bmu-elev-XXXXXX");
	if (!mkdtemp(&dir)) { expect(false, "elevated: mkdtemp"); return; }
	String root = txt::view(&dir);
	String a = txt::join(root, "a").copy(tmem);
	String b = txt::join(root, "b").copy(tmem);
	sys::mkdirs(txt::join(a, "tree/sub"));
	sys::mkdirs(b);
	sys::write_file(txt::join(a, "one.txt"), "one");
	sys::write_file(txt::join(a, "we\nird name"), "nl");
	sys::write_file(txt::join(a, "tree/sub/deep.txt"), "deep");

	fileop::Progress p = erun(COPY, a, { "one.txt", "tree", "we\nird name" }, b);
	expect(p.state == DONE, "elevated: copy done");
	expect(sys::is_file(txt::join(b, "tree/sub/deep.txt")) && sys::is_file(txt::join(b, "we\nird name")), "elevated: copied through helper (odd names too)");
	expect(p.bytes_total == 9, "elevated: progress relayed");

	p = erun(COPY, a, { "one.txt" }, b, KEEP_BOTH);
	expect(p.state == DONE && sys::is_file(txt::join(b, "one (2).txt")), "elevated: conflict answer relayed");
	p = erun(COPY, a, { "one.txt" }, b, cancel_on_conflict: true);
	expect(p.state == CANCELLED && !sys::is_file(txt::join(b, "one (3).txt")), "elevated: cancel relayed");

	p = erun(COPY, a, { "missing" }, b);
	expect(p.state == FAILED && p.err == 2 && txt::view(&p.error).contains("missing"), "elevated: error and errno relayed");

	p = erun(DELETE, b, { "tree", "gone-already" }, "");
	expect(p.state == DONE && !sys::exists(txt::join(b, "tree")), "elevated: delete, missing item skipped");

	char[16] pw;
	txt::set(&pw, "x");
	expect(!ejob.start_elevated(TRASH, a, { "one.txt" }, "", &pw), "elevated: no trash as root");

	// A sudo that rejects the password.
	fileop::elevate_cmd = { "sh", "-c", "echo 'Sorry, try again.' >&2; sleep 10", "fake-sudo" };
	p = erun(COPY, a, { "one.txt" }, b);
	expect(p.state == FAILED && txt::view(&p.error) == "Wrong password", "elevated: wrong password detected");
	// A sudo that refuses outright.
	fileop::elevate_cmd = { "sh", "-c", "echo 'sudo: david is not in the sudoers file.' >&2; exit 1", "fake-sudo" };
	p = erun(COPY, a, { "one.txt" }, b);
	expect(p.state == FAILED && txt::view(&p.error).contains("not in the sudoers file"), "elevated: sudo refusal reported");

	fileop::Job cleanup;
	if (cleanup.start(DELETE, "/tmp", { txt::basename(root) })) { while (!cleanup.finished(&p)) sys::c_usleep(500); }
	expect(!sys::exists(root), "elevated: cleanup");
}
