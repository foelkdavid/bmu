module bmu::tests;
import std::atomic, std::core::string, libc;
import bmu::audio, bmu::sys, bmu::txt;

// bmu::audio on miniaudio's null backend (no hardware): the opaque layout must round-trip the user pointer,
// rate and channels, and blocks must arrive with both buffers.
struct AudioProbe
{
	Atomic{int} blocks;
	Atomic{int} frames;
	bool both_buffers;
	bool zeroed_output;
	float* first_out;
}

audio::Device probe_dev;
AudioProbe probe;

fn void probe_process(void* user, float* output, float* input, uint frames)
{
	AudioProbe* p = user;
	if (p.blocks.load() == 0)
	{
		p.both_buffers = output != null && input != null;
		p.zeroed_output = output != null && output[0] == 0 && output[frames * 2 - 1] == 0;
	}
	for (uint i = 0; i < frames * 2; i++) output[i] = 0.25f;
	p.frames.add((int)frames);
	p.blocks.add(1);
}

fn void check_audio() => @pool()
{
	expect(probe_dev.scan("bmu-check", offline: true), "audio: null backend context");
	expect_str(txt::view(&probe_dev.backend), "Null", "audio: backend name (ma_context.backend offset)");
	expect(probe_dev.output_count >= 1 && probe_dev.input_count >= 1, "audio: null backend lists devices");
	expect(probe_dev.output_name(0).len > 0 && probe_dev.output_name(99) == "", "audio: device names");
	bool opened = probe_dev.open(&probe_process, &probe, in_channels: 1, out_channels: 2, rate: 44100, period: 128);
	expect(opened, string::tformat("audio: open duplex (%s)", txt::view(&probe_dev.error)));
	expect(probe_dev.rate == 44100, string::tformat("audio: rate read back (%d)", probe_dev.rate));
	expect(probe_dev.in_channels == 1 && probe_dev.out_channels == 2, "audio: channels read back");
	for (int i = 0; i < 200 && probe.blocks.load() < 3; i++) sys::c_usleep(5000);
	probe_dev.stop();
	expect(probe.blocks.load() >= 3, "audio: callback runs with the user pointer");
	expect(probe.both_buffers, "audio: duplex gets input and output");
	expect(probe.zeroed_output, "audio: output arrives zeroed");
	expect(probe.frames.load() > 0, "audio: frames delivered");
	int before = probe.blocks.load();
	sys::c_usleep(30000);
	expect(probe.blocks.load() == before, "audio: stop ends callbacks");
	expect(!probe_dev.open(&probe_process, &probe, in_channels: 0, out_channels: 0), "audio: no channels fails");
	expect(txt::view(&probe_dev.error).len > 0, "audio: error text");
	probe_dev.close();
	probe_dev.close();
	expect(!probe_dev.has_context, "audio: close is idempotent");
}
