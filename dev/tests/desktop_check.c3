module bmu::tests;
import std::core::string, libc;
import bmu::desktop, bmu::txt, bmu::sys;

fn desktop::HandlerStatus handler_result(desktop::DefaultHandler* h)
{
	desktop::HandlerStatus result;
	for (int i = 0; i < 700; i++)
	{
		h.poll(&result);
		if (!result.busy) return result;
		sys::c_usleep(10000);
	}
	expect(false, "desktop: worker completes within deadline");
	h.close();
	return result;
}

fn void check_desktop() => @pool()
{
	String root = string::tformat("/tmp/bmu-desktop-check-%d", sys::now());
	String old_path = sys::env("PATH").tcopy();
	String old_config = sys::env("XDG_CONFIG_HOME").tcopy();
	sys::mkdirs(root);
	String script = txt::join(root, "xdg-mime");
	String state = txt::join(root, "default");
	sys::write_file(script, string::tformat("#!/bin/sh\ncase \"$3\" in application/fail) exit 1;; application/slow) exec /bin/sleep 20;; application/override) printf 'other.desktop\\n'; exit 0;; application/empty) exit 0;; esac\nif [ \"$1\" = default ]; then printf '%%s' \"$2\" > '%s'; else if [ -f '%s' ]; then read -r value < '%s'; printf '%%s\\n' \"$value\"; else printf 'other.desktop\\n'; fi; fi\n", state, state, state));
	libc::system(string::tformat("/bin/chmod 755 '%s'", script).zstr_tcopy());
	libc::setenv("PATH", root.zstr_tcopy(), 1);
	libc::setenv("XDG_CONFIG_HOME", root.zstr_tcopy(), 1);
	defer
	{
		libc::setenv("PATH", old_path.zstr_tcopy(), 1);
		if (old_config.len) { libc::setenv("XDG_CONFIG_HOME", old_config.zstr_tcopy(), 1); } else { libc::unsetenv("XDG_CONFIG_HOME"); }
		libc::system(string::tformat("/bin/rm -rf '%s'", root).zstr_tcopy());
	}
	desktop::DefaultHandler h;
	defer h.close();
	expect(!h.request("", "viewer.desktop"), "desktop: empty mime refused");
	expect(h.request("application/test", "viewer.desktop"), "desktop: query starts");
	desktop::HandlerStatus result = handler_result(&h);
	expect(!result.busy && !result.is_default && !txt::view(&result.error).len, "desktop: other handler is not an error");
	expect_str(txt::view(&result.current), "other.desktop", "desktop: current handler returned");
	expect(!sys::exists(state), "desktop: querying does not change default");
	expect(h.request("application/test", "viewer.desktop", true), "desktop: set starts");
	result = handler_result(&h);
	expect(result.is_default && !txt::view(&result.error).len, "desktop: set verified with fresh query");
	expect(h.request("application/fail", "viewer.desktop"), "desktop: failed query starts");
	result = handler_result(&h);
	expect(!result.is_default && txt::view(&result.error).len > 0, "desktop: nonzero exit reported");
	expect(h.request("application/override", "viewer.desktop", true), "desktop: override request starts");
	result = handler_result(&h);
	expect(!result.is_default && txt::view(&result.error).len > 0, "desktop: successful set with ineffective default reported");
	expect(h.request("application/empty", "viewer.desktop"), "desktop: unconfigured query starts");
	result = handler_result(&h);
	expect(!result.is_default && txt::empty(&result.current) && txt::empty(&result.error), "desktop: no configured default is valid");
	expect(h.request("application/slow", "viewer.desktop"), "desktop: timeout query starts");
	result = handler_result(&h);
	expect(!result.busy && !txt::empty(&result.error), "desktop: hung command times out");
	expect(h.request("application/slow", "viewer.desktop"), "desktop: slow query starts");
	expect(!h.request("application/test", "viewer.desktop", true), "desktop: overlapping request refused");
	sys::c_usleep(30000);
	h.close();
	expect(!h.started, "desktop: cancellation joins worker");
	libc::system(string::tformat("/bin/rm '%s'", script).zstr_tcopy());
	expect(h.request("application/test", "viewer.desktop"), "desktop: missing tool request starts");
	result = handler_result(&h);
	expect(txt::view(&result.error).len > 0, "desktop: missing xdg-utils reported");
}
