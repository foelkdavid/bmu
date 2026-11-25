module bmu::fileop @feat(LINUX);
import std::thread, std::core::string, std::math, std::time::clock, libc;
import bmu::txt, bmu::sys, bmu::archive;

// bmu::fileop - background copy / move / trash / delete for file managers (Linux x86_64, no raylib).
//
// One Job runs one operation on a worker thread. The UI thread polls status() every frame (one mutex
// lock + a small copy, no I/O), answers name conflicts, can cancel, and calls finished() to reap.
//
// Safety model (all-or-nothing for COPY / MOVE):
//   1. Plan: every item is checked and every name conflict is answered BEFORE anything is written.
//   2. Same-filesystem moves are rename(2) (instant, nothing copied). Copies and cross-filesystem
//      moves are written to a hidden temporary name (`.sms-part-PID-N`) in the target folder.
//   3. Cancel or error before the commit: temporaries are removed, renamed items are renamed back,
//      replaced items are restored. Sources are never modified.
//   4. Commit (not cancellable, fast): temporaries are renamed into place without overwriting
//      (renameat2 RENAME_NOREPLACE); a replaced item is moved aside first and deleted only afterwards.
//      Cross-filesystem moves call syncfs() on the target before the sources are deleted.
// Copied data is flushed to the target disk while copying (syncfs every FLUSH_STEP bytes or FLUSH_TIME, and once
// more before the commit), and progress counts flushed bytes: the bar follows the disk's real speed, cancel works the
// whole time, and the commit never waits for gigabytes still in the page cache.
// TRASH follows the freedesktop.org Trash spec (home trash only). DELETE is permanent.
// EXTRACT unpacks an archive (bmu::archive) into a hidden staging folder in the target, then commits the
// staged items like a same-filesystem MOVE (conflicts asked, rollback on cancel, staging always removed).

extern fn CInt c_lstat(ZString path, libc::Stat* st) @cname("lstat") @private;
extern fn CInt c_stat(ZString path, libc::Stat* st) @cname("stat") @private;
extern fn sz c_copy_file_range(CInt fd_in, long* off_in, CInt fd_out, long* off_out, usz len, CUInt flags) @cname("copy_file_range") @private;
extern fn sz c_read(CInt fd, void* buf, usz n) @cname("read") @private;
extern fn sz c_write(CInt fd, void* buf, usz n) @cname("write") @private;
extern fn CInt c_unlink(ZString path) @cname("unlink") @private;
extern fn CInt c_rmdir(ZString path) @cname("rmdir") @private;
extern fn CInt c_symlink(ZString target, ZString path) @cname("symlink") @private;
extern fn sz c_readlink(ZString path, char* buf, usz n) @cname("readlink") @private;
extern fn CInt c_fchmod(CInt fd, uint mode) @cname("fchmod") @private;
extern fn CInt c_chmod(ZString path, uint mode) @cname("chmod") @private;
extern fn CInt c_futimens(CInt fd, Timespec* times) @cname("futimens") @private;
extern fn CInt c_utimensat(CInt dirfd, ZString path, Timespec* times, CInt flags) @cname("utimensat") @private;
extern fn CInt c_syncfs(CInt fd) @cname("syncfs") @private;
extern fn long c_syscall(long n, ...) @cname("syscall") @private;
extern fn CInt c_getpid() @cname("getpid") @private;
extern fn CInt* c_errno() @cname("__errno_location") @private;
extern fn void explicit_bzero(void* p, usz n) @cname("explicit_bzero") @private;
extern fn CInt c_pipe2(CInt* fds, CInt flags) @cname("pipe2") @private;
extern fn CInt c_poll(PollFd* fds, ulong n, CInt timeout) @cname("poll") @private;
extern fn CUInt c_geteuid() @cname("geteuid") @private;
extern fn sz c_readlink_exe(ZString path, char* buf, usz n) @cname("readlink") @private;
extern fn CInt c_getrandom(void* buf, usz n, CUInt flags) @cname("getrandom") @private;
struct PollFd @private { CInt fd; short events; short revents; }
extern fn CInt c_lchown(ZString path, uint uid, uint gid) @cname("lchown") @private;

struct Timespec @private { long sec; long nsec; }

const CInt O_RDONLY @private = 0;
const CInt O_WRONLY @private = 1;
const CInt O_CREAT @private = 0x40;
const CInt O_EXCL @private = 0x80;
const CInt O_DIRECTORY @private = 0x10000;
const CInt O_NOFOLLOW @private = 0x20000;
const CInt O_CLOEXEC @private = 0x80000;
const CInt AT_FDCWD @private = -100;
const CInt AT_SYMLINK_NOFOLLOW @private = 0x100;
const CInt ENOENT @private = 2;
const CInt EINTR @private = 4;
const CInt EEXIST @private = 17;
const CInt EXDEV @private = 18;
const CInt EINVAL @private = 22;
const CInt ENOSYS @private = 38;
const CInt EOPNOTSUPP @private = 95;
const long SYS_RENAMEAT2 @private = 316; // x86_64
const uint S_IFMT @private = 0xF000;
const uint S_IFREG @private = 0x8000;
const uint S_IFDIR @private = 0x4000;
const uint S_IFLNK @private = 0xA000;

const int MAX_ITEMS = 16384;     // top-level items per job
const int MAX_DEPTH = 128;       // folder nesting below an item
const usz CHUNK = 4 * 1024 * 1024; // bytes per copy step (cancel / progress granularity)
const usz FALLBACK_BUF = 1024 * 1024;
const ulong FLUSH_STEP = 32 * 1024 * 1024; // copied bytes between flushes to the target disk
const long FLUSH_TIME = 500_000_000;       // ns: flush at least this often while copying (trees of small files)

enum Kind { COPY, MOVE, TRASH, DELETE, COUNT, RESTORE, EXTRACT }
enum State { IDLE, SCANNING, RUNNING, CONFLICT, FINISHING, DONE, CANCELLED, FAILED }
enum Answer { REPLACE, SKIP, KEEP_BOTH }
enum Plan @private { SKIP, RENAME, COPY }

struct Progress
{
	State state;
	Kind kind;
	int items;           // top-level items requested
	int files_done;      // files, folders and links handled
	int files_total;     // known after SCANNING
	ulong bytes_done;
	ulong bytes_total;
	int skipped;         // conflicts answered SKIP + special files (FIFOs, sockets, devices) not copied
	bool can_cancel;     // false while committing (FINISHING) and after the end
	bool conflict_dir;   // the conflicting target is a folder
	char[256] current;   // name being processed
	char[256] conflict;  // name that exists in the target (state CONFLICT)
	int removed;         // MOVE across filesystems, FINISHING: source files/folders deleted so far
	int remove_total;    // ... and to delete (0 = not deleting sources)
	int item;            // index of the top-level item being worked on (-1 = none yet; see item_status)
	char[512] error;     // state FAILED: what went wrong
	CInt err;            // errno of that error (0 = none / not a system error): EACCES / EPERM mean "permission denied"
}

enum ItemState { WAITING, ACTIVE, DONE, SKIPPED }

<* One top-level item of a running job (Job.item_status). Bytes count like Progress.bytes_done (flushed). *>
struct ItemProgress
{
	ItemState state;
	int files_done;      // files, folders and links of this item handled
	int files_total;     // known after SCANNING (TRASH / RESTORE: 0, the state tells)
	ulong bytes_done;
	ulong bytes_total;
	char[256] name;      // the source name
}

struct Item @private
{
	char[256] dst;       // final name in the target folder
	uint src;            // offset of the source name in Job.names
	Plan plan;
	bool replace;        // an existing target is moved aside, deleted after the commit
	bool started;        // temporary created / rename done (rollback needed)
	bool aside;          // existing target moved to its `.sms-old` name
	bool committed;
	bool missing;        // DELETE: the item was already gone (retry after a partial failure)
	ulong dev;
	ulong pending;       // copied bytes not yet flushed (worker only)
	// Shared with the UI (item_status), guarded by Job.mutex:
	ItemState st;
	int f_done;
	int f_total;
	ulong b_done;
	ulong b_total;
}

// Keep at a stable address while busy; methods are UI-thread-only.
struct Job
{
	thread::Mutex mutex;
	thread::ConditionVariable wake;
	thread::Thread worker;
	bool started;        // worker thread exists (until finished()/close())
	bool ended;          // worker returned
	bool cancel_req;
	bool answered;
	Answer reply;
	bool has_all;
	Answer all_answer;
	Progress p;          // shared with the UI, guarded by mutex
	// Worker-owned while running:
	Kind kind;
	bool permanent_fallback;
	char[4096] src_dir;
	char[4096] dst_dir;
	char[4096] inner;    // EXTRACT: folder inside the archive ("" = its root)
	bool smart;          // EXTRACT: several top-level items go into a folder named after the archive
	char* names;
	Item* items;
	int count;
	char* buf;
	ulong unflushed;     // copied bytes not yet flushed to the target disk (not yet counted as done)
	Clock last_flush;
	int copied_nodes;    // files, folders, links and skipped specials of COPY items (sources a MOVE deletes)
	int cur;             // item that progress is counted for (-1 = none)
	int flush_from;      // first item that may still have unflushed bytes
	int pid;
	bool elevated;       // run through the root helper (start_elevated)
	char[512] secret;    // password for sudo; wiped as soon as it is written
	bool own_target;     // helper as root: new files get the target folder's owner
	uint own_uid;
	uint own_gid;
	char[4096] sp;       // scratch paths (no per-level buffers: deep trees stay cheap on small thread stacks)
	char[4096] dp;
	usz sl;
	usz dl;
}

// ---------------------------------------------------------------------------------------------- UI side

<*
 Start an operation on `names` (plain names, no '/') inside `src_dir`. COPY / MOVE put them into `dst_dir`.
 TRASH moves them to the home trash; with `permanent_fallback` items on other filesystems are deleted
 permanently instead of failing. DELETE removes them permanently. COUNT only adds up files_total / bytes_total
 (for a size display). RESTORE takes names in a trash's `files/` folder and moves each back to the path in
 its `info/NAME.trashinfo` record. Directories should be absolute,
 resolved paths. Returns false when busy or the input is invalid (nothing started).
*>
fn bool Job.start(&self, Kind kind, String src_dir, String[] names, String dst_dir = "", bool permanent_fallback = false)
{
	return begin(self, kind, src_dir, names, dst_dir, permanent_fallback, {});
}

<*
 Like start(), but the operation runs as root: `sudo -k -S` starts this program again in helper mode (apps must
 call `fileop::helper_main` first thing in main, see is_helper). `password` is sent to sudo once and copied
 nowhere else; wipe your buffer after this call. -k means sudo neither uses nor keeps cached credentials: every
 elevated operation asks again. Progress, conflicts, cancel and rollback work as with start(). Not for TRASH or
 RESTORE (root's trash is not the user's). A wrong password ends FAILED with error "Wrong password".
