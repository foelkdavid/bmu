module bmu::audio @feat(LINUX);
import std::core::string;
import bmu::txt;

// bmu::audio - one full-duplex audio device: a real-time callback gets the input block and fills the output
// block (interleaved 32-bit float, same frame count). For loopers, recorders, synths, meters.
// Backend: miniaudio as bundled in raylib's static lib (raylib 6.0 = miniaudio 0.11.24, built by raudio.c with
// MA_NO_JACK and friends). raylib's own audio (InitAudioDevice) is not used and not needed.
// The opaque sizes and field offsets below are for exactly that build on Linux x86_64; bmu-check opens a device
// on miniaudio's null backend and checks rate, channels and the user pointer round trip.
// Docs: docs/API.md "Audio (bmu::audio)". No raylib calls, no window needed.

// Runs on the audio thread for every block: no allocation, no locks, no I/O, no @pool, no ui:: calls.
// `input` is null for an output-only device, `output` null for an input-only one. `output` arrives zeroed.
alias Process = fn void(void* user, float* output, float* input, uint frames);

const int MAX_DEVICES = 32;      // per direction; more are not listed

const usz CONTEXT_SIZE = 1024;   // sizeof(ma_context)
const usz DEVICE_SIZE = 3776;    // sizeof(ma_device)
const usz CONFIG_SIZE = 296;     // sizeof(ma_device_config)
const usz CTX_CONFIG_SIZE = 240; // sizeof(ma_context_config)
const usz INFO_SIZE = 1544;      // sizeof(ma_device_info); name at +256, isDefault at +512

const CInt TYPE_PLAYBACK = 1;
const CInt TYPE_CAPTURE = 2;
const CInt TYPE_DUPLEX = 3;
const CInt FORMAT_F32 = 5;
const CInt BACKEND_NULL = 14;

struct DeviceConfig @private { char[CONFIG_SIZE] raw; long align; }
struct ContextConfig @private { char[CTX_CONFIG_SIZE] raw; long align; }

extern fn DeviceConfig ma_device_config_init(CInt type) @cname("ma_device_config_init") @private;
extern fn CInt ma_context_init(CInt* backends, uint count, void* config, void* context) @cname("ma_context_init") @private;
extern fn CInt ma_context_uninit(void* context) @cname("ma_context_uninit") @private;
extern fn CInt ma_context_get_devices(void* context, void** playback, uint* playback_count, void** capture, uint* capture_count) @cname("ma_context_get_devices") @private;
extern fn CInt ma_device_init(void* context, void* config, void* device) @cname("ma_device_init") @private;
extern fn void ma_device_uninit(void* device) @cname("ma_device_uninit") @private;
extern fn CInt ma_device_start(void* device) @cname("ma_device_start") @private;
extern fn ZString ma_get_backend_name(CInt backend) @cname("ma_get_backend_name") @private;
extern fn ZString ma_result_description(CInt result) @cname("ma_result_description") @private;

macro @put(base, usz offset, $Type, value) @private => *($Type*)((char*)base + offset) = value;
macro @get(base, usz offset, $Type) @private => *($Type*)((char*)base + offset);

// Zero-initialize at a stable address (a global or heap): miniaudio keeps pointers into it. Never copy it.
struct Device
{
	char[CONTEXT_SIZE] context;
	long align1;
	char[DEVICE_SIZE] device;
	long align2;
	bool has_context;
	bool is_open;            // a device was opened and started
	Process process;
	void* user;
	int rate;                // actual sample rate after open (Hz)
	int in_channels;         // actual channels after open (0 = no input)
	int out_channels;        // actual channels after open (0 = no output)
	int period;              // requested frames per block (the backend may vary it)
	int input_count;         // capture devices listed by scan()
	int output_count;        // playback devices listed by scan()
	char* input_infos;       // ma_device_info arrays, owned by the context
	char* output_infos;
	char[64] app;            // shown by the sound server (PulseAudio/PipeWire mixers)
	char[64] backend;        // "PulseAudio", "ALSA", "Null"...
	char[256] error;         // last failure, readable text
}

<*
 Start the audio context (once) and list the devices. Blocking: a few ms to ~100 ms depending on the sound
 server. Call it before showing a device list, again to refresh. `app` names the streams in mixers.
 `offline` = miniaudio's null backend (no hardware, timer-paced callbacks): for tests.
*>
fn bool Device.scan(&self, String app = "", bool offline = false)
{
	if (!self.has_context)
	{
		txt::set(&self.app, app.len ? app : "bmu");
		ContextConfig cc;
		@put(&cc.raw, 80, ZString, txt::z(&self.app));      // pulse.pApplicationName
		CInt backend = BACKEND_NULL;
		CInt r = offline ? ma_context_init(&backend, 1, &cc.raw, &self.context) : ma_context_init(null, 0, &cc.raw, &self.context);
		if (r != 0) return self.fail("No audio system", r);
		self.has_context = true;
		txt::set(&self.backend, ma_get_backend_name(@get(&self.context, 104, CInt)).str_view());
	}
	void* outs;
	void* ins;
	uint out_n;
	uint in_n;
	CInt r = ma_context_get_devices(&self.context, &outs, &out_n, &ins, &in_n);
	if (r != 0) { self.input_count = 0; self.output_count = 0; return self.fail("Can't list audio devices", r); }
	self.output_infos = outs;
	self.input_infos = ins;
	self.output_count = out_n < MAX_DEVICES ? (int)out_n : MAX_DEVICES;
	self.input_count = in_n < MAX_DEVICES ? (int)in_n : MAX_DEVICES;
	return true;
}

