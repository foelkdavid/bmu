module bmu::fileop @feat(LINUX);
import std::core::string, libc;
import bmu::txt, bmu::sys;

// Running operations, visible to every process of the user (e.g. all windows of a file manager): while a COPY,
// MOVE, TRASH, DELETE or RESTORE job works, its worker keeps a small record (kind, source folder, item names) in
// registry_dir(); it is removed when the job ends. A `Busy` reader watches that folder (inotify) and answers
// "is this entry part of a running operation?" from memory. Records of dead processes are ignored and removed.

const int BUSY_MAX_JOBS = 32;               // records read at once (more are ignored)
const usz BUSY_MAX_RECORD = 8 * 1024 * 1024; // bytes per record (16384 names of up to 255 bytes fit)

extern fn CInt c_getuid() @cname("getuid") @private;
extern fn CInt c_unlink_rec(ZString path) @cname("unlink") @private;

bool helper_mode @private;   // the root helper never publishes (its parent's job already does)

<* The registry folder: $XDG_RUNTIME_DIR/bmu-fileop, else /tmp/bmu-fileop-UID (created 0700 when missing). *>
fn bool registry_dir(char[] out) => @pool()
{
	ZString rt = libc::getenv("XDG_RUNTIME_DIR");
	String dir = rt && rt.str_view().len ? txt::join(rt.str_view(), "bmu-fileop") : string::tformat("/tmp/bmu-fileop-%d", c_getuid());
	if (dir.len >= out.len) return false;
	txt::set(out, dir);
	sys::c_mkdir(zp(out), 0o700);
	return sys::is_dir(dir);
}

fn bool publishes(Kind k) @private => k == COPY || k == MOVE || k == TRASH || k == DELETE || k == RESTORE;

<* Write a record (temporary name, then renamed into place: readers never see half a record). *>
fn bool write_record(ulong id, Kind kind, bool queued, String src_dir, String[] names, char[] out, bool ui_thread = false) @private => @pool()
{
	char[4096] dir;
	if (!registry_dir(&dir)) return false;
	int pid = c_getpid();
	String final = txt::join(txt::view(&dir), string::tformat("%d-%x", pid, id));
	// The UI thread (cancel_item) and the worker may rewrite the same record: separate temporary names.
	String tmp = txt::join(txt::view(&dir), string::tformat(".%d-%x%s.tmp", pid, id, ui_thread ? "-ui" : ""));
	DString body;
	body.tinit();
	body.appendf("bmu-fileop2\0%d\0%d\0%d\0%s\0", (int)kind, pid, queued ? 1 : 0, src_dir);
	foreach (n : names) { body.append(n); body.append_char('\0'); }
	CInt fd = sys::c_open(tmp.zstr_tcopy(), O_WRONLY | O_CREAT | 0x200 | O_CLOEXEC, (CInt)0o600); // O_TRUNC
	if (fd < 0) return false;
	bool ok = write_str(fd, body.str_view());
	sys::c_close(fd);
	if (!ok || sys::c_rename(tmp.zstr_tcopy(), final.zstr_tcopy()) != 0) { c_unlink_rec(tmp.zstr_tcopy()); return false; }
	txt::set(out, final);
	return true;
}

<* Worker: (re)write this job's record with the items still in it (left out or asked to be: not listed). *>
fn void announce(Job* j) @private => @pool()
{
	if (helper_mode || !publishes(j.kind) || !j.count) { j.record[0] = 0; return; }
	if (!write_record(j.id(), j.kind, false, txt::view(&j.src_dir), kept_names(j), &j.record)) j.record[0] = 0;
}

<* UI thread, cancel_item: the item leaves the record at once (other processes unmark it now, not after its undo). *>
fn void reannounce(Job* j) @private => @pool()
{
	if (helper_mode || !publishes(j.kind) || !j.record[0]) return;
	char[4096] ignored;
	write_record(j.id(), j.kind, false, txt::view(&j.src_dir), kept_names(j), &ignored, true);
}

