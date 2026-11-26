module bmu::sys;
import std::io, std::core::string, std::sort, std::time, libc;
import bmu::txt;

// bmu::sys - thin POSIX layer (Linux x86_64, glibc or musl): file tests, mkdir -p,
// directory listing, env, process spawning primitives. The c_* externs are the raw
// libc calls; the plain functions are the safe wrappers apps should use.
// macOS / Windows: the plain file, folder and env functions work (through the C3 standard library); the c_*
// process externs are Linux only.

extern fn CInt c_fork() @cname("fork") @feat(LINUX);
extern fn CInt c_setsid() @cname("setsid") @feat(LINUX);
extern fn CInt c_execvpe(ZString file, ZString* argv, ZString* envp) @cname("execvpe") @feat(LINUX);
extern fn CInt c_dup2(CInt old, CInt new) @cname("dup2") @feat(LINUX);
extern fn CInt c_open(ZString path, CInt flags, ...) @cname("open") @feat(LINUX);
extern fn CInt c_close(CInt fd) @cname("close") @feat(LINUX);
extern fn sz c_write(CInt fd, char* buf, usz len) @cname("write") @feat(LINUX);
extern fn CInt c_chdir(ZString path) @cname("chdir") @feat(LINUX);
extern fn CInt c_waitpid(CInt pid, CInt* status, CInt options) @cname("waitpid") @feat(LINUX);
extern fn CInt c_kill(CInt pid, CInt sig) @cname("kill") @feat(LINUX);
extern fn CInt c_access(ZString path, CInt mode) @cname("access") @feat(LINUX);
extern fn CInt c_mkdir(ZString path, uint mode) @cname("mkdir") @feat(LINUX);
extern fn void c_exit(CInt code) @cname("_exit") @feat(LINUX);
extern fn void* c_opendir(ZString path) @cname("opendir") @feat(LINUX);
extern fn Dirent* c_readdir(void* dir) @cname("readdir") @feat(LINUX);
extern fn CInt c_closedir(void* dir) @cname("closedir") @feat(LINUX);
extern fn ZString c_realpath(ZString path, char* resolved) @cname("realpath") @feat(LINUX);
extern fn long c_time(long* t) @cname("time") @feat(LINUX);
extern ZString* environ @cname("environ") @feat(LINUX);
extern fn CInt c_usleep(uint usec) @cname("usleep") @feat(LINUX);
extern fn CInt c_rename(ZString from, ZString to) @cname("rename");

const CInt O_RDONLY = 0;
const CInt O_WRONLY = 1;
const CInt O_CREAT = 0x40;
const CInt O_TRUNC = 0x200;
const CInt O_APPEND = 0x400;
const CInt WNOHANG = 1;
const CInt SIGTERM = 15;
const CInt SIGKILL = 9;
const CInt X_OK = 1;

const char DT_UNKNOWN = 0;
const char DT_DIR = 4;
const char DT_LNK = 10;

// glibc / musl x86_64 layout.
struct Dirent @feat(LINUX)
{
	ulong ino;
	long off;
	ushort reclen;
	char type;
	char[256] name;
}

fn long now() @feat(LINUX) => c_time(null);
fn long now() @feat(!LINUX) => (long)time::now().to_seconds();

fn bool exists(String p) @feat(!LINUX) => file::exists(p);
fn bool is_dir(String p) @feat(!LINUX) => file::is_dir(p);
fn bool is_file(String p) @feat(!LINUX) => file::is_file(p);
fn bool is_exec(String p) @feat(!LINUX) => is_file(p);

fn bool exists(String p) @feat(LINUX) => @pool()
{
	libc::Stat st;
	return libc::stat(p.zstr_tcopy(), &st) == 0;
}

fn bool is_dir(String p) @feat(LINUX) => @pool()
{
	libc::Stat st;
	if (libc::stat(p.zstr_tcopy(), &st) != 0) return false;
	return (st.st_mode & 0xF000) == 0x4000;
}

fn bool is_file(String p) @feat(LINUX) => @pool()
{
	libc::Stat st;
	if (libc::stat(p.zstr_tcopy(), &st) != 0) return false;
	return (st.st_mode & 0xF000) == 0x8000;
}

fn bool is_exec(String p) @feat(LINUX) => @pool()
{
	return is_file(p) && c_access(p.zstr_tcopy(), X_OK) == 0;
}

