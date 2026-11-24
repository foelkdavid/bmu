module bmu::find @feat(LINUX);
import std::thread, std::math, libc;
import bmu::txt, bmu::sys;

// bmu::find - recursive file-name search on a worker thread (Linux, no raylib).
//
// Breadth-first from a root folder (shallow matches first), case-insensitive substring on entry names,
// never follows symlinks, stays on the root's filesystem (like `find -xdev`: one fstat per folder, none
// per file). Results are append-only: the UI thread reads `count()` once per frame (one lock) and then
// reads hits 0..count-1 without locking. Restart = close() + start().

extern fn CInt c_dirfd(void* dir) @cname("dirfd") @private;
extern fn CInt c_fstat(CInt fd, libc::Stat* st) @cname("fstat") @private;
extern fn CInt c_stat(ZString path, libc::Stat* st) @cname("stat") @private;
extern fn CInt c_lstat(ZString path, libc::Stat* st) @cname("lstat") @private;

const int MAX_RESULTS = 16384;
const usz RESULT_BYTES = 4 * 1024 * 1024;   // relative paths of the hits
const usz QUEUE_BYTES = 64 * 1024 * 1024;   // folders waiting to be read (breadth-first)
const int MAX_DEPTH = 64;

struct Hit
{
	uint off;       // relative path in the result arena
	ushort len;
	ushort name_at; // start of the entry name inside the relative path
	bool dir;
}

// Keep at a stable address while started; methods are UI-thread-only.
struct Finder
{
	thread::Mutex mutex;
	thread::Thread worker;
	bool started;
	bool ended;
	bool cancel_req;
	int count;          // published hits (guarded by mutex)
	int folders;        // folders read so far
	bool truncated;     // stopped at a limit (results, queue or path length)
	// Worker-owned while running:
	char[4096] root;
	char[256] query;
	bool hidden;
	ulong dev;
	char* arena;
	usz arena_len;
	Hit* hits;
	char* queue;
	usz queue_len;
	usz queue_cap;
	char[4096] path;
}

<*
 Search `root` (absolute folder) for entry names containing `query` (case-insensitive). `hidden` includes
 dot-files and descends into dot-folders. False when already started (close() first), query empty or no memory.
*>
fn bool Finder.start(&self, String root, String query, bool hidden = false)
{
	if (self.started || !query.len || query.len >= self.query.len || !root.starts_with("/") || root.len >= self.root.len) return false;
	self.arena = libc::malloc(RESULT_BYTES);
	self.hits = libc::malloc(MAX_RESULTS * Hit::size);
	self.queue_cap = 64 * 1024;
	self.queue = libc::malloc(self.queue_cap);
	if (!self.arena || !self.hits || !self.queue) { free_all(self); return false; }
	if (catch self.mutex.init()) { free_all(self); return false; }
	txt::set(&self.root, root);
	txt::set(&self.query, query);
	self.hidden = hidden;
	self.arena_len = 0;
	self.queue_len = 0;
	self.count = 0;
	self.folders = 0;
	self.truncated = false;
	self.cancel_req = false;
	self.ended = false;
	if (catch self.worker.create(&work, self)) { self.mutex.destroy(); free_all(self); return false; }
	self.started = true;
	return true;
}

<* Cancel, wait for the worker (it stops within one folder entry) and free the results. *>
fn void Finder.close(&self)
{
	if (!self.started) return;
	self.mutex.lock();
	self.cancel_req = true;
	self.mutex.unlock();
	self.worker.join()!!;
	self.mutex.destroy();
	free_all(self);
	self.started = false;
	self.count = 0;
}

<* Number of results so far (one lock). Hits below it never change until close(). *>
fn int Finder.results(&self)
{
	if (!self.started) return 0;
	self.mutex.lock();
	int n = self.count;
	self.mutex.unlock();
	return n;
}

<* True while the worker is still walking folders. *>
fn bool Finder.searching(&self)
{
	if (!self.started) return false;
	self.mutex.lock();
	bool s = !self.ended;
	self.mutex.unlock();
	return s;
}

<* Stopped at a limit: MAX_RESULTS hits, RESULT_BYTES / QUEUE_BYTES, or MAX_DEPTH. Read after searching() is false. *>
fn bool Finder.limited(&self)
{
	if (!self.started) return false;
	self.mutex.lock();
	bool t = self.truncated;
	self.mutex.unlock();
	return t;
}

<* Path of hit `i` relative to the root (i < results()). *>
fn String Finder.rel(&self, int i) => (String)self.arena[self.hits[i].off : self.hits[i].len];
<* Entry name of hit `i`. *>
fn String Finder.name(&self, int i) => (String)self.arena[self.hits[i].off + self.hits[i].name_at : self.hits[i].len - self.hits[i].name_at];
<* Folder of hit `i` relative to the root ("" = the root itself). *>
fn String Finder.folder(&self, int i) => (String)self.arena[self.hits[i].off : (usz)math::max(0, (int)self.hits[i].name_at - 1)];
fn bool Finder.is_dir(&self, int i) => self.hits[i].dir;

fn void free_all(Finder* self) @private
{
	libc::free(self.arena);
	libc::free(self.hits);
	libc::free(self.queue);
	self.arena = null;
	self.hits = null;
	self.queue = null;
}