fn String[] kept_names(Job* j) @private
{
	String[] names = mem::talloc_array(String, (usz)j.count);
	int n;
	j.mutex.lock();
	for (int i = 0; i < j.count; i++) if (!j.items[i].drop && j.items[i].st != CANCELLED) names[n++] = src_name(j, i);
	j.mutex.unlock();
	return names[:n];
}

<*
 Publish a request that waits in this process's own queue (no Job running yet), so other processes can mark its
 items too (BusyHit.queued). Pass the Job that will run it: its record replaces this one when it starts, under
 the same name. Call again after the request changed; unpublish() when it is dropped without starting.
 One small file write (tmpfs): call on the event, not per frame.
*>
fn bool publish_queued(Job* job, Kind kind, String src_dir, String[] names, char[] record)
{
	if (!publishes(kind)) return false;
	return write_record(job.id(), kind, true, src_dir, names, record);
}

<* Remove a record written by publish_queued (no-op when `record` is ""). *>
fn void unpublish(char[] record)
{
	if (record[0]) c_unlink_rec(zp(record));
	record[0] = 0;
}

<* Worker, at the end: remove the record. *>
fn void retract(Job* j) @private
{
	if (j.record[0]) c_unlink_rec(zp(&j.record));
	j.record[0] = 0;
}

<* One running operation as a Busy reader sees it. *>
struct BusyJob
{
	Kind kind;
	int pid;
	bool own;            // started by this process
	bool queued;         // waits in that process's queue (publish_queued), not running yet
	ulong id;            // Job.id() of that job (in its process)
	char[4096] src_dir;
}

<* What Busy.find knows about an entry. *>
struct BusyHit
{
	bool found;
	Kind kind;
	bool own;            // a job of this process: `item` indexes its Job.item_status
	int item;            // index of the name in its job
	ulong job;           // its Job.id(): with `own`, which of this process's jobs
	bool queued;         // its operation waits in a queue (not running yet)
}

struct BusySlot @private
{
	uint off;            // name offset in the blob + 1 (0 = empty slot)
	int item;
	short job;
}

<*
 Reader of the registry. open() once (creates and watches the folder, reads it), then call poll() every frame:
 one non-blocking inotify read; on a change it rereads the records (small files on tmpfs) and returns true, so
 the app recomputes its marks then, never per frame. find() is a hash lookup. Zero-initialize at a stable address.
*>
struct Busy
{
	sys::DirWatch watch;
	bool opened;
	int jobs;
	BusyJob[BUSY_MAX_JOBS] job;
	char* blob;
	usz blob_len;
	BusySlot* slots;
	uint mask;
	int count;           // names of all running operations
}

fn bool Busy.open(&self)
{
	char[4096] dir;
	if (!registry_dir(&dir)) return false;
	self.opened = self.watch.watch(txt::view(&dir));
	self.load();
	return self.opened;
}

<* True when the running operations changed since the last call (the records were reread). *>
fn bool Busy.poll(&self)
{
	if (!self.opened || !self.watch.changed()) return false;
	self.load();
	return true;
}

