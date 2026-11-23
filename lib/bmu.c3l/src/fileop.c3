module bmu::fileop;
import std::thread, std::core::string, libc;
import bmu::txt, bmu::sys;

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
// TRASH follows the freedesktop.org Trash spec (home trash only). DELETE is permanent.

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

enum Kind { COPY, MOVE, TRASH, DELETE }
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
	char[512] error;     // state FAILED: what went wrong
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
	ulong dev;
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
	char* names;
	Item* items;
	int count;
	char* buf;
	int pid;
	char[4096] sp;       // scratch paths (no per-level buffers: deep trees stay cheap on small thread stacks)
	char[4096] dp;
	usz sl;
	usz dl;
}

// ---------------------------------------------------------------------------------------------- UI side

<*
 Start an operation on `names` (plain names, no '/') inside `src_dir`. COPY / MOVE put them into `dst_dir`.
 TRASH moves them to the home trash; with `permanent_fallback` items on other filesystems are deleted
 permanently instead of failing. DELETE removes them permanently. Directories should be absolute,
 resolved paths. Returns false when busy or the input is invalid (nothing started).
*>
fn bool Job.start(&self, Kind kind, String src_dir, String[] names, String dst_dir = "", bool permanent_fallback = false)
{
	if (self.started || !names.len || names.len > MAX_ITEMS) return false;
	if (!src_dir.starts_with("/") || src_dir.len >= 4096 || dst_dir.len >= 4096) return false;
	if ((kind == COPY || kind == MOVE) && !dst_dir.starts_with("/")) return false;
	usz bytes;
	foreach (n : names)
	{
		if (!n.len || n.len > 255 || n == "." || n == ".." || n.contains("/")) return false;
		bytes += n.len + 1;
	}
	char* store = libc::malloc(bytes);
	Item* items = libc::calloc(names.len, Item::size);
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
	self.p = { .state = SCANNING, .kind = kind, .items = (int)names.len, .can_cancel = true };
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
		switch (j.kind)
		{
			case COPY:
			case MOVE: end = transfer(j);
			case TRASH: end = trash(j);
			case DELETE: end = delete_all(j);
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
	j.mutex.unlock();
}

fn void add_total(Job* j, int files, ulong bytes) @private
{
	j.mutex.lock();
	j.p.files_total += files;
	j.p.bytes_total += bytes;
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
		add_done(j, 0, (ulong)n);
	}
	c_fchmod(out, st.st_mode & 0o7777);
	Timespec[2] t = { { st.st_atime, st.st_atime_nsec }, { st.st_mtime, st.st_mtime_nsec } };
	c_futimens(out, &t);
	if (sys::c_close(out) != 0) return fail(j, "Cannot write", name);
	add_done(j, 1, 0);
	return true;
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
			set_times(zp(&j.dp), &st);
			add_done(j, 1, 0);
			return true;
		case S_IFDIR:
			break;
		default:
			j.mutex.lock();
			j.p.skipped++;
			j.p.files_done++;
			j.mutex.unlock();
			return true;
	}
	if (sys::c_mkdir(zp(&j.dp), 0o700) != 0) return fail(j, "Cannot create folder", name);
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
	add_done(j, 1, 0);
	return true;
}

<* rm -rf j.dp (never follows links). `count` reports progress, `cancellable` honours cancel. *>
fn bool remove_tree(Job* j, int depth, bool count, bool cancellable) @private
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
			else { ok = remove_tree(j, depth + 1, count, cancellable); }
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
			if (j.kind == MOVE) { it.plan = SKIP; continue; }
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
				j.mutex.lock(); j.p.skipped++; j.mutex.unlock();
			case KEEP_BOTH:
				if (!unique_name(j, name, dir, false, &it.dst)) { *c_errno() = 0; fail(j, "No free name for", name); return FAILED; }
		}
	}
	// 2. Totals for the progress display.
	for (int i = 0; i < j.count; i++)
	{
		Item* it = &j.items[i];
		if (it.plan == RENAME) { add_total(j, 1, 0); continue; }
		if (it.plan != COPY) continue;
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
	}
	for (int i = 0; i < j.count; i++)
	{
		Item* it = &j.items[i];
		if (it.plan != COPY) continue;
		if (stopped(j)) return rollback(j);
		set_path(&j.sp, &j.sl, src_dir, src_name(j, i));
		if (!temp_path(j, i, "part", &j.dp)) { *c_errno() = 0; fail(j, "Path too long", src_name(j, i)); return rollback(j); }
		j.dl = txt::view(&j.dp).len;
		it.started = true;
		if (!copy_tree(j, 0)) return rollback(j);
	}
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
		// Cross-filesystem move: make the copies durable before deleting the sources.
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
			if (!remove_tree(j, 0, false, false)) return FAILED; // copy is complete; the error says which source remains
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

fn State delete_all(Job* j) @private
{
	String src_dir = txt::view(&j.src_dir);
	for (int i = 0; i < j.count; i++)
	{
		set_path(&j.sp, &j.sl, src_dir, src_name(j, i));
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
		set_path(&j.dp, &j.dl, src_dir, src_name(j, i));
		if (!remove_tree(j, 0, true, true)) return stopped(j) && !j.p.error[0] ? CANCELLED : FAILED;
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
		if (trash_one(j, t, name)) { add_done(j, 1, 0); continue; }
		if (j.p.error[0]) return FAILED;
		if (*c_errno() == EXDEV && j.permanent_fallback)
		{
			set_path(&j.dp, &j.dl, src_dir, name);
			if (!remove_tree(j, 0, false, true)) return stopped(j) && !j.p.error[0] ? CANCELLED : FAILED;
			add_done(j, 1, 0);
			continue;
		}
		fail(j, *c_errno() == EXDEV ? "Not on the trash's drive" : "Cannot move to the trash", name);
		return FAILED;
	}
	return DONE;
}