// ------------------------------------------------------------------------------------------- worker

fn bool stopped(Finder* f) @private
{
	f.mutex.lock();
	bool c = f.cancel_req;
	f.mutex.unlock();
	return c;
}

fn void set_truncated(Finder* f) @private
{
	f.mutex.lock();
	f.truncated = true;
	f.mutex.unlock();
}

<* Queue a folder's relative path (NUL-terminated) for breadth-first reading. *>
fn bool enqueue(Finder* f, String rel) @private
{
	usz need = f.queue_len + rel.len + 1;
	if (need > QUEUE_BYTES) return false;
	if (need > f.queue_cap)
	{
		usz cap = f.queue_cap;
		while (cap < need) cap *= 2;
		if (cap > QUEUE_BYTES) cap = QUEUE_BYTES;
		char* q = libc::realloc(f.queue, cap);
		if (!q) return false;
		f.queue = q;
		f.queue_cap = cap;
	}
	libc::memcpy(f.queue + f.queue_len, rel.ptr, rel.len);
	f.queue[f.queue_len + rel.len] = 0;
	f.queue_len = need;
	return true;
}

<* Append a hit; false when a result limit is reached. *>
fn bool add_hit(Finder* f, String rel, String name, bool dir) @private
{
	usz len = rel.len ? rel.len + 1 + name.len : name.len;
	if (f.count >= MAX_RESULTS || f.arena_len + len > RESULT_BYTES || len > 0xFFFF) return false;
	char* at = f.arena + f.arena_len;
	usz name_at;
	if (rel.len)
	{
		libc::memcpy(at, rel.ptr, rel.len);
		at[rel.len] = '/';
		name_at = rel.len + 1;
	}
	libc::memcpy(at + name_at, name.ptr, name.len);
	// The hit is written before count publishes it (the mutex orders both for the UI thread).
	f.mutex.lock();
	f.hits[f.count] = { (uint)f.arena_len, (ushort)len, (ushort)name_at, dir };
	f.count++;
	f.mutex.unlock();
	f.arena_len += len;
	return true;
}

fn int work(void* arg) @private
{
	Finder* f = arg;
	walk(f);
	f.mutex.lock();
	f.ended = true;
	f.mutex.unlock();
	return 0;
}

fn int depth_of(String rel) @private
{
	if (!rel.len) return 0;
	int d = 1;
	foreach (c : rel) if (c == '/') d++;
	return d;
}

fn void walk(Finder* f) @private
{
	String root = txt::view(&f.root);
	String query = txt::view(&f.query);
	libc::Stat st;
	if (c_stat(txt::z(&f.root), &st) != 0) return;
	f.dev = (ulong)st.st_dev;
	enqueue(f, "");
	usz head;
	while (head < f.queue_len)
	{
		if (stopped(f)) return;
		// The queue may move on realloc: copy the folder's relative path out first.
		char[4096] relbuf;
		String q = ((ZString)(f.queue + head)).str_view();
		head += q.len + 1;
		txt::set(&relbuf, q);
		String rel = txt::view(&relbuf);
		usz plen = root.len + (rel.len ? 1 + rel.len : 0);
		if (plen >= f.path.len) { set_truncated(f); continue; }
		txt::set(&f.path, root);
		if (rel.len) { txt::append(&f.path, root == "/" ? "" : "/"); txt::append(&f.path, rel); }
		void* d = sys::c_opendir(txt::z(&f.path));
		if (!d) continue;
		// -xdev: one fstat per folder.
		if (c_fstat(c_dirfd(d), &st) != 0 || (ulong)st.st_dev != f.dev) { sys::c_closedir(d); continue; }
		f.mutex.lock();
		f.folders++;
		f.mutex.unlock();
		bool deeper = depth_of(rel) < MAX_DEPTH;
		int n;
		while (true)
		{
			sys::Dirent* e = sys::c_readdir(d);
			if (!e) break;
			if ((++n & 255) == 0 && stopped(f)) { sys::c_closedir(d); return; }
			String name = ((ZString)&e.name).str_view();
			if (name == "." || name == "..") continue;
			if (!f.hidden && name[0] == '.') continue;
			bool dir = e.type == sys::DT_DIR;
			if (e.type == sys::DT_UNKNOWN)
			{
				char[4096] full;
				usz fl = txt::view(&f.path).len + 1 + name.len;
				if (fl < full.len)
				{
					txt::set(&full, txt::view(&f.path));
					txt::append(&full, "/");
					txt::append(&full, name);
					dir = c_lstat(txt::z(&full), &st) == 0 && (st.st_mode & 0xF000) == 0x4000;
				}
			}
			if (txt::icontains(name, query) && !add_hit(f, rel, name, dir))
			{
				set_truncated(f);
				sys::c_closedir(d);
				return;
			}
			if (!dir) continue;
			if (!deeper) { set_truncated(f); continue; }
			char[4096] child;
			if (rel.len + 1 + name.len >= child.len) { set_truncated(f); continue; }
			txt::set(&child, rel);
			if (rel.len) txt::append(&child, "/");
			txt::append(&child, name);
			if (!enqueue(f, txt::view(&child))) { set_truncated(f); }
		}
		sys::c_closedir(d);
	}
}
