module bmu::archive;
import std::thread, std::os, std::sort, std::math, libc;
import bmu::txt, bmu::sys;

// bmu::archive - read archives (zip, tar.*, 7z, rar, iso, cpio, deb, ...) through libarchive (Linux, no raylib).
//
// libarchive is loaded with dlopen on first use (load()), never linked: programs that do not touch an archive
// pay nothing at startup, and a system without libarchive only loses archive support (available() is false).
//
// Index reads an archive's table of contents once on a worker thread (headers only, data is skipped), then the
// UI thread lists folders from memory (list(), find(); no I/O). extract() writes entries below a folder; it runs
// on the caller's thread (fileop's EXTRACT job calls it on its worker) and never writes outside that folder:
// entry paths are normalized (leading '/', '.' removed, '..' rejected) and libarchive refuses to write
// through symlinks (SECURE_SYMLINKS / SECURE_NODOTDOT). Owners, ACLs, xattrs and setuid bits are not restored.

const int MAX_ENTRIES = 65536;           // entries per index, implied folders included
const usz NAME_BYTES = 8 * 1024 * 1024;  // normalized paths of an index
const usz BLOCK = 64 * 1024;             // libarchive read block

// ------------------------------------------------------------------------------------------ libarchive

alias FnNew @private = fn void*();
alias FnA @private = fn CInt(void* a);
alias FnOpen @private = fn CInt(void* a, ZString path, usz block);
alias FnNext @private = fn CInt(void* a, void** entry);
alias FnErr @private = fn ZString(void* a);
alias FnBytes @private = fn long(void* a, CInt n);
alias FnStr @private = fn ZString(void* e);
alias FnI64 @private = fn long(void* e);
alias FnMode @private = fn CUInt(void* e);
alias FnInt @private = fn CInt(void* e);
alias FnSetStr @private = fn void(void* e, ZString s);
alias FnOpts @private = fn CInt(void* a, CInt flags);
alias FnHeader @private = fn CInt(void* a, void* entry);
alias FnReadBlock @private = fn CInt(void* a, void** buf, usz* size, long* offset);
alias FnWriteBlock @private = fn long(void* a, void* buf, usz size, long offset);
alias FnSetCb @private = fn CInt(void* a, void* cb_or_data);

extern fn long c_lseek(CInt fd, long off, CInt whence) @cname("lseek") @private;
extern fn sz c_read(CInt fd, void* buf, usz n) @cname("read") @private;
extern fn CInt c_fstat(CInt fd, libc::Stat* st) @cname("fstat") @private;
extern fn CInt* c_errno() @cname("__errno_location") @private;

struct Lib @private
{
	FnNew read_new;
	FnA filter_all;
	FnA format_all;
	FnA format_raw;
	FnSetCb set_read_callback;
	FnSetCb set_skip_callback;
	FnSetCb set_seek_callback;
	FnSetCb set_callback_data;
	FnA open1;
	FnNext next_header;
	FnA data_skip;
	FnReadBlock read_data_block;
	FnA read_free;
	FnErr error_string;
	FnBytes filter_bytes;
	FnA format;
	FnStr pathname;
	FnStr pathname_utf8;
	FnStr hardlink;
	FnI64 size;
	FnI64 mtime;
	FnMode filetype;
	FnInt is_encrypted;
	FnSetStr copy_pathname;
	FnSetStr copy_hardlink;
	FnNew write_disk_new;
	FnOpts write_disk_set_options;
	FnHeader write_header;
	FnWriteBlock write_data_block;
	FnA write_finish_entry;
	FnA write_close;
	FnA write_free;
}

Lib lib @private;
int lib_state @private; // 0 = not tried, 1 = loaded, -1 = unavailable

const CInt OK @private = 0;
const CInt EOF @private = 1;
const CInt WARN @private = -20;
const CUInt AE_IFMT @private = 0xF000;
const CUInt AE_IFDIR @private = 0x4000;
const CUInt AE_IFLNK @private = 0xA000;
const CInt FORMAT_RAW @private = 0x90000;
const CInt EXTRACT_TIME @private = 0x0004;
const CInt EXTRACT_SECURE_SYMLINKS @private = 0x0100;
const CInt EXTRACT_SECURE_NODOTDOT @private = 0x0200;

