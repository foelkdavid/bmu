module bmu::desktop @feat(LINUX);
import std::thread, std::os::process;
import bmu::sys, bmu::txt;

// Desktop integration is opt-in and lazy: no process until request(). Keep at a stable address.
struct HandlerStatus
{
	bool busy;
	bool is_default;
	char[256] current;
	char[256] error;
}

struct DefaultHandler
{
	thread::Mutex mutex;
	thread::Thread worker;
	bool started;
	bool done;
	bool cancel;
	bool change;
	char[256] mime;
	char[256] desktop;
	HandlerStatus result;
}

<* Query the default for mime, or set desktop as default then verify by querying. False if busy,
   invalid arguments, or the worker cannot start. No shell; xdg-mime is found on PATH. *>
fn bool DefaultHandler.request(&self, String mime, String desktop, bool make_default = false)
{
	if (self.started || !mime.len || mime.len >= self.mime.len || !desktop.len || desktop.len >= self.desktop.len || mime.starts_with("-") || desktop.starts_with("-")) return false;
	if (catch self.mutex.init()) return false;
	txt::set(&self.mime, mime);
	txt::set(&self.desktop, desktop);
	self.change = make_default;
	self.done = false;
	self.cancel = false;
	self.result = { .busy = true };
	if (catch self.worker.create(&handler_work, self))
	{
		self.mutex.destroy();
		self.result = {};
		txt::set(&self.result.error, "Could not start desktop integration worker");
		return false;
	}
	self.started = true;
	return true;
}

<* Copy cached status (one lock while running). Reaps a completed worker without waiting for I/O. *>
fn void DefaultHandler.poll(&self, HandlerStatus* out)
{
	if (!self.started) { *out = self.result; return; }
	self.mutex.lock();
	*out = self.result;
	bool done = self.done;
	self.mutex.unlock();
	if (!done) return;
	self.worker.join()!!;
	self.mutex.destroy();
	self.started = false;
}

<* Cancel a running query/update, kill its command, join and release the worker. *>
fn void DefaultHandler.close(&self)
{
	if (!self.started) return;
	self.mutex.lock();
	self.cancel = true;
	self.mutex.unlock();
	self.worker.join()!!;
	self.mutex.destroy();
	self.started = false;
	self.result.busy = false;
}

fn bool handler_cancelled(DefaultHandler* h) @private
{
	h.mutex.lock();
	bool cancel = h.cancel;
	h.mutex.unlock();
	return cancel;
}

// Drain bounded output while waiting, with a five-second deadline per command. Never called on UI thread.
fn bool handler_command(DefaultHandler* h, String[] argv, char[] output, char[] error) @private
{
	process::Process p;
	if (try child = process::spawn(argv, process::SpawnOptions.INHERIT_ENV | process::SpawnOptions.ASYNC_OUTPUT)) { p = child; }
	else { txt::set(error, "Cannot run xdg-mime (install xdg-utils)"); return false; }
	defer (void)p.destroy();
	usz used;
	bool overflow;
	for (int tick = 0; ; tick++)
	{
		char[512] buf;
		sz n = p.read_stdout(&buf, buf.len) ?? 0;
		if (n > 0)
		{
			usz count = (usz)n;
			if (used + count >= output.len) { overflow = true; }
			else { output[used:count] = buf[:count]; used += count; output[used] = 0; }
		}
		// stderr is deliberately discarded: never expose arbitrary command output as UI text.
		(void)(p.read_stderr(&buf, buf.len) ?? 0);
		int status;
		int waited = sys::c_waitpid(p.child, &status, sys::WNOHANG);
		if (waited != 0)
		{
			p.child = 0;
			if (waited < 0 || status != 0) { txt::set(error, "xdg-mime failed; check your desktop configuration"); return false; }
			// One final read catches output written immediately before exit.
			n = p.read_stdout(&buf, buf.len) ?? 0;
			if (n > 0)
			{
				usz count = (usz)n;
				if (used + count >= output.len) { overflow = true; }
				else { output[used:count] = buf[:count]; used += count; output[used] = 0; }
			}
			if (overflow) { txt::set(error, "xdg-mime returned an oversized response"); return false; }
			while (used && (output[used - 1] == '\n' || output[used - 1] == '\r')) output[--used] = 0;
			return true;
		}
		if (tick >= 500 || handler_cancelled(h))
		{
			if (catch p.terminate()) {}
			(void)(p.join() ?? -1);
			txt::set(error, "Desktop integration timed out or was cancelled");
			return false;
		}
		sys::c_usleep(10000);
	}
}

fn int handler_work(void* arg) @private
{
	DefaultHandler* h = (DefaultHandler*)arg;
	HandlerStatus result;
	char[256] ignored;
	bool ok = true;
	if (h.change) ok = handler_command(h, { "xdg-mime", "default", txt::view(&h.desktop), txt::view(&h.mime) }, &ignored, &result.error);
	if (ok) ok = handler_command(h, { "xdg-mime", "query", "default", txt::view(&h.mime) }, &result.current, &result.error);
	if (ok)
	{
		result.is_default = txt::view(&result.current) == txt::view(&h.desktop);
		if (h.change && !result.is_default) txt::set(&result.error, "Default did not change; another desktop setting may override it");
	}
	h.mutex.lock();
	h.result = result;
	h.done = true;
	h.mutex.unlock();
	return 0;
}