*>
fn bool Job.start_elevated(&self, Kind kind, String src_dir, String[] names, String dst_dir, char[] password, bool permanent_fallback = false)
{
	if (kind == TRASH || kind == RESTORE || kind == EXTRACT) return false;
	return begin(self, kind, src_dir, names, dst_dir, permanent_fallback, password);
}

<*
 EXTRACT: unpack archive `archive_path` (absolute) into folder `dst_dir`. `inner` is a folder inside the archive
 (normalized, "" = root); `names` are direct children of it (empty = everything in it). Items land in dst_dir
 relative to `inner`. With `smart`, several top-level items are put into one new folder named after the
 archive (archive::stem); a single one is placed as is. Call archive::load() first (false when unavailable).
 Progress: bytes_done / bytes_total are compressed bytes read of the archive size. Not elevatable.
*>
fn bool Job.extract(&self, String archive_path, String inner, String[] names, String dst_dir, bool smart = false)
{
	if (self.started || !archive::load() || inner.len >= self.inner.len) return false;
	txt::set(&self.inner, inner);
	self.smart = smart;
	return begin(self, EXTRACT, archive_path, names, dst_dir, false, {});
}

fn bool begin(Job* self, Kind kind, String src_dir, String[] names, String dst_dir, bool permanent_fallback, char[] password) @private
{
	if (self.started || (!names.len && kind != EXTRACT) || names.len > MAX_ITEMS) return false;
	if (!src_dir.starts_with("/") || src_dir.len >= 4096 || dst_dir.len >= 4096) return false;
	if ((kind == COPY || kind == MOVE || kind == EXTRACT) && !dst_dir.starts_with("/")) return false;
	usz bytes;
	foreach (n : names)
	{
		if (!n.len || n.len > 255 || n == "." || n == ".." || n.contains("/")) return false;
		bytes += n.len + 1;
	}
	char* store = libc::malloc(bytes + 1);
	Item* items = libc::calloc(names.len + 1, Item::size);
	char* buf = libc::malloc(FALLBACK_BUF);
	if (!store || !items || !buf) { libc::free(store); libc::free(items); libc::free(buf); return false; }
	usz at;
	foreach (i, n : names)
	{
		items[i].src = (uint)at;
		libc::memcpy(store + at, n.ptr, n.len);
		store[at + n.len] = 0;
		at += n.len + 1;
		txt::set(&items[i].dst, n);
	}
	if (catch self.mutex.init()) { libc::free(store); libc::free(items); libc::free(buf); return false; }
	if (catch self.wake.init()) { self.mutex.destroy(); libc::free(store); libc::free(items); libc::free(buf); return false; }
	self.kind = kind;
	self.permanent_fallback = permanent_fallback;
	self.elevated = password.len > 0 || password.ptr != null;
	if (self.elevated)
	{
		usz n = txt::view(password).len;
		if (n >= self.secret.len) n = 0;
		libc::memcpy(&self.secret, password.ptr, n);
		self.secret[n] = 0;
	}
	txt::set(&self.src_dir, src_dir);
	txt::set(&self.dst_dir, dst_dir);
	self.names = store;
	self.items = items;
	self.count = (int)names.len;
	self.buf = buf;
	self.pid = c_getpid();
	self.ended = false;
	self.cancel_req = false;
	self.answered = false;
	self.has_all = false;
	self.p = { .state = SCANNING, .kind = kind, .items = (int)names.len, .can_cancel = true, .item = -1 };
	self.unflushed = 0;
	self.last_flush = clock::now();
	self.copied_nodes = 0;
	self.cur = -1;
	self.flush_from = 0;
	if (catch self.worker.create(&work, self))
	{
		self.wake.destroy(); self.mutex.destroy();
		libc::free(store); libc::free(items); libc::free(buf);
		self.names = null; self.items = null; self.buf = null;
		return false;
	}
	self.started = true;
	return true;
}

<* True from start() until finished() reaped the job. *>
fn bool Job.busy(&self) => self.started;

<* Snapshot of the progress (cheap: one lock + copy). IDLE when no job. *>
fn void Job.status(&self, Progress* out)
{
	if (!self.started) { *out = { .state = IDLE }; return; }
	self.mutex.lock();
	*out = self.p;
	self.mutex.unlock();
}

<*
 Number of top-level items with per-item progress (item_status): the names given to start(). 0 when idle and
 for COUNT, EXTRACT and elevated jobs (their items are not tracked).
*>
fn int Job.item_count(&self) => self.started && !self.elevated && self.kind != COUNT && self.kind != EXTRACT ? self.count : 0;

<*
 Progress of items `first`, `first + 1`… into `out` (one lock for the whole range: ask only for the rows you
 show). Returns how many were filled.
*>
fn int Job.item_status(&self, int first, ItemProgress[] out)
{
	int total = self.item_count();
	if (first < 0 || first >= total) return 0;
	int n = math::min((int)out.len, total - first);
	self.mutex.lock();
	for (int k = 0; k < n; k++)
	{
		Item* it = &self.items[first + k];
		out[k] = { .state = it.st, .files_done = it.f_done, .files_total = it.f_total, .bytes_done = it.b_done, .bytes_total = it.b_total };
	}
	self.mutex.unlock();
	for (int k = 0; k < n; k++) txt::set(&out[k].name, src_name(self, first + k)); // names never change while running
	return n;
}

<* Request cancellation; ignored while committing. Rollback runs on the worker; poll finished(). *>
fn void Job.cancel(&self)
{
	if (!self.started) return;
	self.mutex.lock();
	if (self.p.can_cancel) self.cancel_req = true;
	self.wake.signal();
	self.mutex.unlock();
}

<* Answer the pending conflict (state CONFLICT); `all` reuses the answer for later conflicts. *>
fn void Job.answer(&self, Answer a, bool all = false)
{
	if (!self.started) return;
	self.mutex.lock();
	self.reply = a;
	self.answered = true;
	if (all) { self.has_all = true; self.all_answer = a; }
	self.wake.signal();
	self.mutex.unlock();
}

<* True once after the worker ended: joins it, frees memory and returns the final progress. *>
fn bool Job.finished(&self, Progress* out)
{
	if (!self.started) return false;
	self.mutex.lock();
	bool done = self.ended;
	self.mutex.unlock();
	if (!done) return false;
	self.status(out);
	reap(self);
	return true;
}

<* Cancel (rolling back where possible) and wait for the worker. Blocks; use on shutdown. *>
fn void Job.close(&self)
{
	if (!self.started) return;
	self.cancel();
	reap(self);
}

fn void reap(Job* self) @private
{
	self.worker.join()!!;
	self.wake.destroy();
	self.mutex.destroy();
	libc::free(self.names);
	libc::free(self.items);
	libc::free(self.buf);
	explicit_bzero(&self.secret, self.secret.len);
	self.names = null;
	self.items = null;
	self.buf = null;
	self.started = false;
}

<* The home trash folder: $XDG_DATA_HOME/Trash, default ~/.local/share/Trash. *>
fn void trash_dir(char[] out)
{
	String data = sys::env("XDG_DATA_HOME");
	if (data.starts_with("/"))
	{
		txt::set(out, data);
	}
	else
	{
		txt::set(out, sys::home());
		txt::append(out, "/.local/share");
	}
	txt::append(out, "/Trash");
}

<* True when `path` can be moved to the home trash by rename (same filesystem). One lstat + one stat. *>
fn bool can_trash(String path) => @pool()
{
	libc::Stat a, b;
	if (c_lstat(path.zstr_tcopy(), &a) != 0) return false;
	char[4096] dir;
	trash_dir(&dir);
	// The trash may not exist yet: use its closest existing parent.
	while (txt::view(&dir).len > 1)
	{
		if (c_stat(txt::z(&dir), &b) == 0) return a.st_dev == b.st_dev;
		txt::set(&dir, txt::dirname(txt::view(&dir)).tcopy());
	}
	return false;
}

// ------------------------------------------------------------------------------------------- worker side

fn int work(void* arg) @private
{
	Job* j = arg;
	State end;
	// Temp memory for the few name/format helpers (only the main thread has one implicitly).
	@pool_init(mem, 64 * 1024)
	{
		if (j.elevated)
		{
			end = run_elevated(j);
		}
		else
		{
			switch (j.kind)
			{
				case COPY:
				case MOVE: end = transfer(j);
				case TRASH: end = trash(j);
				case DELETE: end = delete_all(j);
				case COUNT: end = count_all(j);
				case RESTORE: end = restore_all(j);
				case EXTRACT: end = extract_all(j);
			}
		}
	};
	j.mutex.lock();
	j.p.state = end;
	j.p.can_cancel = false;
	j.p.current[0] = 0;
	j.ended = true;
	j.mutex.unlock();
	return 0;
}

fn bool stopped(Job* j) @private
{
	j.mutex.lock();
	bool c = j.cancel_req;
	j.mutex.unlock();
	return c;
}

fn void set_state(Job* j, State s, bool can_cancel = true) @private
{
	j.mutex.lock();
	j.p.state = s;
	j.p.can_cancel = can_cancel;
	j.mutex.unlock();
}

fn void set_current(Job* j, String name) @private
{
	j.mutex.lock();
	txt::set(&j.p.current, name);
	j.mutex.unlock();
}

fn void add_done(Job* j, int files, ulong bytes) @private
{
	j.mutex.lock();
	j.p.files_done += files;
	j.p.bytes_done += bytes;
	if (j.cur >= 0) { j.items[j.cur].f_done += files; j.items[j.cur].b_done += bytes; }
	j.mutex.unlock();
}

fn void add_total(Job* j, int files, ulong bytes) @private
{
	j.mutex.lock();
	j.p.files_total += files;
	j.p.bytes_total += bytes;
	if (j.cur >= 0) { j.items[j.cur].f_total += files; j.items[j.cur].b_total += bytes; }
	j.mutex.unlock();
}

<* Count the following progress for item i (state unchanged). *>
fn void item_for(Job* j, int i) @private
{
	j.mutex.lock();
	j.cur = i;
	j.mutex.unlock();
}

<* Item i is now `s`; ACTIVE also counts the following progress for it. *>
fn void item_state(Job* j, int i, ItemState s) @private
{
	j.mutex.lock();
	j.items[i].st = s;
	if (s == ACTIVE) { j.cur = i; j.p.item = i; }
	j.mutex.unlock();
}

<* Record the first error (with errno text) and return false. *>
fn bool fail(Job* j, String what, String name) @private
{
	CInt e = *c_errno();
	j.mutex.lock();
	if (!j.p.error[0])
	{
		txt::set(&j.p.error, what);
		if (name.len) { txt::append(&j.p.error, " \""); txt::append(&j.p.error, name); txt::append(&j.p.error, "\""); }
		if (e) { txt::append(&j.p.error, ": "); txt::append(&j.p.error, libc::strerror(e).str_view()); }
		j.p.err = e;
	}
	j.mutex.unlock();
	return false;
}