// mkdir -p
fn bool mkdirs(String p) @feat(!LINUX)
{
	if (p.len == 0) return false;
	if (is_dir(p)) return true;
	(void)path::mkdir(p, true);
	return is_dir(p);
}

fn bool mkdirs(String p) @feat(LINUX) => @pool()
{
	if (p.len == 0) return false;
	if (is_dir(p)) return true;
	char[1024] buf;
	txt::set(&buf, p);
	usz n = txt::view(&buf).len;
	for (usz i = 1; i <= n; i++)
	{
		if (i == n || buf[i] == '/')
		{
			char saved = buf[i];
			buf[i] = 0;
			c_mkdir(txt::z(&buf), 0o755);
			buf[i] = saved;
		}
	}
	return is_dir(p);
}

// Resolve symlinks / "..". Falls back to the input when the path does not exist.
fn void realpath(char[] out, String p) @feat(!LINUX) => @pool()
{
	if (try r = p.to_absolute_path(tmem)) p = (String)r;
	txt::set(out, p);
	$if env::WIN32:
		foreach (&c : out) if (*c == '\\') *c = '/';   // one separator for txt::basename / dirname
	$endif
}

fn void realpath(char[] out, String p) @feat(LINUX) => @pool()
{
	char[4096] tmp;
	ZString r = c_realpath(p.zstr_tcopy(), &tmp);
	txt::set(out, r ? r.str_view() : p);
}

fn String home()
{
	$if env::WIN32:
		ZString h = libc::getenv("USERPROFILE");
		return h ? h.str_view() : "C:/";
	$else
		ZString h = libc::getenv("HOME");
		return h ? h.str_view() : "/";
	$endif
}

fn String env(String name) => @pool()
{
	ZString v = libc::getenv(name.zstr_tcopy());
	return v ? v.str_view() : "";
}

// Directory listing ---------------------------------------------------------

struct Entry
{
	char[256] name;
	bool dir;
}

<*
 List `dir` into `out`, directories first, alphabetical.
 @return "number of entries written"
*>
fn int list_dir(String dir, Entry[] out, bool hidden) @feat(!LINUX) => @pool()
{
	if (!is_dir(dir)) return -1;
	PathList? list = path::ls(tmem, path::tnew(dir) ?? (Path)".");
	if (catch list) return -1;
	int n = 0;
	foreach (pth : list)
	{
		if (n >= out.len) break;
		String name = pth.basename();
		if (name == "." || name == ".." || name.len == 0) continue;
		if (!hidden && name[0] == '.') continue;
		txt::set(&out[n].name, name);
		out[n].dir = is_dir(txt::join(dir, name));
		n++;
	}
	sort::quicksort(out[:n], &entry_compare);
	return n;
}

fn int list_dir(String dir, Entry[] out, bool hidden) @feat(LINUX) => @pool()
{
	void* d = c_opendir(dir.zstr_tcopy());
	if (!d) return -1;
	int n = 0;
	while (n < out.len)
	{
		Dirent* e = c_readdir(d);
		if (!e) break;
		String name = ((ZString)&e.name).str_view();
		if (name == "." || name == "..") continue;
		if (!hidden && name[0] == '.') continue;
		bool isdir = e.type == DT_DIR;
		if (e.type == DT_UNKNOWN || e.type == DT_LNK) isdir = is_dir(txt::join(dir, name));
		txt::set(&out[n].name, name);
		out[n].dir = isdir;
		n++;
	}
	c_closedir(d);
	// In-place quicksort (average O(n log n)) instead of quadratic insertion sort.
	sort::quicksort(out[:n], &entry_compare);
	return n;
}

// Folder watch ----------------------------------------------------------------

extern fn CInt c_inotify_init1(CInt flags) @cname("inotify_init1") @feat(LINUX) @private;
extern fn CInt c_inotify_add_watch(CInt fd, ZString path, uint mask) @cname("inotify_add_watch") @feat(LINUX) @private;
extern fn CInt c_inotify_rm_watch(CInt fd, CInt wd) @cname("inotify_rm_watch") @feat(LINUX) @private;
extern fn sz c_read_watch(CInt fd, void* buf, usz n) @cname("read") @feat(LINUX) @private;

// Entries appear, disappear or are renamed; the folder itself is deleted or moved. Content writes are not reported.
const uint WATCH_MASK @private = 0x40 | 0x80 | 0x100 | 0x200 | 0x400 | 0x800 | 0x01000000; // MOVED_FROM/TO CREATE DELETE DELETE_SELF MOVE_SELF ONLYDIR

