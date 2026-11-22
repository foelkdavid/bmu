module gruvkit::txt;
import std::core::string;

// gruvkit::txt - fixed-size, NUL-terminated char buffers (`char[N]`) are the storage
// type for every editable string (ui::input edits them in place). These helpers
// bridge them with C3 Strings, plus case-insensitive compare and path helpers.
// Functions that build a String (join, zjoin) use temp memory: wrap in @pool().

fn String view(char[] b)
{
	usz n = 0;
	while (n < b.len && b[n] != 0) n++;
	return (String)b[:n];
}

fn ZString z(char[] b) => (ZString)b.ptr;

fn void set(char[] b, String s)
{
	if (b.len == 0) return;
	usz n = s.len < b.len - 1 ? s.len : b.len - 1;
	if (n > 0) mem::copy(b.ptr, s.ptr, (sz)n);
	b[n] = 0;
}

fn void append(char[] b, String s)
{
	usz cur = view(b).len;
	if (cur + 1 >= b.len) return;
	set(b[cur..], s);
}

fn bool empty(char[] b) => b.len == 0 || b[0] == 0;

fn char lower(char c) => c >= 'A' && c <= 'Z' ? c + 32 : c;

fn bool ieq(String a, String b)
{
	if (a.len != b.len) return false;
	for (usz i = 0; i < a.len; i++) if (lower(a[i]) != lower(b[i])) return false;
	return true;
}

fn bool icontains(String hay, String needle)
{
	if (needle.len == 0) return true;
	if (needle.len > hay.len) return false;
	for (usz i = 0; i + needle.len <= hay.len; i++)
	{
		if (ieq(hay[i:needle.len], needle)) return true;
	}
	return false;
}

fn bool iends_with(String s, String suffix) => s.len >= suffix.len && ieq(s[s.len - suffix.len..], suffix);
fn bool istarts_with(String s, String prefix) => s.len >= prefix.len && ieq(s[:prefix.len], prefix);

// Case-insensitive ordering, used for sorting names.
fn int icmp(String a, String b)
{
	usz n = a.len < b.len ? a.len : b.len;
	for (usz i = 0; i < n; i++)
	{
		char x = lower(a[i]);
		char y = lower(b[i]);
		if (x != y) return x < y ? -1 : 1;
	}
	if (a.len == b.len) return 0;
	return a.len < b.len ? -1 : 1;
}

// Last path component ("/a/b/c.exe" -> "c.exe").
fn String basename(String p)
{
	while (p.len > 1 && p[^1] == '/') p = p[:p.len - 1];
	sz? i = p.rindex_of_char('/');
	if (catch i) return p;
	return p[(usz)i + 1..];
}

// Everything before the last component ("/a/b/c.exe" -> "/a/b").
fn String dirname(String p)
{
	while (p.len > 1 && p[^1] == '/') p = p[:p.len - 1];
	sz? i = p.rindex_of_char('/');
	if (catch i) return ".";
	if (i == 0) return "/";
	return p[:(usz)i];
}

fn String strip_ext(String name)
{
	sz? i = name.rindex_of_char('.');
	if (catch i) return name;
	if (i == 0) return name;
	return name[:(usz)i];
}

// Join two path pieces into temp memory.
fn String join(String a, String b)
{
	if (a.len == 0) return b.tcopy();
	if (a[^1] == '/') return string::tformat("%s%s", a, b);
	return string::tformat("%s/%s", a, b);
}

fn ZString zjoin(String a, String b) => join(a, b).zstr_tcopy();

// Human readable "pretty" name from a folder or file name (extension dropped):
// "The_Elder_Scrolls_III:_Morrowind" -> "The Elder Scrolls III: Morrowind".
fn void pretty_name(char[] out, String raw)
{
	String s = strip_ext(raw);
	bool spaced = s.contains_char(' ') || s.contains_char('_');
	usz o = 0;
	for (usz i = 0; i < s.len && o + 2 < out.len; i++)
	{
		char c = s[i];
		// "BlackMythWukong" -> "Black Myth Wukong" (only for names without any spacing)
		if (!spaced && i > 0 && c >= 'A' && c <= 'Z' && s[i - 1] >= 'a' && s[i - 1] <= 'z') out[o++] = ' ';
		out[o++] = c == '_' ? ' ' : c;
	}
	out[o] = 0;
}

// Lowercase alphanumeric slug: "Empire Earth Gold" -> "empire-earth-gold".
// A name without any letter or digit gives `fallback`.
fn void slug(char[] out, String name, String fallback = "item")
{
	usz o = 0;
	bool dash = false;
	foreach (c : name)
	{
		if (o + 2 >= out.len) break;
		char l = lower(c);
		if ((l >= 'a' && l <= 'z') || (l >= '0' && l <= '9'))
		{
			if (dash && o > 0) out[o++] = '-';
			out[o++] = l;
			dash = false;
		}
		else
		{
			dash = true;
		}
	}
	if (o == 0) { set(out, fallback); return; }
	out[o] = 0;
}

// Natural ordering: "Proton 9.0" < "Proton 10.0".
fn int natcmp(String a, String b)
{
	usz i = 0;
	usz j = 0;
	while (i < a.len && j < b.len)
	{
		bool da = a[i] >= '0' && a[i] <= '9';
		bool db = b[j] >= '0' && b[j] <= '9';
		if (da && db)
		{
			ulong x = 0;
			ulong y = 0;
			while (i < a.len && a[i] >= '0' && a[i] <= '9') x = x * 10 + (ulong)(a[i++] - (char)48);
			while (j < b.len && b[j] >= '0' && b[j] <= '9') y = y * 10 + (ulong)(b[j++] - (char)48);
			if (x != y) return x < y ? -1 : 1;
			continue;
		}
		char x = lower(a[i++]);
		char y = lower(b[j++]);
		if (x != y) return x < y ? -1 : 1;
	}
	if (i < a.len) return 1;
	if (j < b.len) return -1;
	return 0;
}