// Name of a listed device (valid until the next scan or close); "" when out of range.
fn String Device.input_name(&self, int i) => i >= 0 && i < self.input_count ? ((ZString)(self.input_infos + (usz)i * INFO_SIZE + 256)).str_view() : "";
fn String Device.output_name(&self, int i) => i >= 0 && i < self.output_count ? ((ZString)(self.output_infos + (usz)i * INFO_SIZE + 256)).str_view() : "";
fn bool Device.input_default(&self, int i) => i >= 0 && i < self.input_count && @get(self.input_infos + (usz)i * INFO_SIZE, 512, uint) != 0;
fn bool Device.output_default(&self, int i) => i >= 0 && i < self.output_count && @get(self.output_infos + (usz)i * INFO_SIZE, 512, uint) != 0;

<*
 Open and start the device. `in_channels`/`out_channels` 0 = no input/output (at least one > 0).
 `input`/`output`: index from scan(), -1 = the system default. `rate` 0 = the device's own.
 `period`: frames per block (latency vs CPU; 256 at 48 kHz = 5.3 ms). Scans first if needed.
 False with `error` set when it fails; read `rate`, `in_channels`, `out_channels` after success.
 Reopening (other device or format) = close(), then open() again.
*>
fn bool Device.open(&self, Process process, void* user, int in_channels = 1, int out_channels = 2, int rate = 48000, int period = 256, int input = -1, int output = -1)
{
	if (self.is_open) self.stop();
	if (!self.has_context && !self.scan()) return false;
	if (in_channels <= 0 && out_channels <= 0) return self.fail("No channels", 0);
	CInt type = in_channels > 0 && out_channels > 0 ? TYPE_DUPLEX : (in_channels > 0 ? TYPE_CAPTURE : TYPE_PLAYBACK);
	DeviceConfig dc = ma_device_config_init(type);
	char* c = &dc.raw;
	@put(c, 4, uint, (uint)(rate > 0 ? rate : 0));                    // sampleRate
	@put(c, 8, uint, (uint)(period > 0 ? period : 0));                // periodSizeInFrames
	@put(c, 32, void*, (void*)&on_data);                              // dataCallback
	@put(c, 56, void*, (void*)self);                                  // pUserData
	if (out_channels > 0)
	{
		if (output >= 0 && output < self.output_count) @put(c, 112, void*, (void*)(self.output_infos + (usz)output * INFO_SIZE));
		@put(c, 120, CInt, FORMAT_F32);
		@put(c, 124, uint, (uint)out_channels);
	}
	if (in_channels > 0)
	{
		if (input >= 0 && input < self.input_count) @put(c, 152, void*, (void*)(self.input_infos + (usz)input * INFO_SIZE));
		@put(c, 160, CInt, FORMAT_F32);
		@put(c, 164, uint, (uint)in_channels);
	}
	@put(c, 224, ZString, txt::z(&self.app));                         // pulse stream names
	@put(c, 232, ZString, txt::z(&self.app));
	self.process = process;
	self.user = user;
	self.period = period;
	CInt r = ma_device_init(&self.context, c, &self.device);
	if (r != 0) return self.fail("Can't open the audio device", r);
	self.rate = (int)@get(&self.device, 12, uint);
	self.out_channels = out_channels > 0 ? (int)@get(&self.device, 1120, uint) : 0;
	self.in_channels = in_channels > 0 ? (int)@get(&self.device, 2552, uint) : 0;
	r = ma_device_start(&self.device);
	if (r != 0) { ma_device_uninit(&self.device); return self.fail("Can't start the audio device", r); }
	self.is_open = true;
	txt::set(&self.error, "");
	return true;
}

// Stop and release the device (blocks until the callback has returned for good); the context stays.
fn void Device.stop(&self)
{
	if (!self.is_open) return;
	ma_device_uninit(&self.device);
	self.is_open = false;
}

// Stop the device and release the context; idempotent. The Device can be scanned/opened again.
fn void Device.close(&self)
{
	self.stop();
	if (self.has_context) ma_context_uninit(&self.context);
	self.has_context = false;
	self.input_count = 0;
	self.output_count = 0;
}

fn bool Device.fail(&self, String what, CInt r) => @pool()
{
	txt::set(&self.error, r ? string::tformat("%s: %s", what, ma_result_description(r)) : what);
	return false;
}

fn void on_data(void* device, void* output, void* input, uint frames) @private
{
	Device* d = @get(device, 48, Device*);                     // ma_device.pUserData
	d.process(d.user, (float*)output, (float*)input, frames);
}