fn String src_name(Job* j, int i) @private => ((ZString)(j.names + j.items[i].src)).str_view();

// Path builders on the job's scratch buffers; false when the result would not fit.
fn bool set_path(char[] buf, usz* len, String dir, String name) @private
{
	if (dir.len + 1 + name.len >= buf.len) return false;
	libc::memcpy(&buf[0], dir.ptr, dir.len);
	usz n = dir.len;
	if (!n || buf[n - 1] != '/') buf[n++] = '/';
	libc::memcpy(&buf[n], name.ptr, name.len);
	n += name.len;
	buf[n] = 0;
	*len = n;
	return true;
}

fn bool push(char[] buf, usz* len, String name) @private
{
	if (*len + 1 + name.len >= buf.len) return false;
	buf[*len] = '/';
	libc::memcpy(&buf[*len + 1], name.ptr, name.len);
	*len += 1 + name.len;
	buf[*len] = 0;
	return true;
}

fn void pop(char[] buf, usz* len, usz to) @private
{
	*len = to;
	buf[to] = 0;
}

fn ZString zp(char[] buf) @private => (ZString)&buf[0];

<* rename without replacing the target; EEXIST when it exists. *>
fn bool rename_noreplace(ZString from, ZString to) @private
{
	if (c_syscall(SYS_RENAMEAT2, (long)AT_FDCWD, from, (long)AT_FDCWD, to, 1L) == 0) return true;
	CInt e = *c_errno();
	if (e != EINVAL && e != ENOSYS) return false;
	// Filesystem without RENAME_NOREPLACE: check, then rename (small race, documented).
	libc::Stat st;
	if (c_lstat(to, &st) == 0) { *c_errno() = EEXIST; return false; }
	return sys::c_rename(from, to) == 0;
}

<* Temporary sibling names: kind "part" (new copy) or "old" (replaced target), unique per process + item. *>
fn bool temp_path(Job* j, int i, String kind, char[] out) @private => @pool()
{
	return set_path(out, &&(usz){}, txt::view(&j.dst_dir), string::tformat(".sms-%s-%d-%d", kind, j.pid, i));
}

// ------------------------------------------------------------------------------------- recursive helpers

<* Count files/bytes below j.sp. *>
fn bool scan(Job* j, int depth) @private
{
	if (stopped(j)) return false;
	if (depth > MAX_DEPTH) { *c_errno() = 0; return fail(j, "Folder nesting too deep", txt::basename(txt::view(&j.sp))); }
	libc::Stat st;
	if (c_lstat(zp(&j.sp), &st) != 0) return fail(j, "Cannot read", txt::basename(txt::view(&j.sp)));
	if ((st.st_mode & S_IFMT) != S_IFDIR)
	{
		add_total(j, 1, (st.st_mode & S_IFMT) == S_IFREG ? (ulong)st.st_size : 0);
		return true;
	}
	add_total(j, 1, 0);
	void* d = sys::c_opendir(zp(&j.sp));
	if (!d) return fail(j, "Cannot open folder", txt::basename(txt::view(&j.sp)));
	defer sys::c_closedir(d);
	usz keep = j.sl;
	while (true)
	{
		sys::Dirent* e = sys::c_readdir(d);
		if (!e) break;
		String name = ((ZString)&e.name).str_view();
		if (name == "." || name == "..") continue;
		if (!push(&j.sp, &j.sl, name)) { *c_errno() = 0; return fail(j, "Path too long", name); }
		bool ok = scan(j, depth + 1);
		pop(&j.sp, &j.sl, keep);
		if (!ok) return false;
	}
	return true;
}

fn void set_times(ZString path, libc::Stat* st) @private
{
	Timespec[2] t = { { st.st_atime, st.st_atime_nsec }, { st.st_mtime, st.st_mtime_nsec } };
	c_utimensat(AT_FDCWD, path, &t, AT_SYMLINK_NOFOLLOW);
}

<* Wait until everything written to `fd`'s filesystem is on the disk, then count the copied bytes as done. *>
fn void flush(Job* j, CInt fd) @private
{
	if (fd >= 0) c_syncfs(fd);
	j.mutex.lock();
	j.p.bytes_done += j.unflushed;
	for (int i = j.flush_from; i < j.count; i++)
	{
		j.items[i].b_done += j.items[i].pending;
		j.items[i].pending = 0;
	}
	if (j.cur > j.flush_from) j.flush_from = j.cur; // items are copied in order: earlier ones are complete
	j.mutex.unlock();
	j.unflushed = 0;
	j.last_flush = clock::now();
}

<* Flush when FLUSH_STEP bytes are pending or FLUSH_TIME passed with some pending (small files fill no step). *>
fn void maybe_flush(Job* j, CInt fd) @private
{
	if (j.unflushed >= FLUSH_STEP || (j.unflushed && (long)j.last_flush.to_now() >= FLUSH_TIME)) flush(j, fd);
}

<* Flush what is left of the copies (before the commit; still cancellable). *>
fn void flush_target(Job* j) @private
{
	if (!j.unflushed) return;
	CInt fd = sys::c_open(zp(&j.dst_dir), O_RDONLY | O_DIRECTORY | O_CLOEXEC);
	flush(j, fd);
	if (fd >= 0) sys::c_close(fd);
}

<* Copy one regular file j.sp -> j.dp (created exclusively). *>
fn bool copy_file(Job* j, libc::Stat* st) @private
{
	String name = txt::basename(txt::view(&j.sp));
	set_current(j, name);
	CInt in = sys::c_open(zp(&j.sp), O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
	if (in < 0) return fail(j, "Cannot read", name);
	defer sys::c_close(in);
	CInt out = sys::c_open(zp(&j.dp), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, (CInt)0o600);
	if (out < 0) return fail(j, "Cannot create", name);
	bool kernel = true;
	ulong copied;
	while (true)
	{
		if (stopped(j)) { sys::c_close(out); return false; }
		sz n;
		if (kernel)
		{
			n = c_copy_file_range(in, null, out, null, CHUNK, 0);
			if (n < 0)
			{
				CInt e = *c_errno();
				if (e == EINTR) continue;
				// Unsupported between these filesystems: switch to read/write (only before any byte was copied).
				if (copied == 0 && (e == EXDEV || e == ENOSYS || e == EINVAL || e == EOPNOTSUPP || e == 9))
				{
					kernel = false;
					continue;
				}
				sys::c_close(out);
				return fail(j, "Copy failed", name);
			}
		}
		else
		{
			n = c_read(in, j.buf, FALLBACK_BUF);
			if (n < 0)
			{
				if (*c_errno() == EINTR) continue;
				sys::c_close(out);
				return fail(j, "Cannot read", name);
			}
			usz w;
			while (w < (usz)n)
			{
				sz m = c_write(out, j.buf + w, (usz)n - w);
				if (m < 0 && *c_errno() == EINTR) continue;
				if (m <= 0) { sys::c_close(out); return fail(j, "Cannot write", name); }
				w += (usz)m;
			}
		}
		if (n == 0) break;
		copied += (ulong)n;
		j.unflushed += (ulong)n;
		if (j.cur >= 0) j.items[j.cur].pending += (ulong)n;
		maybe_flush(j, out);
	}
	maybe_flush(j, out);
	c_fchmod(out, st.st_mode & 0o7777);
	Timespec[2] t = { { st.st_atime, st.st_atime_nsec }, { st.st_mtime, st.st_mtime_nsec } };
	c_futimens(out, &t);
	if (sys::c_close(out) != 0) return fail(j, "Cannot write", name);
	own(j);
	j.copied_nodes++;
	add_done(j, 1, 0);
	return true;
}

<* Helper as root: a newly created node gets the target folder's owner (no root-owned files in a user's home). *>
fn void own(Job* j) @private
{
	if (j.own_target) c_lchown(zp(&j.dp), j.own_uid, j.own_gid);
}

<* Copy the tree at j.sp to j.dp (j.dp must not exist). Special files are skipped and counted. *>
fn bool copy_tree(Job* j, int depth) @private
{
	if (stopped(j)) return false;
	if (depth > MAX_DEPTH) { *c_errno() = 0; return fail(j, "Folder nesting too deep", txt::basename(txt::view(&j.sp))); }
	String name = txt::basename(txt::view(&j.sp));
	libc::Stat st;
	if (c_lstat(zp(&j.sp), &st) != 0) return fail(j, "Cannot read", name);
	switch (st.st_mode & S_IFMT)
	{
		case S_IFREG:
			return copy_file(j, &st);
		case S_IFLNK:
			char[4096] target;
			sz n = c_readlink(zp(&j.sp), &target, target.len - 1);
			if (n < 0) return fail(j, "Cannot read link", name);
			target[n] = 0;
			if (c_symlink((ZString)&target, zp(&j.dp)) != 0) return fail(j, "Cannot create link", name);
			own(j);
			set_times(zp(&j.dp), &st);
			j.copied_nodes++;
			add_done(j, 1, 0);
			return true;
		case S_IFDIR:
			break;
		default:
			j.copied_nodes++;
			j.mutex.lock();
			j.p.skipped++;
			j.p.files_done++;
			j.mutex.unlock();
			return true;
	}
	if (sys::c_mkdir(zp(&j.dp), 0o700) != 0) return fail(j, "Cannot create folder", name);
	own(j);
	void* d = sys::c_opendir(zp(&j.sp));
	if (!d) return fail(j, "Cannot open folder", name);
	usz skeep = j.sl;
	usz dkeep = j.dl;
	bool ok = true;
	while (ok)
	{
		sys::Dirent* e = sys::c_readdir(d);
		if (!e) break;
		String child = ((ZString)&e.name).str_view();
		if (child == "." || child == "..") continue;
		if (!push(&j.sp, &j.sl, child) || !push(&j.dp, &j.dl, child)) { *c_errno() = 0; ok = fail(j, "Path too long", child); }
		else { ok = copy_tree(j, depth + 1); }
		pop(&j.sp, &j.sl, skeep);
		pop(&j.dp, &j.dl, dkeep);
	}
	sys::c_closedir(d);
	if (!ok) return false;
	c_chmod(zp(&j.dp), st.st_mode & 0o7777);
	set_times(zp(&j.dp), &st);
	j.copied_nodes++;
	add_done(j, 1, 0);
	return true;
}

<* rm -rf j.dp (never follows links). `count` reports progress, `cancellable` honours cancel, `tally` counts
   Progress.removed (MOVE deleting its sources). *>
