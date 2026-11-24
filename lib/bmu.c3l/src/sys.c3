module bmu::sys;
import std::io, std::core::string, std::sort, std::time, libc;
import bmu::txt;

// bmu::sys - thin POSIX layer (Linux x86_64, glibc or musl): file tests, mkdir -p,
// directory listing, env, process spawning primitives. The c_* externs are the raw
// libc calls; the plain functions are the safe wrappers apps should use.
// macOS / Windows: the plain file, folder and env functions work (through the C3 standard library); the c_*
// process externs are Linux only.

extern fn CInt c_fork() @cname("fork") @if(env::LINUX);
extern fn CInt c_setsid() @cname("setsid") @if(env::LINUX);
extern fn CInt c_execvpe(ZString file, ZString* argv, ZString* envp) @cname("execvpe") @if(env::LINUX);
extern fn CInt c_dup2(CInt old, CInt new) @cname("dup2") @if(env::LINUX);
extern fn CInt c_open(ZString path, CInt flags, ...) @cname("open") @if(env::LINUX);
extern fn CInt c_close(CInt fd) @cname("close") @if(env::LINUX);
extern fn sz c_write(CInt fd, char* buf, usz len) @cname("write") @if(env::LINUX);
extern fn CInt c_chdir(ZString path) @cname("chdir") @if(env::LINUX);
extern fn CInt c_waitpid(CInt pid, CInt* status, CInt options) @cname("waitpid") @if(env::LINUX);
extern fn CInt c_kill(CInt pid, CInt sig) @cname("kill") @if(env::LINUX);
extern fn CInt c_access(ZString path, CInt mode) @cname("access") @if(env::LINUX);
extern fn CInt c_mkdir(ZString path, uint mode) @cname("mkdir") @if(env::LINUX);
extern fn void c_exit(CInt code) @cname("_exit") @if(env::LINUX);
extern fn void* c_opendir(ZString path) @cname("opendir") @if(env::LINUX);
extern fn Dirent* c_readdir(void* dir) @cname("readdir") @if(env::LINUX);
extern fn CInt c_closedir(void* dir) @cname("closedir") @if(env::LINUX);
extern fn ZString c_realpath(ZString path, char* resolved) @cname("realpath") @if(env::LINUX);
extern fn long c_time(long* t) @cname("time") @if(env::LINUX);
extern ZString* environ @cname("environ") @if(env::LINUX);
extern fn CInt c_usleep(uint usec) @cname("usleep") @if(env::LINUX);
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
struct Dirent @if(env::LINUX)
{
	ulong ino;
	long off;
	ushort reclen;
	char type;
	char[256] name;
}

fn long now() @if(env::LINUX) => c_time(null);
fn long now() @if(!env::LINUX) => (long)time::now().to_seconds();

fn bool exists(String p) @if(!env::LINUX) => file::exists(p);
fn bool is_dir(String p) @if(!env::LINUX) => file::is_dir(p);
fn bool is_file(String p) @if(!env::LINUX) => file::is_file(p);
fn bool is_exec(String p) @if(!env::LINUX) => is_file(p);

fn bool exists(String p) @if(env::LINUX) => @pool()
{
	libc::Stat st;
	return libc::stat(p.zstr_tcopy(), &st) == 0;
}

fn bool is_dir(String p) @if(env::LINUX) => @pool()
{
	libc::Stat st;
	if (libc::stat(p.zstr_tcopy(), &st) != 0) return false;
	return (st.st_mode & 0xF000) == 0x4000;
}

fn bool is_file(String p) @if(env::LINUX) => @pool()
{
	libc::Stat st;
	if (libc::stat(p.zstr_tcopy(), &st) != 0) return false;
	return (st.st_mode & 0xF000) == 0x8000;
}

fn bool is_exec(String p) @if(env::LINUX) => @pool()
{
	return is_file(p) && c_access(p.zstr_tcopy(), X_OK) == 0;
}

// mkdir -p
fn bool mkdirs(String p) @if(!env::LINUX)
{
	if (p.len == 0) return false;
	if (is_dir(p)) return true;
	(void)path::mkdir(p, true);
	return is_dir(p);
}

fn bool mkdirs(String p) @if(env::LINUX) => @pool()
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
fn void realpath(char[] out, String p) @if(!env::LINUX) => @pool()
{
	if (try r = p.to_absolute_path(tmem)) p = (String)r;
	txt::set(out, p);
	$if env::WIN32:
		foreach (&c : out) if (*c == '\\') *c = '/';   // one separator for txt::basename / dirname
	$endif
}

fn void realpath(char[] out, String p) @if(env::LINUX) => @pool()
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
fn int list_dir(String dir, Entry[] out, bool hidden) @if(!env::LINUX) => @pool()
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

fn int list_dir(String dir, Entry[] out, bool hidden) @if(env::LINUX) => @pool()
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

fn bool write_file(String path, String data)
{
	if (catch file::save(path, data)) return false;
	return true;
}
