module bmu::image;
import std::thread, libc;
import raylib6::rl;
import bmu::txt, bmu::sys;

// CPU-only decoder symbols supplied by the bundled raylib/stb_image archive.
extern fn int c_fstat(int fd, libc::Stat* st) @cname("fstat");
extern fn int stbi_info_from_memory(char* data, int len, int* w, int* h, int* channels);
const usz MAX_FILE_BYTES = 32 * 1024 * 1024;
const long MAX_PIXELS = 32 * 1000 * 1000;
const int MAX_EDGE = 16384;
const int PREVIEW_EDGE = 1600;
enum Status { READY, READ_ERROR, INVALID_IMAGE, TOO_LARGE, NO_MEMORY }
struct Result
{
	Status status;
	rl::RLImage pixels;
	int width;
	int height;
}

// Keep at a stable address until close(); methods are UI-thread-only.
struct Limits
{
	int max_edge;          // downsample so the longer edge fits; 0 = PREVIEW_EDGE (1600), >= MAX_EDGE = full size
	usz max_file_bytes;    // 0 = MAX_FILE_BYTES (32 MiB)
	long max_pixels;       // source width * height; 0 = MAX_PIXELS (32,000,000)
	int fit_w;             // also downsample to fit inside fit_w x fit_h (e.g. the screen in physical px); 0 = no box
	int fit_h;
}

struct Loader
{
	Limits limits;         // set before the first request (read with the request, under the lock)
	thread::Mutex mutex;
	thread::ConditionVariable wake;
	thread::Thread worker;
	bool started;
	bool stopping;
	bool pending;
	bool available;
	ulong generation;
	char[4096] path;
	Result result;
}

fn Result decode(String path, Limits lim) @private
{
	char[4096] filename;
	txt::set(&filename, path);
	// Nonblocking open plus fstat rejects special files without waiting on FIFOs.
	int fd = sys::c_open(txt::z(&filename), sys::O_RDONLY | 0x800);
	if (fd < 0) return { .status = READ_ERROR };
	defer sys::c_close(fd);
	libc::Stat st;
	if (c_fstat(fd, &st) != 0 || (st.st_mode & 0xF000) != 0x8000) return { .status = READ_ERROR };
	usz max_file = lim.max_file_bytes ? lim.max_file_bytes : MAX_FILE_BYTES;
	long max_pixels = lim.max_pixels ? lim.max_pixels : MAX_PIXELS;
	int max_edge = lim.max_edge ? lim.max_edge : PREVIEW_EDGE;
	if (st.st_size > (long)max_file) return { .status = TOO_LARGE };
	if (st.st_size <= 0) return { .status = INVALID_IMAGE };
	usz size = (usz)st.st_size;
	char* bytes = libc::malloc(size);
	if (!bytes) return { .status = NO_MEMORY };
	defer libc::free(bytes);
	usz used;
	while (used < size)
	{
		sz n = libc::read(fd, bytes + used, size - used);
		if (n <= 0) return { .status = READ_ERROR };
		used += (usz)n;
	}
	int w, h, channels;
	if (!stbi_info_from_memory(bytes, (int)size, &w, &h, &channels) || w <= 0 || h <= 0) return { .status = INVALID_IMAGE };
	if (w > MAX_EDGE || h > MAX_EDGE || (long)w * h > max_pixels) return { .status = TOO_LARGE };
	// Explicit type avoids trusting filename case; raylib dispatches by extension.
	String ext = ".png";
	if (txt::iends_with(path, ".jpg") || txt::iends_with(path, ".jpeg")) { ext = ".jpg"; }
	else if (txt::iends_with(path, ".bmp")) { ext = ".bmp"; }
	else if (txt::iends_with(path, ".gif")) { ext = ".gif"; }
	char[8] kind;
	txt::set(&kind, ext);
	rl::RLImage pixels = rl::load_image_from_memory(txt::z(&kind), bytes, (int)size);
	if (!pixels.data) return { .status = INVALID_IMAGE };
	// One resize (on this thread) to the smallest of: max_edge, the fit box; never enlarged.
	int edge = w > h ? w : h;
	double k = edge > max_edge ? (double)max_edge / edge : 1;
	if (lim.fit_w > 0 && lim.fit_h > 0)
	{
		double kw = (double)lim.fit_w / w;
		double kh = (double)lim.fit_h / h;
		double kb = kw < kh ? kw : kh;
		if (kb < k) k = kb;
	}
	if (k < 1)
	{
		int pw = (int)(w * k + 0.5);
		int ph = (int)(h * k + 0.5);
		rl::image_resize(&pixels, pw > 0 ? pw : 1, ph > 0 ? ph : 1);
	}
	return { READY, pixels, w, h };
}

fn int work(void* arg) @private
{
	Loader* self = arg;
	while (true)
	{
		self.mutex.lock();
		while (!self.pending && !self.stopping) self.wake.wait(&self.mutex);
		if (self.stopping) { self.mutex.unlock(); return 0; }
		char[4096] path = self.path;
		Limits lim = self.limits;
		ulong generation = self.generation;
		self.pending = false;
		self.mutex.unlock();
		Result result = decode(txt::view(&path), lim);
		self.mutex.lock();
		if (generation == self.generation && !self.stopping)
		{
			self.result = result;
			self.available = true;
		}
		else if (result.pixels.data) { rl::unload_image(result.pixels); }
		self.mutex.unlock();
	}
}

fn bool Loader.request(&self, String path)
{
	self.cancel();
	if (!path.len || path.len >= self.path.len) return false;
	if (!self.started)
	{
		if (catch self.mutex.init()) return false;
		if (catch self.wake.init()) { self.mutex.destroy(); return false; }
		if (catch self.worker.create(&work, self))
		{
			self.wake.destroy(); self.mutex.destroy(); return false;
		}
		self.started = true;
	}
	self.mutex.lock();
	txt::set(&self.path, path);
	self.pending = true;
	self.wake.signal();
	self.mutex.unlock();
	return true;
}

fn void Loader.cancel(&self)
{
	if (!self.started) return;
	self.mutex.lock();
	self.generation++;
	self.pending = false;
	if (self.available && self.result.pixels.data) rl::unload_image(self.result.pixels);
	self.result = {};
	self.available = false;
	self.mutex.unlock();
}

// Transfers ownership of pixels; caller must unload_image exactly once.
fn bool Loader.take(&self, Result* out)
{
	if (!self.started) return false;
	self.mutex.lock();
	defer self.mutex.unlock();
	if (!self.available) return false;
	*out = self.result;
	self.result = {};
	self.available = false;
	return true;
}

fn void Loader.close(&self)
{
	if (!self.started) return;
	self.cancel();
	self.mutex.lock();
	self.stopping = true;
	self.wake.signal();
	self.mutex.unlock();
	self.worker.join()!!;
	self.wake.destroy();
	self.mutex.destroy();
	*self = {};
}