fn bool remove_tree(Job* j, int depth, bool count, bool cancellable, bool tally = false) @private
{
	if (cancellable && stopped(j)) return false;
	String name = txt::basename(txt::view(&j.dp));
	libc::Stat st;
	if (c_lstat(zp(&j.dp), &st) != 0) return fail(j, "Cannot read", name);
	if ((st.st_mode & S_IFMT) == S_IFDIR)
	{
		if (depth > MAX_DEPTH) { *c_errno() = 0; return fail(j, "Folder nesting too deep", name); }
		void* d = sys::c_opendir(zp(&j.dp));
		if (!d) return fail(j, "Cannot open folder", name);
		usz keep = j.dl;
		bool ok = true;
		while (ok)
		{
			sys::Dirent* e = sys::c_readdir(d);
			if (!e) break;
			String child = ((ZString)&e.name).str_view();
			if (child == "." || child == "..") continue;
			if (!push(&j.dp, &j.dl, child)) { *c_errno() = 0; ok = fail(j, "Path too long", child); }
			else { ok = remove_tree(j, depth + 1, count, cancellable, tally); }
			pop(&j.dp, &j.dl, keep);
		}
		sys::c_closedir(d);
		if (!ok) return false;
		if (count) set_current(j, name);
		if (c_rmdir(zp(&j.dp)) != 0) return fail(j, "Cannot delete folder", name);
	}
	else
	{
		if (count) set_current(j, name);
		if (c_unlink(zp(&j.dp)) != 0) return fail(j, "Cannot delete", name);
	}
	if (count) add_done(j, 1, (st.st_mode & S_IFMT) == S_IFREG ? (ulong)st.st_size : 0);
	if (tally)
	{
		j.mutex.lock();
		j.p.removed++;
		j.mutex.unlock();
	}
	return true;
}

<* Best-effort removal of `path` (rollback / cleanup); errors are not recorded. *>
fn void discard(Job* j, ZString path) @private
{
	char[512] saved = j.p.error;
	txt::set(&j.dp, path.str_view());
	j.dl = path.str_view().len;
	libc::Stat st;
	if (c_lstat(path, &st) == 0) remove_tree(j, 0, false, false);
	j.mutex.lock();
	j.p.error = saved;
	j.mutex.unlock();
}

// --------------------------------------------------------------------------------------------- planning

fn bool exists_in_dst(Job* j, String name) @private
{
	char[4096] p;
	if (!set_path(&p, &&(usz){}, txt::view(&j.dst_dir), name)) return true;
	libc::Stat st;
	return c_lstat(zp(&p), &st) == 0;
}

<* "name (copy).ext" / "name (2).ext"...: first free name in the target, or false. *>
fn bool unique_name(Job* j, String name, bool dir, bool copy_label, char[] out) @private => @pool()
{
	String stem = name;
	String ext = "";
	if (!dir)
	{
		sz? dot = name.rindex_of_char('.');
		if (try dot && dot > 0) { stem = name[:(usz)dot]; ext = name[(usz)dot..]; }
	}
	for (int n = copy_label ? 1 : 2; n < 10000; n++)
	{
		String cand;
		if (copy_label) { cand = n == 1 ? string::tformat("%s (copy)%s", stem, ext) : string::tformat("%s (copy %d)%s", stem, n, ext); }
		else { cand = string::tformat("%s (%d)%s", stem, n, ext); }
		if (cand.len > 255) return false;
		if (!exists_in_dst(j, cand)) { txt::set(out, cand); return true; }
	}
	return false;
}

<* Wait for the UI to answer a conflict. Returns false when cancelled. *>
fn bool ask(Job* j, String name, bool dir, Answer* out) @private
{
	j.mutex.lock();
	defer j.mutex.unlock();
	if (j.has_all) { *out = j.all_answer; return true; }
	j.answered = false;
	j.p.state = CONFLICT;
	j.p.conflict_dir = dir;
	txt::set(&j.p.conflict, name);
	while (!j.answered && !j.cancel_req) j.wake.wait(&j.mutex);
	j.p.state = SCANNING;
	j.p.conflict[0] = 0;
	if (j.cancel_req) return false;
	*out = j.reply;
	return true;
}

fn State transfer(Job* j) @private
{
	String src_dir = txt::view(&j.src_dir);
	String dst_dir = txt::view(&j.dst_dir);
	libc::Stat dst_st;
	if (c_stat(zp(&j.dst_dir), &dst_st) != 0 || (dst_st.st_mode & S_IFMT) != S_IFDIR)
	{
		fail(j, "Cannot open target folder", txt::basename(dst_dir));
		return FAILED;
	}
	bool same_dir = src_dir == dst_dir;
	if (j.own_target) { j.own_uid = dst_st.st_uid; j.own_gid = dst_st.st_gid; }
	// 1. Plan every item; nothing is written yet.
	for (int i = 0; i < j.count; i++)
	{
		if (stopped(j)) return CANCELLED;
		Item* it = &j.items[i];
		String name = src_name(j, i);
		if (!set_path(&j.sp, &j.sl, src_dir, name)) { *c_errno() = 0; fail(j, "Path too long", name); return FAILED; }
		libc::Stat st;
		if (c_lstat(zp(&j.sp), &st) != 0) { fail(j, "Cannot read", name); return FAILED; }
		bool dir = (st.st_mode & S_IFMT) == S_IFDIR;
		it.dev = (ulong)st.st_dev;
		if (dir && (dst_dir == txt::view(&j.sp) || (dst_dir.starts_with(txt::view(&j.sp)) && dst_dir[j.sl] == '/')))
		{
			*c_errno() = 0;
			fail(j, "Cannot put a folder inside itself", name);
			return FAILED;
		}
		it.plan = j.kind == MOVE && it.dev == (ulong)dst_st.st_dev ? RENAME : COPY;
		if (same_dir)
		{
			if (j.kind == MOVE) { it.plan = SKIP; item_state(j, i, SKIPPED); continue; }
			if (!unique_name(j, name, dir, true, &it.dst)) { *c_errno() = 0; fail(j, "No free name for a copy of", name); return FAILED; }
			continue;
		}
		if (!exists_in_dst(j, name)) continue;
		char[4096] target;
		set_path(&target, &&(usz){}, dst_dir, name);
		libc::Stat tst;
		bool tdir = c_lstat(zp(&target), &tst) == 0 && (tst.st_mode & S_IFMT) == S_IFDIR;
		Answer a;
		if (!ask(j, name, tdir, &a)) return CANCELLED;
		switch (a)
		{
			case REPLACE:
				// Replacing a folder that contains the source would delete the source with it.
				String tp = ((ZString)&target).str_view();
				if (txt::view(&j.sp).starts_with(tp) && j.sp[tp.len] == '/')
				{
					*c_errno() = 0;
					fail(j, "Cannot replace a folder that contains", name);
					return FAILED;
				}
				it.replace = true;
			case SKIP:
				it.plan = SKIP;
				j.mutex.lock(); j.p.skipped++; it.st = SKIPPED; j.mutex.unlock();
			case KEEP_BOTH:
				if (!unique_name(j, name, dir, false, &it.dst)) { *c_errno() = 0; fail(j, "No free name for", name); return FAILED; }
		}
	}
	// 2. Totals for the progress display.
	for (int i = 0; i < j.count; i++)
	{
		Item* it = &j.items[i];
		if (it.plan == SKIP) continue;
		item_for(j, i);
		if (it.plan == RENAME) { add_total(j, 1, 0); continue; }
		set_path(&j.sp, &j.sl, src_dir, src_name(j, i));
		if (!scan(j, 0)) return rollback(j);
	}
	set_state(j, RUNNING);
	// 3. Renames (instant), then copies to temporaries.
	for (int i = 0; i < j.count; i++)
	{
		Item* it = &j.items[i];
		if (it.plan != RENAME) continue;
		if (stopped(j)) return rollback(j);
		String name = src_name(j, i);
		set_current(j, name);
		item_state(j, i, ACTIVE);
		char[4096] dst;
		set_path(&j.sp, &j.sl, src_dir, name);
		set_path(&dst, &&(usz){}, dst_dir, txt::view(&it.dst));
		if (it.replace)
		{
			char[4096] old;
			if (!temp_path(j, i, "old", &old)) { *c_errno() = 0; fail(j, "Path too long", name); return rollback(j); }
			if (!rename_noreplace(zp(&dst), zp(&old))) { fail(j, "Cannot replace", txt::view(&it.dst)); return rollback(j); }
			it.aside = true;
		}
		if (!rename_noreplace(zp(&j.sp), zp(&dst)))
		{
			if (*c_errno() == EXDEV)
			{
				// Same device id but different mounts (bind mounts): copy instead.
				if (it.aside)
				{
					char[4096] old;
					temp_path(j, i, "old", &old);
					rename_noreplace(zp(&old), zp(&dst));
					it.aside = false;
				}
				it.plan = COPY;
				if (!scan(j, 0)) return rollback(j);
				continue;
			}
			fail(j, "Cannot move", name);
			return rollback(j);
		}
		it.started = true;
		add_done(j, 1, 0);
		item_state(j, i, DONE);
	}
	for (int i = 0; i < j.count; i++)
	{
		Item* it = &j.items[i];
		if (it.plan != COPY) continue;
		if (stopped(j)) return rollback(j);
		item_state(j, i, ACTIVE);
		set_path(&j.sp, &j.sl, src_dir, src_name(j, i));
		if (!temp_path(j, i, "part", &j.dp)) { *c_errno() = 0; fail(j, "Path too long", src_name(j, i)); return rollback(j); }
		j.dl = txt::view(&j.dp).len;
		it.started = true;
		if (!copy_tree(j, 0)) return rollback(j);
		item_state(j, i, DONE);
	}
	flush_target(j);
	if (stopped(j)) return rollback(j);
	// 4. Commit: not cancellable.
	set_state(j, FINISHING, false);
	bool ok = true;
	bool synced;
	for (int i = 0; i < j.count && ok; i++)
	{
		Item* it = &j.items[i];
		if (it.plan != COPY) continue;
		char[4096] part;
		char[4096] dst;
		temp_path(j, i, "part", &part);
		set_path(&dst, &&(usz){}, dst_dir, txt::view(&it.dst));
		if (it.replace)
		{
			char[4096] old;
			temp_path(j, i, "old", &old);
			if (!rename_noreplace(zp(&dst), zp(&old))) { ok = fail(j, "Cannot replace", txt::view(&it.dst)); break; }
			it.aside = true;
		}
		if (!rename_noreplace(zp(&part), zp(&dst)))
		{
			ok = fail(j, "Cannot place", txt::view(&it.dst));
			break;
		}
		it.committed = true;
	}
	if (!ok)
	{
		// Undo the uncommitted part; committed copies stay (sources are untouched, nothing is lost).
		for (int i = j.count - 1; i >= 0; i--)
		{
			Item* it = &j.items[i];
			if (it.plan == COPY && !it.committed && it.started)
			{
				char[4096] part;
				temp_path(j, i, "part", &part);
				discard(j, zp(&part));
			}
			if (it.aside && !it.committed && it.plan == COPY)
			{
				char[4096] old, dst;
				temp_path(j, i, "old", &old);
				set_path(&dst, &&(usz){}, dst_dir, txt::view(&it.dst));
				rename_noreplace(zp(&old), zp(&dst));
				it.aside = false;
			}
		}
	}
	// Replaced targets are deleted only now that their replacements are in place.
	for (int i = 0; i < j.count; i++)
	{
		Item* it = &j.items[i];
		if (!it.aside || (it.plan == COPY && !it.committed)) continue;
		char[4096] old;
		temp_path(j, i, "old", &old);
		discard(j, zp(&old));
	}
	if (!ok) return FAILED;
	if (j.kind == MOVE)
	{
		// Cross-filesystem move: make the copies durable before deleting the sources (progress in removed / remove_total).
		j.mutex.lock();
		j.p.remove_total = j.copied_nodes;
		j.mutex.unlock();
		for (int i = 0; i < j.count; i++)
		{
			Item* it = &j.items[i];
			if (it.plan != COPY) continue;
			if (!synced)
			{
				CInt fd = sys::c_open(zp(&j.dst_dir), O_RDONLY | O_DIRECTORY | O_CLOEXEC);
				if (fd >= 0) { c_syncfs(fd); sys::c_close(fd); }
				synced = true;
			}
			set_current(j, src_name(j, i));
			set_path(&j.dp, &j.dl, src_dir, src_name(j, i));
			if (!remove_tree(j, 0, false, false, true)) return FAILED; // copy is complete; the error says which source remains
		}
	}
	return DONE;
}