<* True when a running operation works on entries of `dir` (cheap: compare with each job's folder). *>
fn bool Busy.has_dir(&self, String dir)
{
	for (int i = 0; i < self.jobs; i++) if (txt::view(&self.job[i].src_dir) == dir) return true;
	return false;
}

fn uint name_hash(String s, int job) @private
{
	uint h = 2166136261 ^ (uint)job;
	foreach (c : s) { h ^= c; h *= 16777619; }
	return h;
}

<* Is `dir`/`name` part of a running operation? *>
fn BusyHit Busy.find(&self, String dir, String name)
{
	if (!self.count) return {};
	for (int j = 0; j < self.jobs; j++)
	{
		if (txt::view(&self.job[j].src_dir) != dir) continue;
		for (uint h = name_hash(name, j) & self.mask;; h = (h + 1) & self.mask)
		{
			BusySlot* s = &self.slots[h];
			if (!s.off) break;
			if (s.job == j && ((ZString)(self.blob + s.off - 1)).str_view() == name)
			{
				return { .found = true, .kind = self.job[j].kind, .own = self.job[j].own, .item = s.item, .job = self.job[j].id, .queued = self.job[j].queued };
			}
		}
	}
	return {};
}

<* Forget the records read so far (load() rereads them). *>
fn void Busy.clear(&self)
{
	libc::free(self.blob);
	libc::free(self.slots);
	self.blob = null;
	self.slots = null;
	self.blob_len = 0;
	self.jobs = 0;
	self.count = 0;
	self.mask = 0;
}

fn void Busy.close(&self)
{
	self.clear();
	self.watch.close();
	self.opened = false;
}

fn bool pid_alive(int pid) @private => sys::c_kill(pid, 0) == 0 || *c_errno() == 1; // EPERM: alive, not ours

<* Reread every record (UI thread, on a change only). *>
fn void Busy.load(&self) => @pool()
{
	self.clear();
	char[4096] dir;
	if (!registry_dir(&dir)) return;
	sys::Entry[64] list;
	int n = sys::list_dir(txt::view(&dir), &list, false);
	String[BUSY_MAX_JOBS] bodies;
	int me = c_getpid();
	usz total;
	for (int i = 0; i < n && self.jobs < BUSY_MAX_JOBS; i++)
	{
		String path = txt::join(txt::view(&dir), txt::view(&list[i].name));
		String? body = sys::read_temp(path);
		if (catch body) continue;
		if (body.len > BUSY_MAX_RECORD) continue;
		bool v2 = body.starts_with("bmu-fileop2\0");
		String[] f = body.tsplit("\0", v2 ? 5 : 4);
		if (f.len < (v2 ? 5 : 4) || (f[0] != "bmu-fileop1" && !v2)) continue;
		int? kind = f[1].to_int();
		int? pid = f[2].to_int();
		if (catch kind) continue;
		if (catch pid) continue;
		bool queued = v2 && f[3] == "1";
		if (v2) f[3] = f[4];
		if (kind < 0 || kind > (int)Kind.EXTRACT || f[3].len == 0) continue;
		if (!pid_alive(pid)) { c_unlink_rec(path.zstr_tcopy()); continue; } // left by a crashed process
		String rest = f[3];                      // "src_dir\0name\0name\0…"
		sz? zero = rest.index_of_char('\0');
		usz dir_end = rest.len;
		if (try zero) dir_end = (usz)zero;
		if (dir_end >= 4096) continue;
		BusyJob* bj = &self.job[self.jobs];
		*bj = { .kind = (Kind)kind, .pid = pid, .own = pid == me, .queued = queued };
		String fname = txt::view(&list[i].name);   // "PID-JOBHEX"
		sz? dash = fname.index_of_char('-');
		if (try dash) foreach (c : fname[(usz)dash + 1..]) bj.id = bj.id * 16 + (ulong)(c >= 'a' ? c - 'a' + 10 : c - '0');
		txt::set(&bj.src_dir, rest[:dir_end]);
		bodies[self.jobs] = dir_end < rest.len ? rest[dir_end + 1..] : "";
		total += bodies[self.jobs].len + 1;
		self.jobs++;
	}
	if (!self.jobs) return;
	self.blob = libc::malloc(total + 1);
	if (!self.blob) { self.clear(); return; }
	int names;
	for (int j = 0; j < self.jobs; j++)
	{
		libc::memcpy(self.blob + self.blob_len, bodies[j].ptr, bodies[j].len);
		self.blob_len += bodies[j].len;
		self.blob[self.blob_len++] = 0;
		foreach (c : bodies[j]) if (c == 0) names++;
	}
	uint size = 64;
	while (size < (uint)names * 2) size *= 2;
	self.slots = libc::calloc(size, BusySlot::size);
	if (!self.slots) { self.clear(); return; }
	self.mask = size - 1;
	usz at;
	for (int j = 0; j < self.jobs; j++)
	{
		usz end = at + bodies[j].len;
		int item;
		while (at < end)
		{
			String name = ((ZString)(self.blob + at)).str_view();
			if (name.len)
			{
				uint h = name_hash(name, j) & self.mask;
				while (self.slots[h].off) h = (h + 1) & self.mask;
				self.slots[h] = { .off = (uint)at + 1, .item = item, .job = (short)j };
				self.count++;
			}
			item++;
			at += name.len + 1;
		}
		at = end + 1;
	}
}
