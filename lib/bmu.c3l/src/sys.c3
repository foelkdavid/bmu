module bmu::sys;
import std::io, std::core::string, libc;
import bmu::txt;

// bmu::sys - thin POSIX layer (Linux x86_64, glibc or musl): file tests, mkdir -p,
// directory listing, env, process spawning primitives. The c_* externs are the raw
// libc calls; the plain functions are the safe wrappers apps should use.

extern fn CInt c_fork() @cname("fork");
extern fn CInt c_setsid() @cname("setsid");
extern fn CInt c_execvpe(ZString file, ZString* argv, ZString* envp) @cname("execvpe");
extern fn CInt c_dup2(CInt old, CInt new) @cname("dup2");
extern fn CInt c_open(ZString path, CInt flags, ...) @cname("open");
extern fn CInt c_close(CInt fd) @cname("close");
extern fn sz c_write(CInt fd, char* buf, usz len) @cname("write");
extern fn CInt c_chdir(ZString path) @cname("chdir");
extern fn CInt c_waitpid(CInt pid, CInt* status, CInt options) @cname("waitpid");
extern fn CInt c_kill(CInt pid, CInt sig) @cname("kill");
extern fn CInt c_access(ZString path, CInt mode) @cname("access");
extern fn CInt c_mkdir(ZString path, uint mode) @cname("mkdir");
extern fn void c_exit(CInt code) @cname("_exit");
extern fn void* c_opendir(ZString path) @cname("opendir");
extern fn Dirent* c_readdir(void* dir) @cname("readdir");
extern fn CInt c_closedir(void* dir) @cname("closedir");
extern fn ZString c_realpath(ZString path, char* resolved) @cname("realpath");
extern fn long c_time(long* t) @cname("time");
extern ZString* environ @cname("environ");
extern fn CInt c_usleep(uint usec) @cname("usleep");
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
struct Dirent
{
	ulong ino;
	long off;
	ushort reclen;
	char type;
	char[256] name;
}

fn long now() => c_time(null);

fn bool exists(String p) => @pool()
{
	libc::Stat st;
	return libc::stat(p.zstr_tcopy(), &st) == 0;
}

fn bool is_dir(String p) => @pool()
{
	libc::Stat st;
	if (libc::stat(p.zstr_tcopy(), &st) != 0) return false;
	return (st.st_mode & 0xF000) == 0x4000;
}

fn bool is_file(String p) => @pool()
{
	libc::Stat st;
	if (libc::stat(p.zstr_tcopy(), &st) != 0) return false;
	return (st.st_mode & 0xF000) == 0x8000;
}

fn bool is_exec(String p) => @pool()
{
	return is_file(p) && c_access(p.zstr_tcopy(), X_OK) == 0;
}

// mkdir -p
fn bool mkdirs(String p) => @pool()
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
fn void realpath(char[] out, String p) => @pool()
{
	char[4096] tmp;
	ZString r = c_realpath(p.zstr_tcopy(), &tmp);
	txt::set(out, r ? r.str_view() : p);
}

fn String home()
{
	ZString h = libc::getenv("HOME");
	return h ? h.str_view() : "/";
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
fn int list_dir(String dir, Entry[] out, bool hidden) => @pool()
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
	// insertion sort: dirs first, then case-insensitive name
	for (int i = 1; i < n; i++)
	{
		Entry key = out[i];
		int j = i - 1;
		while (j >= 0 && entry_less(&key, &out[j]))
		{
			out[j + 1] = out[j];
			j--;
		}
		out[j + 1] = key;
	}
	return n;
}

fn bool entry_less(Entry* a, Entry* b)
{
	if (a.dir != b.dir) return a.dir;
	return txt::icmp(txt::view(&a.name), txt::view(&b.name)) < 0;
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