<* Undo everything not yet committed (cancel / error before the commit). *>
fn State rollback(Job* j) @private
{
	j.mutex.lock();
	bool cancelled = j.cancel_req && !j.p.error[0];
	j.p.state = FINISHING;
	j.p.can_cancel = false;
	txt::set(&j.p.current, "Undoing");
	j.mutex.unlock();
	String src_dir = txt::view(&j.src_dir);
	String dst_dir = txt::view(&j.dst_dir);
	for (int i = j.count - 1; i >= 0; i--)
	{
		Item* it = &j.items[i];
		char[4096] dst, old, src;
		set_path(&dst, &&(usz){}, dst_dir, txt::view(&it.dst));
		temp_path(j, i, "old", &old);
		if (it.started && it.plan == COPY)
		{
			char[4096] part;
			temp_path(j, i, "part", &part);
			discard(j, zp(&part));
		}
		if (it.started && it.plan == RENAME)
		{
			set_path(&src, &&(usz){}, src_dir, src_name(j, i));
			rename_noreplace(zp(&dst), zp(&src));
		}
		if (it.aside) rename_noreplace(zp(&old), zp(&dst));
	}
	return cancelled ? CANCELLED : FAILED;
}

// ------------------------------------------------------------------------------------------ trash/delete

<* `<trash>/info/NAME.trashinfo` for an item in `<trash>/files` (j.src_dir). *>
fn bool info_path(Job* j, String name, char[] out) @private
{
	usz n;
	if (!set_path(out, &n, txt::dirname(txt::view(&j.src_dir)), "info") || !push(out, &n, name) || n + 11 >= out.len) return false;
	txt::append(out, ".trashinfo");
	return true;
}

fn int hex(char c) @private
{
	if (c >= '0' && c <= '9') return c - '0';
	if (c >= 'a' && c <= 'f') return c - 'a' + 10;
	if (c >= 'A' && c <= 'F') return c - 'A' + 10;
	return -1;
}

<* Read `<trash>/info/NAME.trashinfo`: 0 ok, 1 no record, 2 unreadable, 3 no Path=, 4 invalid, 5 relative path. *>
fn int load_info(String files_dir, String name, char[] path, char[] date) @private
{
	char[4096] info;
	usz il;
	if (!set_path(&info, &il, txt::dirname(files_dir), "info") || !push(&info, &il, name) || il + 11 >= info.len) return 4;
	txt::append(&info, ".trashinfo");
	CInt fd = sys::c_open(zp(&info), O_RDONLY | O_CLOEXEC);
	if (fd < 0) return 1;
	char[16384] text;
	sz n = c_read(fd, &text, text.len - 1);
	sys::c_close(fd);
	if (n < 0) return 2;
	String body = (String)text[:(usz)n];
	sz? at = body.index_of("\nPath=");
	usz start;
	if (try at) { start = (usz)at + 6; }
	else if (body.starts_with("Path=")) { start = 5; }
	else { return 3; }
	usz k;
	for (usz i = start; i < body.len && body[i] != '\n' && body[i] != '\r'; i++)
	{
		char c = body[i];
		if (c == '%' && i + 2 < body.len && hex(body[i + 1]) >= 0 && hex(body[i + 2]) >= 0)
		{
			c = (char)(hex(body[i + 1]) * 16 + hex(body[i + 2]));
			i += 2;
		}
		if (k + 1 >= path.len || c == 0) return 4;
		path[k++] = c;
	}
	path[k] = 0;
	// Per-volume trashes may store relative paths; only the home trash (absolute paths) is supported.
	if (!k || path[0] != '/') return 5;
	if (date.len)
	{
		date[0] = 0;
		sz? d = body.index_of("\nDeletionDate=");
		if (try d)
		{
			usz m;
			for (usz i = (usz)d + 14; i < body.len && body[i] != '\n' && body[i] != '\r' && m + 1 < date.len; i++) date[m++] = body[i] == 'T' ? ' ' : body[i];
			date[m] = 0;
		}
	}
	return 0;
}

<*
 Where a trashed item came from: `files_dir` is the trash's `files/` folder, `name` the entry in it. Fills `path`
 (absolute, decoded) and, when given, `date` ("YYYY-MM-DD hh:mm:ss"). One small file read: call it on an event
 such as a hover change, not every frame.
*>
fn bool trash_info(String files_dir, String name, char[] path, char[] date = {})
{
	return load_info(files_dir, name, path, date) == 0;
}

fn bool read_origin(Job* j, String name, char[] out) @private
{
	*c_errno() = 0;
	switch (load_info(txt::view(&j.src_dir), name, out, {}))
	{
		case 0: return true;
		case 1: return fail(j, "No restore information for", name);
		case 2: return fail(j, "Cannot read the restore information for", name);
		case 3: return fail(j, "No original path recorded for", name);
		case 5: return fail(j, "Unsupported original path for", name);
		default: return fail(j, "Invalid original path for", name);
	}
}

// ------------------------------------------------------------------------------------------- extract

fn void extract_progress(void* ctx, ulong done, ulong total, String name) @private
{
	Job* j = ctx;
	j.mutex.lock();
	j.p.bytes_done = done;
	j.p.bytes_total = total;
	txt::set(&j.p.current, txt::basename(name));
	j.mutex.unlock();
}

fn bool extract_stop(void* ctx) @private => stopped((Job*)ctx);

<* Replace the job's items with the entries of folder `dir` (staged top-level items) for the commit. *>
fn bool stage_items(Job* j, ZString dir) @private
{
	int n;
	usz bytes;
	for (int pass = 0; pass < 2; pass++)
	{
		void* d = sys::c_opendir(dir);
		if (!d) return fail(j, "Cannot open folder", "");
		int k;
		usz at;
		while (true)
		{
			sys::Dirent* e = sys::c_readdir(d);
			if (!e) break;
			String name = ((ZString)&e.name).str_view();
			if (name == "." || name == "..") continue;
			if (pass == 0) { n++; bytes += name.len + 1; continue; }
			if (k >= n) break;
			j.items[k] = { .src = (uint)at };
			txt::set(&j.items[k].dst, name);
			libc::memcpy(j.names + at, name.ptr, name.len);
			j.names[at + name.len] = 0;
			at += name.len + 1;
			k++;
		}
		sys::c_closedir(d);
		if (pass == 1) { n = k; break; }
		if (n > MAX_ITEMS) { *c_errno() = 0; return fail(j, "Too many items at the top of the archive", ""); }
		libc::free(j.names);
		libc::free(j.items);
		j.names = libc::malloc(bytes + 1);
		j.items = libc::calloc((usz)n + 1, Item::size);
		j.count = 0;
		if (!j.names || !j.items) { *c_errno() = 0; return fail(j, "Out of memory", ""); }
	}
	j.count = n;
	return true;
}

fn State extract_all(Job* j) @private => @pool()
{
	libc::Stat dst_st;
	if (c_stat(zp(&j.dst_dir), &dst_st) != 0 || (dst_st.st_mode & S_IFMT) != S_IFDIR)
	{
		fail(j, "Cannot open target folder", txt::basename(txt::view(&j.dst_dir)));
		return FAILED;
	}
	// libarchive refuses symlinks on the way to an entry: give it the resolved target.
	char[4096] real;
	if (!sys::c_realpath(zp(&j.dst_dir), &real)) { fail(j, "Cannot open target folder", txt::basename(txt::view(&j.dst_dir))); return FAILED; }
	txt::set(&j.dst_dir, ((ZString)&real).str_view());
	String dst_dir = txt::view(&j.dst_dir);
	uint rnd;
	c_getrandom(&rnd, uint::size, 0);
	char[4096] stage;
	char[4096] root;
	if (!set_path(&stage, &&(usz){}, dst_dir, string::tformat(".sms-xtract-%d-%x", j.pid, rnd))
		|| !set_path(&root, &&(usz){}, txt::view(&stage), "x"))
	{
		*c_errno() = 0;
		fail(j, "Path too long", txt::basename(dst_dir));
		return FAILED;
	}
	// The staging folder is private (0700) until its items are renamed into place.
	if (sys::c_mkdir(zp(&stage), 0o700) != 0) { fail(j, "Cannot create a folder in", txt::basename(dst_dir)); return FAILED; }
	State end = FAILED;
	if (sys::c_mkdir(zp(&root), 0o777) != 0)
	{
		fail(j, "Cannot create a folder in", txt::basename(dst_dir));
	}
	else
	{
		set_state(j, RUNNING);
		String[] names = mem::talloc_array(String, (usz)j.count + 1)[:(usz)j.count];
		for (int i = 0; i < j.count; i++) names[i] = src_name(j, i);
		archive::Sink* sink = mem::tnew(archive::Sink);
		sink.ctx = j;
		sink.progress = &extract_progress;
		sink.stop = &extract_stop;
		switch (archive::extract(txt::view(&j.src_dir), txt::view(&j.inner), names, txt::view(&root), sink))
		{
			case DONE:
				j.mutex.lock(); j.p.skipped += sink.skipped; j.mutex.unlock();
				end = commit_extract(j, &stage, &root);
			case CANCELLED:
				end = CANCELLED;
			case FAILED:
				fail_text(j, txt::view(&sink.error));
				end = j.cancel_req ? CANCELLED : FAILED;
		}
	}
	set_current(j, "Cleaning up");
	discard(j, zp(&stage));
	return end;
}