<* Watches one folder for entries being added, removed or renamed (inotify; elsewhere nothing is reported).
   Call watch() on navigation and changed() once per frame: a non-blocking read, no file system work. *>
struct DirWatch
{
	CInt fd; // inotify descriptor + 1 (0 = not created yet)
	CInt wd; // watch descriptor + 1 (0 = nothing watched)
}

<* Watch `dir` instead of the previous folder (the descriptor is created on first use). False = not watched. *>
fn bool DirWatch.watch(&self, String dir) @feat(LINUX) => @pool()
{
	if (!self.fd)
	{
		CInt fd = c_inotify_init1(0x800 | 0x80000); // IN_NONBLOCK | IN_CLOEXEC
		if (fd < 0) return false;
		self.fd = fd + 1;
	}
	if (self.wd) c_inotify_rm_watch(self.fd - 1, self.wd - 1);
	CInt wd = c_inotify_add_watch(self.fd - 1, dir.zstr_tcopy(), WATCH_MASK);
	self.wd = wd < 0 ? 0 : wd + 1;
	self.changed(); // drop events of the previous folder
	return wd >= 0;
}

<* True when the watched folder changed since the last call (drains all pending events; never blocks). *>
fn bool DirWatch.changed(&self) @feat(LINUX)
{
	if (!self.fd) return false;
	char[4096] buf @align(8);
	bool seen;
	while (c_read_watch(self.fd - 1, &buf, buf.len) > 0) seen = true;
	return seen && self.wd;
}

fn void DirWatch.close(&self) @feat(LINUX)
{
	if (self.fd) c_close(self.fd - 1);
	*self = {};
}

fn bool DirWatch.watch(&self, String dir) @feat(!LINUX) => false;
fn bool DirWatch.changed(&self) @feat(!LINUX) => false;
fn void DirWatch.close(&self) @feat(!LINUX) {}

fn int entry_compare(Entry* a, Entry* b)
{
	if (a.dir != b.dir) return a.dir ? -1 : 1;
	return txt::icmp(txt::view(&a.name), txt::view(&b.name));
}

// Small file helpers ---------------------------------------------------------

fn String? read_temp(String path)
{
	char[] data = file::load_temp(path)!;
	return (String)data;
}

// Last `max` bytes of a file, temp memory.
fn String read_tail(String path, usz max)
{
	File? f = file::open(path, "rb");
	if (catch f) return "";
	defer (void)f.close();
	long? size = f.size();
	if (catch size) return "";
	long start = size > (long)max ? size - (long)max : 0;
	if (catch f.seek(start)) return "";
	usz len = (usz)(size - start);
	char[] buf = mem::talloc_array(char, (sz)len + 1);
	sz? got = f.read(buf[:len]);
	if (catch got) return "";
	return (String)buf[:(usz)got];
}

// rename(2); fails across filesystems or when `to` exists as a non-empty dir.
fn bool move(String from, String to) => @pool()
{
	return c_rename(from.zstr_tcopy(), to.zstr_tcopy()) == 0;
}

extern fn long c_syscall_rename(long n, ...) @cname("syscall") @feat(LINUX) @private;
extern fn CInt c_lstat_rename(ZString path, libc::Stat* st) @cname("lstat") @feat(LINUX) @private;
extern fn CInt* c_errno_rename() @cname("__errno_location") @feat(LINUX) @private;

<* rename(2) that never replaces an existing `to` (renameat2 RENAME_NOREPLACE): false with errno EEXIST (17) when
   something has that name. File systems without RENAME_NOREPLACE: lstat check, then rename (a small race). *>
fn bool move_noreplace(String from, String to) @feat(LINUX) => @pool()
{
	return move_noreplace_z(from.zstr_tcopy(), to.zstr_tcopy());
}

fn bool move_noreplace_z(ZString from, ZString to) @feat(LINUX)
{
	if (c_syscall_rename(316, (long)-100, from, (long)-100, to, 1L) == 0) return true; // x86_64 renameat2, AT_FDCWD
	CInt e = *c_errno_rename();
	if (e != 22 && e != 38) return false; // EINVAL / ENOSYS: no RENAME_NOREPLACE here
	libc::Stat st;
	if (c_lstat_rename(to, &st) == 0) { *c_errno_rename() = 17; return false; }
	return c_rename(from, to) == 0;
}

fn bool write_file(String path, String data)
{
	if (catch file::save(path, data)) return false;
	return true;
}
