module bmu::places;
import std::io, std::core::string;
import bmu::sys, bmu::txt;

// bmu::places - the sidebar shared by every bmu app: one small file, $XDG_CONFIG_HOME/bmu/places
// (fallback ~/.config/bmu/places). Only a file manager writes it; bmu::picker reads it and shows the same
// sidebar. Without the file everyone shows the defaults: Home, Downloads, File system, Trash.
//   places::load();                          // once at startup (picker::start() reloads it itself)
//   places::add("/data/photos");             // saves at once, other apps see it on their next load
//   if (places::downloads) ...               // pinned Downloads entry shown (default true)
// Lines: `downloads=0|1`, `trash=0|1`, `place=/absolute/path`. Unknown lines are dropped on save.

const int MAX = 32;
const int PATH_MAX = 4096;
const int FILE_MAX = MAX * (PATH_MAX + 8) + 64;

struct Place
{
	char[PATH_MAX] path;
}
Place[MAX] list;
int count;
bool downloads = true;      // show the pinned Downloads entry
bool trash = true;          // show the Trash entry
char[1024] file;            // full path of the places file (set by load)

<* The places file path (temp). *>
fn String file_path()
{
	String base = sys::env("XDG_CONFIG_HOME");
	if (!base.starts_with("/")) base = txt::join(sys::home(), ".config");
	return txt::join(base, "bmu/places").tcopy();
}

<* ~/Downloads (temp). *>
fn String downloads_path() => txt::join(sys::home(), "Downloads");

<* The home trash's files folder: $XDG_DATA_HOME/Trash/files, fallback ~/.local/share/Trash/files (temp). *>
fn String trash_path()
{
	String data = sys::env("XDG_DATA_HOME");
	if (!data.starts_with("/")) data = txt::join(sys::home(), ".local/share");
	return txt::join(data, "Trash/files");
}

<* Read the file (bounded). Returns false when it does not exist or cannot be read; the list is then empty and
   `downloads` is true. Call on startup or when a picker opens, never per frame. *>
fn bool load() => @pool()
{
	count = 0;
	downloads = true;
	trash = true;
	String f = file_path();
	if (f.len >= file.len) return false;
	txt::set(&file, f);
	File? h = file::open(f, "rb");
	if (catch h) return false;
	defer (void)h.close();
	long? size = h.size();
	if (catch size) return false;
	if (size < 0 || size > FILE_MAX) return false;
	char[] data = mem::talloc_array(char, (usz)size);
	sz? got = h.read(data);
	if (catch got) return false;
	foreach (line : ((String)data[:(usz)got]).tsplit("\n"))
	{
		if (line.starts_with("downloads=")) downloads = line != "downloads=0";
		if (line.starts_with("trash=")) trash = line != "trash=0";
		if (line.starts_with("place=/") && count < MAX && line.len - 6 < PATH_MAX) txt::set(&list[count++].path, line[6..]);
	}
	return true;
}

<* Write the file atomically (temp file + rename). False when it cannot be written. *>
fn bool save() => @pool()
{
	String f = txt::empty(&file) ? file_path() : txt::view(&file);
	if (!sys::mkdirs(txt::dirname(f))) return false;
	DString s;
	s.tinit();
	s.appendf("downloads=%d\ntrash=%d\n", downloads ? 1 : 0, trash ? 1 : 0);
	for (int i = 0; i < count; i++) s.appendf("place=%s\n", txt::view(&list[i].path));
	String tmp = string::tformat("%s.tmp", f);
	if (!sys::write_file(tmp, s.str_view())) return false;
	return sys::move(tmp, f);
}

fn String path(int i) => txt::view(&list[i].path);

<* Append an absolute path (no newlines, < PATH_MAX bytes) and save. True when it is in the list afterwards
   (already present counts); false when full or invalid. *>
fn bool add(String p)
{
	if (!p.starts_with("/") || p.len >= PATH_MAX) return false;
	foreach (c : p) if (c == '\n' || c == '\r') return false;
	for (int i = 0; i < count; i++) if (path(i) == p) return true;
	if (count == MAX) return false;
	txt::set(&list[count++].path, p);
	save();
	return true;
}

<* Remove entry `i` and save. *>
fn void remove(int i)
{
	if (i < 0 || i >= count) return;
	for (int j = i; j + 1 < count; j++) list[j] = list[j + 1];
	count--;
	save();
}

<* Show or hide the pinned Downloads entry and save. *>
fn void set_downloads(bool on)
{
	downloads = on;
	save();
}

<* Show or hide the Trash entry and save. *>
fn void set_trash(bool on)
{
	trash = on;
	save();
}