macro bool @sym(handle, #field, ZString name) @private
{
	void* p = os::dlsym(handle, name);
	if (!p) return false;
	#field = ($Typeof(#field))p;
	return true;
}

<* Load libarchive once (dlopen). Call on the UI thread before starting an Index or an EXTRACT job. *>
fn bool load()
{
	if (lib_state) return lib_state > 0;
	lib_state = -1;
	os::DylibHandle h = os::dlopen("libarchive.so.13", { .resolve_now = true });
	if (!h) h = os::dlopen("libarchive.so", { .resolve_now = true });
	if (!h) return false;
	if (!resolve(h)) { h.close(); return false; }
	lib_state = 1;
	return true;
}

fn bool resolve(os::DylibHandle h) @private
{
	return @sym(h, lib.read_new, "archive_read_new")
		&& @sym(h, lib.filter_all, "archive_read_support_filter_all")
		&& @sym(h, lib.format_all, "archive_read_support_format_all")
		&& @sym(h, lib.format_raw, "archive_read_support_format_raw")
		&& @sym(h, lib.set_read_callback, "archive_read_set_read_callback")
		&& @sym(h, lib.set_skip_callback, "archive_read_set_skip_callback")
		&& @sym(h, lib.set_seek_callback, "archive_read_set_seek_callback")
		&& @sym(h, lib.set_callback_data, "archive_read_set_callback_data")
		&& @sym(h, lib.open1, "archive_read_open1")
		&& @sym(h, lib.next_header, "archive_read_next_header")
		&& @sym(h, lib.data_skip, "archive_read_data_skip")
		&& @sym(h, lib.read_data_block, "archive_read_data_block")
		&& @sym(h, lib.read_free, "archive_read_free")
		&& @sym(h, lib.error_string, "archive_error_string")
		&& @sym(h, lib.filter_bytes, "archive_filter_bytes")
		&& @sym(h, lib.format, "archive_format")
		&& @sym(h, lib.pathname, "archive_entry_pathname")
		&& @sym(h, lib.pathname_utf8, "archive_entry_pathname_utf8")
		&& @sym(h, lib.hardlink, "archive_entry_hardlink")
		&& @sym(h, lib.size, "archive_entry_size")
		&& @sym(h, lib.mtime, "archive_entry_mtime")
		&& @sym(h, lib.filetype, "archive_entry_filetype")
		&& @sym(h, lib.is_encrypted, "archive_entry_is_encrypted")
		&& @sym(h, lib.copy_pathname, "archive_entry_copy_pathname")
		&& @sym(h, lib.copy_hardlink, "archive_entry_copy_hardlink")
		&& @sym(h, lib.write_disk_new, "archive_write_disk_new")
		&& @sym(h, lib.write_disk_set_options, "archive_write_disk_set_options")
		&& @sym(h, lib.write_header, "archive_write_header")
		&& @sym(h, lib.write_data_block, "archive_write_data_block")
		&& @sym(h, lib.write_finish_entry, "archive_write_finish_entry")
		&& @sym(h, lib.write_close, "archive_write_close")
		&& @sym(h, lib.write_free, "archive_write_free");
}

<* True once load() succeeded. *>
fn bool available() => lib_state > 0;

// ------------------------------------------------------------------------------------------ names

const String[*] ARCHIVE_EXTS @private = {
	".zip", ".jar", ".apk", ".war", ".xpi", ".tar", ".tgz", ".tbz", ".tbz2", ".txz", ".tzst", ".tlz",
	".7z", ".rar", ".iso", ".cpio", ".deb", ".rpm", ".cab", ".lha", ".lzh", ".xar",
};
// Single-file compressors: read as "raw" (one entry) unless the stream holds an archive (foo.tar.gz).
const String[*] RAW_EXTS @private = { ".gz", ".xz", ".bz2", ".zst", ".lz", ".lzma", ".lz4", ".z" };

fn bool is_raw_ext(String name) @private
{
	foreach (e : RAW_EXTS) if (txt::iends_with(name, e)) return true;
	return false;
}

<* True when `name` looks like an archive this module reads (extension only, no I/O). *>
fn bool is_archive(String name)
{
	foreach (e : ARCHIVE_EXTS) if (txt::iends_with(name, e)) return true;
	return is_raw_ext(name);
}

<* `foo.tar.gz` -> `foo`, `bar.zip` -> `bar`, `notes.txt.gz` -> `notes.txt` (a view into `name`; never empty). *>
fn String stem(String name)
{
	String s = name;
	foreach (e : RAW_EXTS)
	{
		if (!txt::iends_with(s, e)) continue;
		s = s[:s.len - e.len];
		if (txt::iends_with(s, ".tar")) s = s[:s.len - 4];
		return s.len ? s : name;
	}
	sz dot = s.rindex_of_char('.') ?? -1;
	if (dot > 0) s = s[:(usz)dot];
	return s.len ? s : name;
}

<*
 Normalize an entry path into `out`: no leading '/', no '.' or empty components, no trailing '/'.
 @return "length, 0 for the root itself, -1 when unsafe ('..') or too long"
*>
fn sz normalize(String p, char[] out)
{
	usz n;
	usz i;
	while (i < p.len)
	{
		while (i < p.len && p[i] == '/') i++;
		usz start = i;
		while (i < p.len && p[i] != '/') i++;
		String c = p[start:i - start];
		if (!c.len || c == ".") continue;
		if (c == ".." || c.len > 255) return -1;
		if (n + 1 + c.len >= out.len) return -1;
		if (n) out[n++] = '/';
		libc::memcpy(&out[n], c.ptr, c.len);
		n += c.len;
	}
	out[n] = 0;
	return (sz)n;
}

// Our own reader (instead of archive_read_open_filename): every read asks `stop`, so a cancel interrupts even
// libarchive skipping a huge compressed entry (closing an Index never waits long on the UI thread).
struct Src @private
{
	CInt fd;
	char* buf;
	long size;
	StopFn stop;
	void* ctx;
}

fn long src_read(void* a, void* data, void** buffer) @private
{
	Src* s = data;
	if (s.stop && s.stop(s.ctx)) return -1;
	while (true)
	{
		sz n = c_read(s.fd, s.buf, BLOCK);
		if (n < 0 && *c_errno() == 4) continue; // EINTR
		*buffer = s.buf;
		return (long)n;
	}
}

fn long src_skip(void* a, void* data, long request) @private
{
	Src* s = data;
	if (s.stop && s.stop(s.ctx)) return -1;
	long cur = c_lseek(s.fd, 0, 1);
	if (cur < 0 || request <= 0) return 0; // not seekable: libarchive reads instead
	long to = math::min(cur + request, s.size);
	if (to <= cur || c_lseek(s.fd, to, 0) < 0) return 0;
	return to - cur;
}

fn long src_seek(void* a, void* data, long offset, CInt whence) @private
{
	Src* s = data;
	return c_lseek(s.fd, offset, whence);
}

fn void src_close(Src* s) @private
{
	if (s.fd >= 0) sys::c_close(s.fd);
	libc::free(s.buf);
	s.fd = -1;
	s.buf = null;
}

<* Open `path` for reading through `src` (fill stop/ctx first). Free with read_free, then src_close. *>
fn void* open_read(String path, bool raw, char[] err, Src* src) @private => @pool()
{
	src.fd = sys::c_open(path.zstr_tcopy(), 0x80000); // O_RDONLY | O_CLOEXEC
	if (src.fd < 0) { txt::set(err, "Cannot open the archive"); return null; }
	libc::Stat st;
	src.size = c_fstat(src.fd, &st) == 0 ? (long)st.st_size : 0;
	src.buf = libc::malloc(BLOCK);
	void* a = src.buf ? lib.read_new() : null;
	if (!a) { txt::set(err, "Out of memory"); return null; }
	lib.filter_all(a);
	lib.format_all(a);
	if (raw) lib.format_raw(a);
	lib.set_read_callback(a, (void*)&src_read);
	lib.set_skip_callback(a, (void*)&src_skip);
	lib.set_seek_callback(a, (void*)&src_seek);
	lib.set_callback_data(a, src);
	if (lib.open1(a) != OK)
	{
		ZString e = lib.error_string(a);
		txt::set(err, e ? e.str_view() : "Cannot open the archive");
		lib.read_free(a);
		return null;
	}
	return a;
}

fn String entry_path(void* e) @private
{
	ZString p = lib.pathname_utf8(e);
	if (!p) p = lib.pathname(e);
	return p ? p.str_view() : "";
}

// ------------------------------------------------------------------------------------------ Index

struct Rec
{
	uint off;       // normalized path in the arena
	ushort len;
	ushort name_at; // start of the last component
	uint seq;       // header order (later duplicates win)
	bool dir;
	bool link;
	bool encrypted;
	long size;
	long mtime;
}

enum Phase { IDLE, LOADING, READY, FAILED }

// Keep at a stable address while started; methods are UI-thread-only.
struct Index
{
	thread::Mutex mutex;
	thread::Thread worker;
	bool started;
	bool ended;
	bool cancel_req;
	bool ok;
	int seen;            // entries read so far (progress)
	ulong bytes_read;    // compressed bytes consumed (progress)
	ulong bytes_total;   // archive size
	bool truncated;      // MAX_ENTRIES / NAME_BYTES reached, or entries with unsafe / too long paths skipped
	bool encrypted;      // at least one encrypted entry
	char[512] error;
	char[4096] path;
	// Worker-owned until ended, read-only afterwards:
	char* arena;
	usz arena_len;
	Rec* recs;
	int count;
}

<* Read the table of contents of `path` (absolute) in the background. False when started, unloadable or no memory. *>
fn bool Index.start(&self, String path)
{
	if (self.started || !path.starts_with("/") || path.len >= self.path.len || !load()) return false;
	self.arena = libc::malloc(NAME_BYTES);
	self.recs = libc::malloc(MAX_ENTRIES * Rec::size);
	if (!self.arena || !self.recs) { free_index(self); return false; }
	if (catch self.mutex.init()) { free_index(self); return false; }
	txt::set(&self.path, path);
	self.arena_len = 0;
	self.count = 0;
	self.seen = 0;
	self.bytes_read = 0;
	self.bytes_total = 0;
	self.truncated = false;
	self.encrypted = false;
	self.ok = false;
	self.error[0] = 0;
	self.cancel_req = false;
	self.ended = false;
	if (catch self.worker.create(&index_work, self)) { self.mutex.destroy(); free_index(self); return false; }
	self.started = true;
	return true;
}

<* Cancel (the reader stops at its next 64 KiB read, even inside a huge entry), wait and free. *>
fn void Index.close(&self)
{
	if (!self.started) return;
	self.mutex.lock();
	self.cancel_req = true;
	self.mutex.unlock();
	self.worker.join()!!;
	self.mutex.destroy();
	free_index(self);
	self.started = false;
	self.count = 0;
	self.path[0] = 0;
}

fn void free_index(Index* self) @private
{
	libc::free(self.arena);
	libc::free(self.recs);
	self.arena = null;
	self.recs = null;
}

<* IDLE (not started), LOADING, READY or FAILED (error_text()). One lock. *>
fn Phase Index.phase(&self)
{
	if (!self.started) return IDLE;
	self.mutex.lock();
	defer self.mutex.unlock();
	if (!self.ended) return LOADING;
	return self.ok ? READY : FAILED;
}

<* Entries read so far and compressed bytes consumed of bytes_total (one lock). *>
fn void Index.progress(&self, int* entries, ulong* done, ulong* total)
{
	self.mutex.lock();
	*entries = self.seen;
	*done = self.bytes_read;
	*total = self.bytes_total;
	self.mutex.unlock();
}

fn String Index.error_text(&self) => txt::view(&self.error);
fn String Index.file(&self) => txt::view(&self.path);
<* Entries (READY). *>
fn int Index.entries(&self) => self.ended && self.ok ? self.count : 0;
fn String Index.rel(&self, int i) => (String)self.arena[self.recs[i].off : self.recs[i].len];
fn String Index.name(&self, int i) => (String)self.arena[self.recs[i].off + self.recs[i].name_at : self.recs[i].len - self.recs[i].name_at];
fn bool Index.is_dir(&self, int i) => self.recs[i].dir;
fn bool Index.is_link(&self, int i) => self.recs[i].link;
fn long Index.size(&self, int i) => self.recs[i].size;
fn long Index.mtime(&self, int i) => self.recs[i].mtime;

fn int cmp_bytes(String a, String b) @private
{
	usz n = a.len < b.len ? a.len : b.len;
	int c = n ? libc::memcmp(a.ptr, b.ptr, n) : 0;
	if (c) return c;
	return a.len < b.len ? -1 : a.len > b.len ? 1 : 0;
}

fn int rec_cmp(Rec* a, Rec* b, char* arena) @private
{
	int c = cmp_bytes((String)arena[a.off : a.len], (String)arena[b.off : b.len]);
	if (c) return c;
	return a.seq < b.seq ? -1 : a.seq > b.seq ? 1 : 0;
}

<* First index whose path is >= `key` within [0, n). *>
fn int lower_bound(Index* self, int n, String key) @private
{
	int lo = 0;
	int hi = n;
	while (lo < hi)
	{
		int mid = (lo + hi) / 2;
		if (cmp_bytes(self.rel(mid), key) < 0) { lo = mid + 1; } else { hi = mid; }
	}
	return lo;
}

<* Entry with this normalized path ("" = none), or -1 (READY only). *>
fn int Index.find(&self, String rel)
{
	int n = self.entries();
	int i = lower_bound(self, n, rel);
	return i < n && self.rel(i) == rel ? i : -1;
}

<* True when `rel` is a folder of the archive ("" = its root). *>
fn bool Index.has_dir(&self, String rel)
{
	if (!rel.len) return self.ended && self.ok;
	int i = self.find(rel);
	return i >= 0 && self.recs[i].dir;
}

<*
 Direct children of folder `rel` ("" = root) into `out`, folders first, alphabetical (like sys::list_dir).
 Linear in the folder's subtree; call on navigation only.
 @return "number of entries written"
*>
fn int Index.list(&self, String rel, sys::Entry[] out, bool hidden) => @pool()
{
	int n = self.entries();
	String prefix = rel.len ? rel.tconcat("/") : "";
	int written;
	for (int i = lower_bound(self, n, prefix); i < n && written < out.len; i++)
	{
		String p = self.rel(i);
		if (!p.starts_with(prefix)) break;
		if (self.recs[i].name_at != prefix.len) continue;
		String name = self.name(i);
		if (!hidden && name[0] == '.') continue;
		txt::set(&out[written].name, name);
		out[written].dir = self.recs[i].dir;
		written++;
	}
	sort::quicksort(out[:written], &sys::entry_compare);
	return written;
}

fn void set_index_error(Index* self, String e) @private
{
	self.mutex.lock();
	if (!self.error[0]) txt::set(&self.error, e);
	self.mutex.unlock();
}

fn int index_work(void* arg) @private
{
	Index* self = arg;
	bool ok;
	// Temp memory for the few path helpers (only the main thread has one implicitly).
	@pool_init(mem, 64 * 1024) { ok = read_index(self); };
	self.mutex.lock();
	self.ok = ok && !self.cancel_req;
	self.ended = true;
	self.mutex.unlock();
	return 0;
}

fn bool index_stop(void* ctx) @private => index_stopped((Index*)ctx);

fn bool index_stopped(Index* self) @private
{
	self.mutex.lock();
	defer self.mutex.unlock();
	return self.cancel_req;
}

fn bool add_rec(Index* self, String p, bool dir, bool link, bool enc, long size, long mtime) @private
{
	if (self.count >= MAX_ENTRIES || self.arena_len + p.len > NAME_BYTES) { self.truncated = true; return false; }
	Rec* r = &self.recs[self.count];
	*r = { .off = (uint)self.arena_len, .len = (ushort)p.len, .seq = (uint)self.count, .dir = dir, .link = link, .encrypted = enc, .size = size, .mtime = mtime };
	r.name_at = (ushort)((p.rindex_of_char('/') ?? -1) + 1);
	libc::memcpy(self.arena + self.arena_len, p.ptr, p.len);
	self.arena_len += p.len;
	self.count++;
	return true;
}

fn bool read_index(Index* self) @private => @pool()
{
	String path = txt::view(&self.path);
	libc::Stat st;
	if (libc::stat(path.zstr_tcopy(), &st) != 0) { set_index_error(self, "Cannot read the archive"); return false; }
	self.mutex.lock();
	self.bytes_total = (ulong)st.st_size;
	self.mutex.unlock();
	char[512] err;
	Src src = { .fd = -1, .stop = &index_stop, .ctx = self };
	defer src_close(&src);
	void* a = open_read(path, is_raw_ext(path), &err, &src);
	if (!a) { set_index_error(self, txt::view(&err)); return false; }
	defer lib.read_free(a);
	char[4096] norm;
	bool raw;
	while (true)
	{
		if (index_stopped(self)) return false;
		void* e;
		CInt r = lib.next_header(a, &e);
		if (r == EOF) break;
		if (r < WARN)
		{
			ZString m = lib.error_string(a);
			set_index_error(self, m ? m.str_view() : "Cannot read the archive");
			return false;
		}
		if (!raw && lib.format(a) == FORMAT_RAW) raw = true;
		sz n;
		if (raw) { n = normalize(stem(txt::basename(path)), &norm); }
		else { n = normalize(entry_path(e), &norm); }
		CUInt type = lib.filetype(e) & AE_IFMT;
		bool enc = lib.is_encrypted(e) > 0;
		if (n < 0) { self.truncated = true; }
		else if (n > 0)
		{
			if (!add_rec(self, (String)norm[:(usz)n], type == AE_IFDIR, type == AE_IFLNK, enc, raw ? -1 : lib.size(e), lib.mtime(e))) break;
			if (enc) self.encrypted = true;
		}
		// Raw streams have no size header and are read to the end only when extracted.
		if (raw) break;
		lib.data_skip(a);
		self.mutex.lock();
		self.seen++;
		long b = lib.filter_bytes(a, -1);
		if (b > 0) self.bytes_read = (ulong)b;
		self.mutex.unlock();
	}
	finish_index(self);
	return true;
}

<* Sort, drop duplicate paths (the later header wins) and add folders that only exist implicitly. *>
fn void finish_index(Index* self) @private
{
	sort::quicksort(self.recs[:self.count], &rec_cmp, self.arena);
	dedupe(self);
	int n0 = self.count;
	for (int i = 0; i < n0; i++)
	{
		String p = self.rel(i);
		for (usz k = 0; k < p.len; k++)
		{
			if (p[k] != '/') continue;
			String parent = p[:k];
			int at = lower_bound(self, n0, parent);
			if (at < n0 && self.rel(at) == parent) continue;
			// Implied folder: a prefix of an existing path, so it shares that path's arena bytes.
			if (self.count >= MAX_ENTRIES) { self.truncated = true; break; }
			int c = self.count++;
			self.recs[c] = { .off = self.recs[i].off, .len = (ushort)k, .name_at = (ushort)((parent.rindex_of_char('/') ?? -1) + 1), .seq = (uint)c, .dir = true };
		}
	}
	if (self.count == n0) return;
	sort::quicksort(self.recs[:self.count], &rec_cmp, self.arena);
	dedupe(self);
}

fn void dedupe(Index* self) @private
{
	if (self.count < 2) return;
	int w;
	for (int i = 0; i < self.count; i++)
	{
		// Sorted by path, then header order: the last of equal paths wins (a tar can repeat a path).
		if (i + 1 < self.count && self.rel(i) == self.rel(i + 1)) continue;
		self.recs[w++] = self.recs[i];
	}
	self.count = w;
}

// ------------------------------------------------------------------------------------------ extract

alias ProgressFn = fn void(void* ctx, ulong done, ulong total, String name);
alias StopFn = fn bool(void* ctx);

<* Callbacks and result details for extract(). *>
struct Sink
{
	void* ctx;
	ProgressFn progress; // per entry and per data block (may be null)
	StopFn stop;         // polled as often; true cancels (may be null)
	char[512] error;     // failure text
	int files;           // entries written
	int skipped;         // hard links to entries outside the selection
}

enum Result { DONE, CANCELLED, FAILED }

<*
 Write the entries of archive `path` below folder `inner` (normalized, "" = everything) into `dest` (an
 existing, absolute, symlink-free folder). With `names`, only those direct children of `inner` (and what is
 below them) are written. Paths are relative to `inner`. Blocking: call on a worker thread that has temp
 memory (fileop's worker does), after load() on the UI thread.
*>
fn Result extract(String path, String inner, String[] names, String dest, Sink* s) => @pool()
{
	if (!load()) { txt::set(&s.error, "libarchive is not installed"); return FAILED; }
	libc::Stat st;
	ulong total = libc::stat(path.zstr_tcopy(), &st) == 0 ? (ulong)st.st_size : 0;
	Src src = { .fd = -1, .stop = s.stop, .ctx = s.ctx };
	defer src_close(&src);
	void* a = open_read(path, is_raw_ext(path), &s.error, &src);
	if (!a) return FAILED;
	defer lib.read_free(a);
	void* w = lib.write_disk_new();
	if (!w) { txt::set(&s.error, "Out of memory"); return FAILED; }
	defer lib.write_free(w);
	lib.write_disk_set_options(w, EXTRACT_TIME | EXTRACT_SECURE_SYMLINKS | EXTRACT_SECURE_NODOTDOT);
	char[4096] norm;
	char[4096] target;
	bool raw;
	String raw_name = stem(txt::basename(path));
	Result res = DONE;
	while (res == DONE)
	{
		if (s.stop && s.stop(s.ctx)) { res = CANCELLED; break; }
		void* e;
		CInt r = lib.next_header(a, &e);
		if (r == EOF) break;
		if (r < WARN) { res = fail_with(s, lib.error_string(a), "Cannot read the archive"); break; }
		if (!raw && lib.format(a) == FORMAT_RAW) raw = true;
		sz n = normalize(raw ? raw_name : entry_path(e), &norm);
		if (n <= 0) continue; // root or unsafe path: never written
		String rel;
		if (!selected((String)norm[:(usz)n], inner, names, &rel)) continue;
		if (lib.is_encrypted(e) > 0) { txt::set(&s.error, "Encrypted archives are not supported"); res = FAILED; break; }
		if (!place(dest, rel, &target)) { txt::set(&s.error, "Path too long"); res = FAILED; break; }
		lib.copy_pathname(e, (ZString)&target);
		ZString hl = lib.hardlink(e);
		if (hl)
		{
			char[4096] hn;
			String hrel;
			sz m = normalize(hl.str_view(), &hn);
			if (m <= 0 || !selected((String)hn[:(usz)m], inner, names, &hrel)) { s.skipped++; continue; }
			char[4096] ht;
			if (!place(dest, hrel, &ht)) { txt::set(&s.error, "Path too long"); res = FAILED; break; }
			lib.copy_hardlink(e, (ZString)&ht);
		}
		if (s.progress) s.progress(s.ctx, (ulong)math::max(0L, lib.filter_bytes(a, -1)), total, rel);
		r = lib.write_header(w, e);
		if (r < WARN) { res = fail_with(s, lib.error_string(w), "Cannot write", rel); break; }
		res = copy_data(a, w, s, total, rel);
		if (res != DONE) break;
		if (lib.write_finish_entry(w) < WARN) { res = fail_with(s, lib.error_string(w), "Cannot write", rel); break; }
		s.files++;
		if (raw) break;
	}
	// Folder permissions and times are applied here (after their contents).
	if (lib.write_close(w) < WARN && res == DONE) res = fail_with(s, lib.error_string(w), "Cannot finish writing");
	return res;
}

fn Result copy_data(void* a, void* w, Sink* s, ulong total, String rel) @private
{
	while (true)
	{
		if (s.stop && s.stop(s.ctx)) return CANCELLED;
		void* buf;
		usz size;
		long off;
		CInt r = lib.read_data_block(a, &buf, &size, &off);
		if (r == EOF) return DONE;
		if (r < WARN) return fail_with(s, lib.error_string(a), "Cannot read", rel);
		if (lib.write_data_block(w, buf, size, off) < 0) return fail_with(s, lib.error_string(w), "Cannot write", rel);
		if (s.progress) s.progress(s.ctx, (ulong)math::max(0L, lib.filter_bytes(a, -1)), total, rel);
	}
}

fn Result fail_with(Sink* s, ZString lib_error, String what, String name = "") @private
{
	txt::set(&s.error, what);
	if (name.len) { txt::append(&s.error, " \""); txt::append(&s.error, name); txt::append(&s.error, "\""); }
	if (lib_error) { txt::append(&s.error, ": "); txt::append(&s.error, lib_error.str_view()); }
	return FAILED;
}

<* Is normalized `p` inside `inner` (and one of `names` there)? `rel` = its path relative to `inner`. *>
fn bool selected(String p, String inner, String[] names, String* rel) @private
{
	String r = p;
	if (inner.len)
	{
		if (p.len <= inner.len + 1 || !p.starts_with(inner) || p[inner.len] != '/') return false;
		r = p[inner.len + 1..];
	}
	if (names.len)
	{
		sz slash = r.index_of_char('/') ?? -1;
		String first = slash >= 0 ? r[:(usz)slash] : r;
		bool hit;
		foreach (nm : names) if (nm == first) { hit = true; break; }
		if (!hit) return false;
	}
	*rel = r;
	return true;
}

fn bool place(String dest, String rel, char[] out) @private
{
	if (dest.len + 1 + rel.len >= out.len) return false;
	libc::memcpy(&out[0], dest.ptr, dest.len);
	out[dest.len] = '/';
	libc::memcpy(&out[dest.len + 1], rel.ptr, rel.len);
	out[dest.len + 1 + rel.len] = 0;
	return true;
}