<* Move the staged items into the target like a same-filesystem MOVE (conflicts, rollback). *>
fn State commit_extract(Job* j, char[] stage, char[] root) @private => @pool()
{
	if (!stage_items(j, zp(root))) return FAILED;
	if (!j.count) return DONE;
	String src = txt::view(root);
	if (j.smart && j.count > 1)
	{
		String name = archive::stem(txt::basename(txt::view(&j.src_dir)));
		String named = txt::join(txt::view(stage), name);
		if (named != src && sys::c_rename(zp(root), named.zstr_tcopy()) != 0) { fail(j, "Cannot create folder", name); return FAILED; }
		c_chmod(named.zstr_tcopy(), 0o755);
		src = txt::view(stage);
		if (!stage_items(j, zp(stage))) return FAILED;
	}
	txt::set(&j.src_dir, src);
	j.mutex.lock();
	j.p.items = j.count;
	j.mutex.unlock();
	j.kind = MOVE;
	State end = transfer(j);
	j.kind = EXTRACT;
	return end;
}

<* mkdir -p for a restore target's parent (4095-byte paths). *>
fn bool make_parents(char[] path) @private
{
	usz n = txt::view(path).len;
	for (usz i = 1; i <= n; i++)
	{
		if (i < n && path[i] != '/') continue;
		char saved = path[i];
		path[i] = 0;
		sys::c_mkdir(zp(path), 0o755);
		path[i] = saved;
	}
	libc::Stat st;
	return c_stat(zp(path), &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR;
}

fn State restore_all(Job* j) @private
{
	String src_dir = txt::view(&j.src_dir);
	add_total(j, j.count, 0);
	set_state(j, RUNNING);
	for (int i = 0; i < j.count; i++)
	{
		if (stopped(j)) return CANCELLED;
		String name = src_name(j, i);
		set_current(j, name);
		item_state(j, i, ACTIVE);
		char[4096] origin;
		if (!read_origin(j, name, &origin)) return FAILED;
		String path = txt::view(&origin);
		txt::set(&j.dst_dir, txt::dirname(path)); // exists_in_dst / unique_name / temp_path work in the target folder
		if (!make_parents(&j.dst_dir)) { fail(j, "Cannot recreate the original folder of", name); return FAILED; }
		if (!set_path(&j.sp, &j.sl, src_dir, name)) { *c_errno() = 0; fail(j, "Path too long", name); return FAILED; }
		libc::Stat st;
		if (c_lstat(zp(&j.sp), &st) != 0) { fail(j, "Cannot read", name); return FAILED; }
		char[256] final;
		txt::set(&final, txt::basename(path));
		bool aside;
		char[4096] old;
		if (exists_in_dst(j, txt::view(&final)))
		{
			char[4096] target;
			set_path(&target, &&(usz){}, txt::view(&j.dst_dir), txt::view(&final));
			libc::Stat tst;
			bool tdir = c_lstat(zp(&target), &tst) == 0 && (tst.st_mode & S_IFMT) == S_IFDIR;
			Answer a;
			if (!ask(j, txt::view(&final), tdir, &a)) return CANCELLED;
			set_state(j, RUNNING);
			switch (a)
			{
				case SKIP:
					j.mutex.lock(); j.p.skipped++; j.p.files_done++; j.items[i].st = SKIPPED; j.mutex.unlock();
					continue;
				case KEEP_BOTH:
					if (!unique_name(j, txt::basename(path), (st.st_mode & S_IFMT) == S_IFDIR, false, &final)) { *c_errno() = 0; fail(j, "No free name for", name); return FAILED; }
				case REPLACE:
					if (!temp_path(j, i, "old", &old)) { *c_errno() = 0; fail(j, "Path too long", name); return FAILED; }
					if (!rename_noreplace(zp(&target), zp(&old))) { fail(j, "Cannot replace", txt::view(&final)); return FAILED; }
					aside = true;
			}
		}
		char[4096] dst;
		if (!set_path(&dst, &&(usz){}, txt::view(&j.dst_dir), txt::view(&final))) { *c_errno() = 0; fail(j, "Path too long", name); return FAILED; }
		if (!rename_noreplace(zp(&j.sp), zp(&dst)))
		{
			CInt e = *c_errno();
			if (aside) rename_noreplace(zp(&old), zp(&dst));
			*c_errno() = e;
			fail(j, e == EXDEV ? "Original folder is on another drive:" : "Cannot restore", name);
			return FAILED;
		}
		if (aside) discard(j, zp(&old));
		char[4096] info;
		if (info_path(j, name, &info)) c_unlink(zp(&info));
		add_done(j, 1, 0);
		item_state(j, i, DONE);
	}
	return DONE;
}

<* COUNT: totals only (files_total counts files, folders and links; bytes_total = sum of file sizes). *>
fn State count_all(Job* j) @private
{
	String src_dir = txt::view(&j.src_dir);
	for (int i = 0; i < j.count; i++)
	{
		set_path(&j.sp, &j.sl, src_dir, src_name(j, i));
		if (!scan(j, 0)) return j.p.error[0] ? FAILED : CANCELLED;
	}
	return DONE;
}

fn State delete_all(Job* j) @private
{
	String src_dir = txt::view(&j.src_dir);
	for (int i = 0; i < j.count; i++)
	{
		set_path(&j.sp, &j.sl, src_dir, src_name(j, i));
		libc::Stat gone;
		if (c_lstat(zp(&j.sp), &gone) != 0 && *c_errno() == ENOENT) { j.items[i].missing = true; item_state(j, i, DONE); continue; }
		item_for(j, i);
		if (!scan(j, 0)) return j.p.error[0] ? FAILED : CANCELLED;
	}
	// Deleting inside the trash also removes each item's .trashinfo record (freedesktop spec).
	char[4096] trash;
	trash_dir(&trash);
	usz tl = txt::view(&trash).len;
	bool in_trash = push(&trash, &tl, "files") && src_dir == txt::view(&trash);
	set_state(j, RUNNING);
	for (int i = 0; i < j.count; i++)
	{
		if (j.items[i].missing) continue;
		item_state(j, i, ACTIVE);
		set_path(&j.dp, &j.dl, src_dir, src_name(j, i));
		if (!remove_tree(j, 0, true, true)) return stopped(j) && !j.p.error[0] ? CANCELLED : FAILED;
		item_state(j, i, DONE);   // its .trashinfo record (inside the trash) goes next, nothing to show
		if (in_trash)
		{
			char[4096] info;
			trash_dir(&info);
			usz il = txt::view(&info).len;
			if (push(&info, &il, "info") && push(&info, &il, src_name(j, i)) && il + 10 < info.len)
			{
				txt::append(&info, ".trashinfo");
				c_unlink(zp(&info));
			}
		}
	}
	return DONE;
}

fn bool url_encode(String path, char[] out) @private
{
	usz n;
	foreach (c : path)
	{
		bool plain = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '/' || c == '-' || c == '_' || c == '.' || c == '~';
		if (n + 4 >= out.len) return false;
		if (plain) { out[n++] = c; continue; }
		out[n++] = '%';
		out[n++] = "0123456789ABCDEF"[c >> 4];
		out[n++] = "0123456789ABCDEF"[c & 15];
	}
	out[n] = 0;
	return true;
}

<* Move j.sp to the trash (freedesktop spec): reserve info/NAME.trashinfo exclusively, then rename. *>
fn bool trash_one(Job* j, String trash, String name) @private => @pool()
{
	char[12288] encoded;
	if (!url_encode(txt::view(&j.sp), &encoded)) { *c_errno() = 0; return fail(j, "Path too long", name); }
	char[32] date;
	long now = sys::now();
	libc::Tm tm;
	libc::localtime_r(&now, &tm);
	libc::strftime(&date, date.len, "%Y-%m-%dT%H:%M:%S", &tm);
	String info_text = string::tformat("[Trash Info]\nPath=%s\nDeletionDate=%s\n", ((ZString)&encoded).str_view(), ((ZString)&date).str_view());
	for (int n = 1; n < 10000; n++)
	{
		String tname = n == 1 ? name : string::tformat("%s.%d", name, n);
		if (tname.len > 245) return fail(j, "Name too long for the trash", name);
		char[4096] info, dest;
		if (!set_path(&info, &&(usz){}, trash, string::tformat("info/%s.trashinfo", tname))) return fail(j, "Path too long", name);
		if (!set_path(&dest, &&(usz){}, trash, string::tformat("files/%s", tname))) return fail(j, "Path too long", name);
		CInt fd = sys::c_open(zp(&info), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, (CInt)0o600);
		if (fd < 0)
		{
			if (*c_errno() == EEXIST) continue;
			return fail(j, "Cannot write to the trash", name);
		}
		bool wrote = c_write(fd, info_text.ptr, info_text.len) == (sz)info_text.len;
		if (sys::c_close(fd) != 0) wrote = false;
		if (!wrote) { c_unlink(zp(&info)); return fail(j, "Cannot write to the trash", name); }
		if (rename_noreplace(zp(&j.sp), zp(&dest))) return true;
		CInt e = *c_errno();
		c_unlink(zp(&info));
		if (e == EEXIST) continue;
		*c_errno() = e;
		return false; // caller decides (EXDEV -> permanent fallback)
	}
	return fail(j, "No free name in the trash for", name);
}

fn State trash(Job* j) @private
{
	char[4096] trash;
	trash_dir(&trash);
	String t = txt::view(&trash);
	libc::Stat tst;
	bool fresh = c_stat(zp(&trash), &tst) != 0;
	char[4096] sub;
	bool made = set_path(&sub, &&(usz){}, t, "files") && sys::mkdirs(txt::view(&sub));
	made = made && set_path(&sub, &&(usz){}, t, "info") && sys::mkdirs(txt::view(&sub));
	if (!made)
	{
		fail(j, "Cannot create the trash folder", t);
		return FAILED;
	}
	if (fresh) c_chmod(zp(&trash), 0o700); // the spec wants a private trash
	String src_dir = txt::view(&j.src_dir);
	add_total(j, j.count, 0);
	set_state(j, RUNNING);
	for (int i = 0; i < j.count; i++)
	{
		if (stopped(j)) return CANCELLED;
		String name = src_name(j, i);
		set_current(j, name);
		set_path(&j.sp, &j.sl, src_dir, name);
		item_state(j, i, ACTIVE);
		if (trash_one(j, t, name)) { add_done(j, 1, 0); item_state(j, i, DONE); continue; }
		if (j.p.error[0]) return FAILED;
		if (*c_errno() == EXDEV && j.permanent_fallback)
		{
			set_path(&j.dp, &j.dl, src_dir, name);
			if (!remove_tree(j, 0, false, true)) return stopped(j) && !j.p.error[0] ? CANCELLED : FAILED;
			add_done(j, 1, 0);
			item_state(j, i, DONE);
			continue;
		}
		fail(j, *c_errno() == EXDEV ? "Not on the trash's drive" : "Cannot move to the trash", name);
		return FAILED;
	}
	return DONE;
}

// ------------------------------------------------------------------------------------- root helper

// Elevation command; the program path and helper arguments follow. Tests set it to {} (run the helper directly).
String[] elevate_cmd = { "sudo", "-k", "-S", "-p", "", "--" };
const String HELPER_ARG = "--bmu-fileop-helper";

<* True when this process was started as the root helper: call helper_main(args) and exit with its result. *>
fn bool is_helper(String[] args) => args.len == 3 && args[1] == HELPER_ARG;

// Line I/O on raw fds (no stdio buffering, no temp memory on the worker).
struct LineReader @private
{
	CInt fd;
	char[20480] buf;
	usz len;
	bool eof;
}

<* Next complete line (without the newline) into `out`, or false if none is buffered yet. *>
fn bool LineReader.next(&self, char[] out)
{
	for (usz i = 0; i < self.len; i++)
	{
		if (self.buf[i] != '\n') continue;
		usz n = i < out.len ? i : out.len - 1;
		libc::memcpy(out.ptr, &self.buf, n);
		out[n] = 0;
		libc::memmove(&self.buf, &self.buf[i + 1], self.len - i - 1);
		self.len -= i + 1;
		return true;
	}
	return false;
}

<* Read what is available (call after poll says readable). *>
fn void LineReader.fill(&self)
{
	if (self.len == self.buf.len) self.len = 0; // a line longer than the buffer is garbage: drop it
	sz n = c_read(self.fd, &self.buf[self.len], self.buf.len - self.len);
	if (n <= 0) { if (n == 0 || *c_errno() != EINTR) self.eof = true; return; }
	self.len += (usz)n;
}

fn void wipe_reader(LineReader* r) @private => explicit_bzero(&r.buf, r.buf.len);

fn bool write_all(CInt fd, char* p, usz n) @private
{
	while (n > 0)
	{
		sz w = c_write(fd, p, n);
		if (w < 0 && *c_errno() == EINTR) continue;
		if (w <= 0) return false;
		p += w;
		n -= (usz)w;
	}
	return true;
}

fn bool write_str(CInt fd, String s) @private => write_all(fd, s.ptr, s.len);

<* Hex-encode `s` into `out` (names may contain any byte except '/' and NUL; lines stay lines). *>
fn String hex_of(String s, char[] out) @private
{
	usz k;
	foreach (c : s)
	{
		if (k + 2 >= out.len) break;
		out[k++] = "0123456789abcdef"[c >> 4];
		out[k++] = "0123456789abcdef"[c & 15];
	}
	return (String)out[:k];
}

<* Space-separated fields cannot be empty: "" travels as "-". *>
fn String hex_field(String s, char[] out) @private => s.len ? hex_of(s, out) : "-";
fn bool unhex_field(String s, char[] out) @private
{
	if (s == "-") { out[0] = 0; return true; }
	return unhex(s, out);
}

fn bool unhex(String s, char[] out) @private
{
	if (s.len % 2 || s.len / 2 >= out.len) return false;
	for (usz i = 0; i < s.len / 2; i++)
	{
		int hi = hex(s[i * 2]);
		int lo = hex(s[i * 2 + 1]);
		if (hi < 0 || lo < 0) return false;
		out[i] = (char)(hi * 16 + lo);
	}
	out[s.len / 2] = 0;
	return true;
}

fn void fail_text(Job* j, String text) @private
{
	j.mutex.lock();
	if (!j.p.error[0]) txt::set(&j.p.error, text);
	j.mutex.unlock();
}

<* Split a line into space-separated fields (in place). *>
fn int fields(char[] line, String[] out) @private
{
	String s = txt::view(line);
	int n;
	usz start;
	for (usz i = 0; i <= s.len && n < out.len; i++)
	{
		if (i < s.len && s[i] != ' ') continue;
		if (i > start) out[n++] = s[start:i - start];
		start = i + 1;
	}
	return n;
}

fn long num(String s) @private
{
	long v;
	foreach (c : s) { if (c < '0' || c > '9') return v; v = v * 10 + (long)(c - '0'); }
	return v;
}

<* Worker side of start_elevated: run sudo + helper, relay progress / conflicts / cancel. *>
fn State run_elevated(Job* j) @private
{
	char[4096] exe;
	sz el = c_readlink_exe("/proc/self/exe", &exe, exe.len - 1);
	if (el <= 0) { explicit_bzero(&j.secret, j.secret.len); fail_text(j, "Cannot find the program to run as administrator"); return FAILED; }
	exe[el] = 0;
	char[16] rnd;
	char[40] token;
	c_getrandom(&rnd, rnd.len, 0);
	hex_of((String)rnd[..], &token);
	token[32] = 0;
	ZString[16] argv;
	int a;
	foreach (c : elevate_cmd) { if (a < 12) argv[a++] = c.zstr_tcopy(); }
	argv[a++] = (ZString)&exe;
	argv[a++] = HELPER_ARG;
	argv[a++] = (ZString)&token;
	argv[a] = null;
	CInt[2] in;
	CInt[2] out;
	CInt[2] err;
	if (c_pipe2(&in, 0x80000) != 0 || c_pipe2(&out, 0x80000) != 0 || c_pipe2(&err, 0x80000) != 0)
	{
		explicit_bzero(&j.secret, j.secret.len);
		fail(j, "Cannot start the administrator helper", "");
		return FAILED;
	}
	CInt pid = sys::c_fork();
	if (pid == 0)
	{
		sys::c_dup2(in[0], 0);
		sys::c_dup2(out[1], 1);
		sys::c_dup2(err[1], 2);
		sys::c_execvpe(argv[0], &argv[0], sys::environ);
		sys::c_exit(127);
	}
	sys::c_close(in[0]);
	sys::c_close(out[1]);
	sys::c_close(err[1]);
	if (pid < 0)
	{
		explicit_bzero(&j.secret, j.secret.len);
		sys::c_close(in[1]); sys::c_close(out[0]); sys::c_close(err[0]);
		fail(j, "Cannot start the administrator helper", "");
		return FAILED;
	}
	// The password is the first line sudo reads; nothing else is sent before the helper says READY.
	usz sl = txt::view(&j.secret).len;
	j.secret[sl] = '\n';
	write_all(in[1], &j.secret, sl + 1);
	explicit_bzero(&j.secret, j.secret.len);
	State end = relay(j, in[1], out[0], err[0], txt::view(&token));
	sys::c_close(in[1]);
	sys::c_close(out[0]);
	sys::c_close(err[0]);
	CInt status;
	// IDLE: the helper never reported an end. It either never got the job (wrong password, cancel at the
	// password) or already exited; stopping sudo then cannot interrupt a running operation.
	if (end == IDLE) sys::c_kill(pid, sys::SIGTERM);
	sys::c_waitpid(pid, &status, 0);
	if (end != IDLE) return end;
	j.mutex.lock();
	bool cancelled = j.cancel_req && !j.p.error[0];
	j.mutex.unlock();
	return cancelled ? CANCELLED : FAILED;
}

<* Returns the final state from the helper, or IDLE when it never finished (error already recorded). *>
fn State relay(Job* j, CInt to, CInt from, CInt errfd, String token) @private
{
	LineReader* r = mem::new(LineReader);
	defer { wipe_reader(r); free(r); }
	r.fd = from;
	char[1024] errbuf;
	usz errlen;
	char[2048] line;
	bool ready;
	bool cancel_sent;
	bool conflict_open;
	double start = (double)sys::now();
	while (true)
	{
		PollFd[2] fds = { { from, 1, 0 }, { errfd, 1, 0 } };
		c_poll(&fds, errfd >= 0 ? 2 : 1, 100);
		if (fds[1].revents)
		{
			sz n = c_read(errfd, &errbuf[errlen], errbuf.len - 1 - errlen);
			if (n > 0) { errlen += (usz)n; errbuf[errlen] = 0; }
			else { sys::c_close(errfd); errfd = -1; }
			String e = (String)errbuf[:errlen];
			if (!ready && (e.contains("Sorry, try again") || e.contains("incorrect password")))
			{
				fail_text(j, "Wrong password");
				return IDLE;
			}
		}
		if (fds[0].revents) r.fill();
		while (r.next(&line))
		{
			String[10] f;
			int n = fields(&line, &f);
			if (!n) continue;
			if (!ready)
			{
				if (f[0] != "READY") continue;
				ready = true;
				// Job: token, then J kind fallback hex(src) hex(dst) count, then one hex name per line.
				char[8300] l;
				char[8200] h1;
				char[8200] h2;
				write_str(to, token); write_str(to, "\n");
				String jl = string::tformat("J %d %d %s %s %d\n", (int)j.kind, j.permanent_fallback ? 1 : 0, hex_field(txt::view(&j.src_dir), &h1), hex_field(txt::view(&j.dst_dir), &h2), j.count);
				write_str(to, jl);
				for (int i = 0; i < j.count; i++) { write_str(to, hex_of(src_name(j, i), &l)); write_str(to, "\n"); }
				set_state(j, SCANNING);
				continue;
			}
			switch (f[0])
			{
				case "P":
					if (n < 8) break;
					j.mutex.lock();
					if (!conflict_open) j.p.state = (State)num(f[1]);
					j.p.files_done = (int)num(f[2]);
					j.p.files_total = (int)num(f[3]);
					j.p.bytes_done = (ulong)num(f[4]);
					j.p.bytes_total = (ulong)num(f[5]);
					j.p.skipped = (int)num(f[6]);
					j.p.can_cancel = f[7] == "1";
					if (n >= 10) { j.p.removed = (int)num(f[8]); j.p.remove_total = (int)num(f[9]); }
					j.mutex.unlock();
				case "C":
					char[256] name;
					if (n >= 2 && unhex(f[1], &name)) { set_current(j, txt::view(&name)); }
					else if (n == 1) { set_current(j, ""); }
				case "Q":
					char[256] name;
					if (n < 3 || !unhex(f[2], &name)) break;
					j.mutex.lock();
					j.answered = false;
					j.p.state = CONFLICT;
					j.p.conflict_dir = f[1] == "1";
					txt::set(&j.p.conflict, txt::view(&name));
					j.mutex.unlock();
					conflict_open = true;
				case "E":
					if (n < 3) break;
					char[512] msg;
					if (n >= 4 && unhex(f[3], &msg))
					{
						j.mutex.lock();
						txt::set(&j.p.error, txt::view(&msg));
						j.p.err = (CInt)num(f[2]);
						j.mutex.unlock();
					}
					return (State)num(f[1]);
			}
		}
		// Relay the UI's answers and cancel.
		j.mutex.lock();
		bool cancel = j.cancel_req;
		bool answered = conflict_open && j.answered;
		Answer reply = j.reply;
		bool all = j.has_all;
		if (answered) { j.answered = false; j.p.state = SCANNING; j.p.conflict[0] = 0; }
		j.mutex.unlock();
		if (answered && ready)
		{
			conflict_open = false;
			write_str(to, string::tformat("A %d %d\n", (int)reply, all ? 1 : 0));
		}
		if (cancel && !cancel_sent)
		{
			if (!ready) return IDLE; // still at the password: stop sudo (nothing was started)
			write_str(to, "X\n");
			cancel_sent = true;
		}
		if (r.eof)
		{
			String e = ((String)errbuf[:errlen]).trim();
			if (!e.len) e = "The administrator helper ended unexpectedly";
			// sudo's own messages ("... is not in the sudoers file", "a password is required") explain the failure.
			fail_text(j, e.starts_with("sudo: ") ? e[6..] : e);
			return IDLE;
		}
		if (!ready && (double)sys::now() - start > 120) { fail_text(j, "No answer from sudo"); return IDLE; }
	}
}

<*
 Root helper entry: `if (fileop::is_helper(args)) return fileop::helper_main(args);` as the first line of main,
 before any window or settings. Reads one job from stdin (after the token), runs it with the normal engine,
 reports on stdout, exits. New files get the target folder's owner.
*>
fn int helper_main(String[] args) => @pool()
{
	String token = args[2];
	if (!write_str(1, "READY\n")) return 1;
	LineReader* r = mem::new(LineReader);
	defer { wipe_reader(r); free(r); }
	r.fd = 0;
	char[16500] line;
	// Anything before the token (e.g. a password sudo did not need) is discarded and wiped.
	while (true)
	{
		while (!r.next(&line)) { r.fill(); if (r.eof) return 1; }
		bool is_token = txt::view(&line) == token;
		explicit_bzero(&line, line.len);
		if (is_token) break;
	}
	while (!r.next(&line)) { r.fill(); if (r.eof) return 1; }
	String[8] f;
	if (fields(&line, &f) != 6 || f[0] != "J") return 1;
	char[4096] src;
	char[4096] dst;
	if (!unhex_field(f[3], &src) || !unhex_field(f[4], &dst)) return 1;
	int count = (int)num(f[5]);
	Kind kind = (Kind)num(f[1]);
	if (count <= 0 || count > MAX_ITEMS || (int)kind > (int)Kind.RESTORE) return 1;
	String[] names = mem::talloc_array(String, (usz)count);
	for (int i = 0; i < count; i++)
	{
		while (!r.next(&line)) { r.fill(); if (r.eof) return 1; }
		char[256] name;
		if (!unhex(txt::view(&line), &name)) return 1;
		names[i] = txt::view(&name).tcopy();
	}
	Job* job = mem::new(Job);
	defer free(job);
	job.own_target = c_geteuid() == 0;
	if (!begin(job, kind, txt::view(&src), names, txt::view(&dst), f[2] == "1", {}))
	{
		write_str(1, "E 7 0 \n");
		return 1;
	}
	Progress p;
	Progress last;
	last.state = IDLE;
	bool asked;
	while (true)
	{
		PollFd[1] fds = { { 0, 1, 0 } };
		if (c_poll(&fds, 1, 50) > 0 && fds[0].revents) r.fill();
		while (r.next(&line))
		{
			String[4] g;
			int n = fields(&line, &g);
			if (n >= 3 && g[0] == "A") { job.answer((Answer)num(g[1]), g[2] == "1"); asked = false; }
			if (n >= 1 && g[0] == "X") job.cancel();
		}
		if (r.eof) job.cancel(); // the app went away: roll back
		if (job.finished(&p))
		{
			// Final numbers first, so the app sees complete totals.
			write_str(1, string::tformat("P %d %d %d %d %d %d 0 %d %d\n", (int)p.state, p.files_done, p.files_total, p.bytes_done, p.bytes_total, p.skipped, p.removed, p.remove_total));
			char[1100] h;
			write_str(1, string::tformat("E %d %d %s\n", (int)p.state, p.err, hex_of(txt::view(&p.error), &h)));
			return p.state == DONE ? 0 : 1;
		}
		job.status(&p);
		if (p.state == CONFLICT && !asked)
		{
			char[600] h;
			write_str(1, string::tformat("Q %d %s\n", p.conflict_dir ? 1 : 0, hex_of(txt::view(&p.conflict), &h)));
			asked = true;
		}
		if (p.state != last.state || p.files_done != last.files_done || p.bytes_done != last.bytes_done || p.files_total != last.files_total || p.can_cancel != last.can_cancel || p.removed != last.removed || p.remove_total != last.remove_total)
		{
			write_str(1, string::tformat("P %d %d %d %d %d %d %d %d %d\n", (int)p.state, p.files_done, p.files_total, p.bytes_done, p.bytes_total, p.skipped, p.can_cancel ? 1 : 0, p.removed, p.remove_total));
		}
		if (txt::view(&p.current) != txt::view(&last.current))
		{
			char[600] h;
			write_str(1, string::tformat("C %s\n", hex_of(txt::view(&p.current), &h)));
		}
		last = p;
	}
}

// ------------------------------------------------------------------------------------- programs as root

<*
 A program started as root through sudo (e.g. an editor for a root-owned file). start() writes the password once
 (wiped right after); a thread drains the program's stderr (so it never blocks on a full pipe) and reaps it, so
 poll() is a lock + copy. Keep it at a stable address while it runs.
*>
struct SudoRun
{
	thread::Mutex mutex;
	thread::Thread drain;
	bool started;
	bool exited;
	CInt status;
	CInt pid;
	CInt errfd;
	bool rejected;       // sudo refused (wrong password, not allowed)
	char[512] error;     // sudo's message when rejected
}

enum SudoState { RUNNING, DONE, FAILED }

fn int sudo_drain(void* arg) @private
{
	SudoRun* r = arg;
	char[1024] head;
	usz len;
	char[4096] sink;
	while (true)
	{
		sz n = c_read(r.errfd, &sink, sink.len);
		if (n < 0 && *c_errno() == EINTR) continue;
		if (n <= 0) break;
		usz take = math::min((usz)n, head.len - 1 - len);
		libc::memcpy(&head[len], &sink, take);
		len += take;
	}
	sys::c_close(r.errfd);
	CInt status;
	while (sys::c_waitpid(r.pid, &status, 0) < 0 && *c_errno() == EINTR) {}
	head[len] = 0;
	String e = ((String)head[:len]).trim();
	r.mutex.lock();
	r.exited = true;
	r.status = status;
	// sudo's own refusals ("Sorry, try again", "... not in the sudoers file", "a password is required").
	if (status != 0 && (e.contains("incorrect password") || e.contains("Sorry, try again") || e.starts_with("sudo: ")))
	{
		r.rejected = true;
		if (e.contains("incorrect password") || e.contains("Sorry, try again")) { txt::set(&r.error, "Wrong password"); }
		else
		{
			usz nl = e.len;
			foreach (usz i, c : e) if (c == '\n') { nl = i; break; }
			txt::set(&r.error, e[6:nl - 6]);
		}
	}
	r.mutex.unlock();
	return 0;
}

<*
 Run `argv` as root via `sudo -k -S` (fileop::elevate_cmd; no cached credentials). With `keep_display`, the
 Wayland/X11 display variables are passed through `env` so GUI programs and terminals can open a window (sudo
 resets the environment). The password is written once and wiped from this struct's copy.
*>
fn bool SudoRun.start(&self, String[] argv, char[] password, bool keep_display = true, String dir = "") => @pool()
{
	if (self.started || !argv.len) return false;
	ZString cwd = dir.len ? dir.zstr_tcopy() : null;
	ZString[] args = mem::talloc_array(ZString, elevate_cmd.len + argv.len + 6);
	usz a;
	foreach (c : elevate_cmd) args[a++] = c.zstr_tcopy();
	if (keep_display)
	{
		args[a++] = "env";
		foreach (name : (String[]){ "WAYLAND_DISPLAY", "XDG_RUNTIME_DIR", "DISPLAY" })
		{
			String v = sys::env(name);
			if (v.len) args[a++] = string::tformat("%s=%s", name, v).zstr_tcopy();
		}
	}
	foreach (x : argv) args[a++] = x.zstr_tcopy();
	args[a] = null;
	CInt[2] in;
	CInt[2] err;
	if (c_pipe2(&in, 0x80000) != 0) return false;
	if (c_pipe2(&err, 0x80000) != 0) { sys::c_close(in[0]); sys::c_close(in[1]); return false; }
	CInt pid = sys::c_fork();
	if (pid == 0)
	{
		sys::c_dup2(in[0], 0);
		sys::c_dup2(err[1], 2);
		sys::c_setsid(); // not tied to the app: quitting it leaves the program running
		if (cwd && sys::c_chdir(cwd) != 0) sys::c_exit(127);
		sys::c_execvpe(args[0], &args[0], sys::environ);
		sys::c_exit(127);
	}
	sys::c_close(in[0]);
	sys::c_close(err[1]);
	if (pid < 0) { sys::c_close(in[1]); sys::c_close(err[0]); return false; }
	char[512] line;
	usz n = txt::view(password).len;
	if (n >= line.len) n = 0;
	libc::memcpy(&line, password.ptr, n);
	line[n] = '\n';
	write_all(in[1], &line, n + 1);
	explicit_bzero(&line, line.len);
	sys::c_close(in[1]); // EOF: a rejected password ends sudo instead of waiting for another try
	*self = { .pid = pid, .errfd = err[0] };
	if (catch self.mutex.init()) { sys::c_close(err[0]); return false; }
	if (catch self.drain.create(&sudo_drain, self)) { self.mutex.destroy(); sys::c_close(err[0]); return false; }
	self.started = true;
	return true;
}

<* RUNNING while the program runs (or sudo waits), DONE when it ended normally, FAILED when sudo refused or it
   failed; `error` then says why. After DONE / FAILED the run is free for start() again. *>
fn SudoState SudoRun.poll(&self)
{
	if (!self.started) return DONE;
	self.mutex.lock();
	bool exited = self.exited;
	bool rejected = self.rejected;
	CInt status = self.status;
	self.mutex.unlock();
	if (!exited) return RUNNING;
	self.drain.join()!!;
	self.mutex.destroy();
	self.started = false;
	if (rejected) return FAILED;
	if (status != 0 && !self.error[0]) txt::set(&self.error, "The program failed");
	return status == 0 ? DONE : FAILED;
}

