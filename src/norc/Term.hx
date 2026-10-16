package norc;

using StringTools;

/**
	Terminal input/output helpers.
**/
class Term {
	public static var colors = true;

	/** All output to stderr, e.g. while stdout carries the API (`--stdin`) **/
	public static var stderrOnly = false;

	/** No output at all (`--silent`) **/
	public static var silent = false;

	/** The line editor reading input (`-i` on a terminal): output is printed above its input line **/
	public static var editor:Null<LineEditor>;

	/**
		Shows a PNG image `rows` lines high (the width by its aspect ratio) above the input line, if the terminal shows
		images (kitty graphics protocol, see `LineEditor.images`); returns `false` if it doesn't, or `png` is no PNG.
	**/
	public static function image(png:haxe.io.Bytes, rows:Int):Bool {
		final e = editor;
		if (e == null || !e.images || silent || rows < 1 || png.length < 8 || png.get(0) != 0x89 || png.getString(1, 3) != "PNG")
			return false;
		final data = haxe.crypto.Base64.encode(png);
		final b = new StringBuf();
		// the lines of the image first (scrolling at the bottom of the screen), then the image at their start; the
		// cursor stays (C=1), no answers (q=2), the data in chunks of 4096 bytes
		b.add(StringTools.lpad("", "\n", rows - 1));
		if (rows > 1)
			b.add('\x1B[${rows - 1}A');
		b.add("\r");
		var i = 0;
		while (i < data.length) {
			final chunk = data.substr(i, 4096);
			i += 4096;
			final more = (i < data.length) ? 1 : 0;
			b.add((i == 4096) ? '\x1B_Ga=T,f=100,t=d,r=$rows,C=1,q=2,m=$more;$chunk\x1B\\' : '\x1B_Gm=$more;$chunk\x1B\\');
		}
		if (rows > 1)
			b.add('\x1B[${rows - 1}B');
		e.print(b.toString());
		return true;
	}

	/** The file of the avatar of a jid (PNG), `null` if there is none; set by the client **/
	public static var avatarPath:Null<String->Null<String>>;

	/** Small avatars in the terminal: in prompts (`{avatar}`) and before the names of contacts (`inline_avatars`) **/
	public static var inlineAvatars = false;

	/** The ids of the images sent to the terminal, by file **/
	static final imageIds = new Map<String, Int>();

	/** The next id of an image (low ids: other uses, e.g. 31 of the query) **/
	static var nextImageId = 100;

	/** The image of each fixed placement (e.g. of the prompt) **/
	static final placements = new Map<Int, Int>();

	/**
		The avatar of `jid` as a small image (2 columns, 1 line) and a space after it, in terminals showing images and
		with `inline_avatars = 1`; `""` without. The image is sent to the terminal once, then only placed. With `placement` (a fixed id, e.g. for
		the prompt drawn again and again) it is moved instead of placed again, the placement of another image is deleted.
	**/
	public static function avatarIcon(jid:Null<String>, ?placement:Int):String {
		final e = editor;
		final original = (inlineAvatars && jid != null && e != null && e.images && !silent && avatarPath != null) ? avatarPath(jid) : null;
		if (original == null || !StringTools.endsWith(original, ".png"))
			return "";
		// exactly sized, 1 pixel free around it (with ImageMagick and the cell size), else filling the two cells
		final cell = e.cellSize;
		final fitted = (cell != null) ? fittedAvatar(original, cell) : null;
		final path = fitted?.path ?? original;
		var id = imageIds.get(path);
		if (id == null) {
			final data = try sys.io.File.getBytes(path) catch (_) null;
			if (data == null)
				return "";
			id = nextImageId++;
			final b = new StringBuf();
			final encoded = haxe.crypto.Base64.encode(data);
			var i = 0;
			while (i < encoded.length) {
				final chunk = encoded.substr(i, 4096);
				i += 4096;
				final more = (i < encoded.length) ? 1 : 0;
				b.add((i == 4096) ? '\x1B_Ga=t,f=100,i=$id,q=2,m=$more;$chunk\x1B\\' : '\x1B_Gm=$more;$chunk\x1B\\');
			}
			e.writeRaw(b.toString());
			imageIds.set(path, id);
		}
		if (placement != null) {
			// once: the placement of another image (e.g. of the previous chat)
			final old = placements.get(placement);
			if (old != null && old != id)
				e.writeRaw(deletion(old, placement));
			placements.set(placement, id);
		}
		final size = (fitted != null) ? ',X=${fitted.x},Y=${fitted.y}' : ',c=2,r=1';
		return '\x1B_Ga=p,i=$id' + ((placement != null) ? ',p=$placement' : '') + size + ',C=1,q=2\x1B\\' + "   ";
	}

	/** Scaled avatars by file and size: their file and horizontal offset, `null` if they can't be made **/
	static final fitted = new Map<String, Null<{path:String, x:Int, y:Int}>>();

	/**
		A copy of the avatar `path` scaled to the box of 2 cells (`cell`) minus a pixel on each side: square, as large as
		the smaller side allows, centered (the offsets `x`, `y` in pixels); made once with ImageMagick, `null` without it.
	**/
	static function fittedAvatar(path:String, cell:{width:Int, height:Int}):Null<{path:String, x:Int, y:Int}> {
		final side = Std.int(Math.min(cell.width * 2, cell.height)) - 2;
		final key = '$path $side';
		if (fitted.exists(key))
			return fitted.get(key);
		var result:Null<{path:String, x:Int, y:Int}> = null;
		final magick = Files.which("magick");
		if (side > 0 && magick != null) {
			final out = haxe.io.Path.withoutExtension(path) + '-$side.png';
			if (sys.FileSystem.exists(out) || Sys.command(magick, [path, "-resize", '${side}x$side!', 'png:$out']) == 0)
				result = {path: out, x: 1 + Std.int((cell.width * 2 - 2 - side) / 2), y: 1 + Std.int((cell.height - 2 - side) / 2)};
		}
		fitted.set(key, result);
		return result;
	}

	/** Removes the image of a fixed placement (see `avatarIcon`), e.g. when the prompt has none anymore **/
	public static function clearPlacement(placement:Int) {
		final id = placements.get(placement);
		if (id == null)
			return;
		placements.remove(placement);
		editor?.writeRaw(deletion(id, placement));
	}

	static function deletion(id:Int, placement:Int):String
		return '\x1B_Ga=d,d=i,i=$id,p=$placement,q=2\x1B\\';

	/** The avatar of a contact before its name (`avatarIcon`) **/
	public static inline function avatarBefore(jid:Null<String>):String
		return avatarIcon(jid);

	/** Prints a line (to stderr if `error`), above the input line while the editor is active **/
	public static function println(text:String, error = false):Null<LineEditor.Position> {
		if (silent)
			return null;
		final e = editor;
		if (e != null)
			return e.print(text, error);
		if (error || stderrOnly)
			Sys.stderr().writeString(text + "\n");
		else
			Sys.println(text);
		return null;
	}

	/**
		Writes `text` at the end of a line printed before (`pos`, of `println`) if it is still on the screen; `false` if
		it isn't, or there is no input line (output may go to a file).
	**/
	public static function mark(pos:Null<LineEditor.Position>, text:String):Bool
		return editor?.mark(pos, text) ?? false;

	/**
		The columns `s` takes on the terminal: escape sequences none, combining characters none, wide characters (CJK,
		emoji) two.
	**/
	public static function displayWidth(s:String):Int {
		final plain = ~/\x1B(\[[0-9;?]*[ -\/]*[@-~]|_[^\x1B]*\x1B\\|\][^\x07\x1B]*(\x07|\x1B\\)|[78])/g.replace(s, "");
		var width = 0;
		for (c in new haxe.iterators.StringIteratorUnicode(plain)) {
			if (c < 32 || (c >= 0x300 && c <= 0x36F) || c == 0x200D || (c >= 0xFE00 && c <= 0xFE0F))
				continue;
			width += (c >= 0x1100 && c <= 0x115F) || (c >= 0x2E80 && c <= 0xA4CF) || (c >= 0xAC00 && c <= 0xD7A3)
				|| (c >= 0xF900 && c <= 0xFAFF) || (c >= 0xFE30 && c <= 0xFE4F) || (c >= 0xFF00 && c <= 0xFF60)
				|| (c >= 0xFFE0 && c <= 0xFFE6) || (c >= 0x1F300 && c <= 0x1FAFF) || (c >= 0x20000 && c <= 0x3FFFD) ? 2 : 1;
		}
		return width;
	}

	public static function error(msg:String)
		println(style(msg, 31), true);

	public static function info(msg:String)
		println(style(msg, 2));

	/** A notification of an event (e.g. a presence change) with its time: `12:03:41 alice is away` **/
	public static function notice(msg:String, code = 2)
		println(timestamp(Date.now()) + ' ' + style(msg, code));

	/** The condition and text of a stanza error, e.g. `remote-server-timeout: Server-to-server connection failed` **/
	public static function errorText(e:Null<xmpp.Stanza.Error>):String
		return (e == null) ? "error" : [(e.condition : Null<String>), e.text].filter(v -> v != null && v.length > 0).join(": ");

	/** e.g. `512 B`, `1.5 MB` **/
	public static function size(bytes:Float):String {
		final units = ["B", "KB", "MB", "GB"];
		var i = 0;
		while (bytes >= 1024 && i < units.length - 1) {
			bytes /= 1024;
			i++;
		}
		return '${i == 0 ? Std.int(bytes) : Math.round(bytes * 10) / 10} ${units[i]}';
	}

	/** Time of an event: `12:03:41` today, else `2026-10-13 12:03:41` **/
	public static function timestamp(date:Date):String {
		final now = Date.now();
		final today = date.getFullYear() == now.getFullYear() && date.getMonth() == now.getMonth() && date.getDate() == now.getDate();
		return DateTools.format(date, today ? "%H:%M:%S" : "%Y-%m-%d %H:%M:%S");
	}

	/** Colors of names, distinct from red (errors) **/
	static final NAME_COLORS = [32, 33, 34, 35, 36, 92, 93, 94, 95, 96];

	/**
		`name` in the color of `jid` (bare): each contact gets one of the name colors, always the same.
		Without `jid`: the own name (bold, in no name color).
	**/
	public static function name(name:String, ?jid:String):String {
		if (jid == null)
			return style(name, 1);
		var hash = 0;
		for (i in 0...jid.length)
			hash = (hash * 31 + StringTools.fastCodeAt(jid, i)) & 0xFFFFFF;
		return style(name, NAME_COLORS[hash % NAME_COLORS.length]);
	}

	public static function style(str:String, code:Int):String
		return colors ? '\x1B[${code}m$str\x1B[0m' : str;

	/**
		Reads a line from stdin, `null` at the end of input.
	**/
	public static function readLine(prompt:String):Null<String> {
		Sys.stderr().writeString(prompt);
		Sys.stderr().flush();
		return try Sys.stdin().readLine() catch (_:haxe.io.Eof) null;
	}

	/**
		Asks a yes/no question, `false` unless answered with `y` or `yes`.
	**/
	public static function confirm(question:String):Bool {
		final answer = readLine('$question [y/N] ');
		return answer != null && ["y", "yes"].contains(answer.trim().toLowerCase());
	}

	/**
		Reads a password from the terminal without echoing it.
	**/
	public static function readPassword(prompt:String):String {
		Sys.stderr().writeString(prompt);
		Sys.stderr().flush();
		final windows = Sys.systemName() == "Windows";
		// Read key by key: the terminal is in raw mode (Unix) or reads unbuffered (Windows) without echo
		final bytes = new Array<Int>();
		while (true) {
			final c = Sys.getChar(false);
			switch c {
				case -1, 4, 10, 13: // eof, ctrl-d, enter
					break;
				case 3: // ctrl-c (no signal in raw mode)
					Sys.stderr().writeString("\n");
					throw "cancelled";
				case 8, 127: // backspace: remove the last character, including its UTF-8 continuation bytes
					while (bytes.length > 0)
						if (bytes.pop() & 0xC0 != 0x80)
							break;
				case 0, 224 if (windows): // function and arrow keys are followed by a second code
					Sys.getChar(false);
				case _:
					bytes.push(c);
			}
		}
		Sys.stderr().writeString("\n");
		final b = haxe.io.Bytes.alloc(bytes.length);
		for (i in 0...bytes.length)
			b.set(i, bytes[i]);
		return b.getString(0, b.length, UTF8);
	}

	/**
		Runs `cmd` with the shell (`cmd` on Windows) and returns the first line of its output.
	**/
	public static function readCommand(cmd:String):String {
		final out = Sys.systemName() == "Windows" ? output("cmd", ["/c", cmd]) : output("sh", ["-c", cmd]);
		if (out == null)
			throw 'command failed: $cmd';
		final line = out.split("\n")[0];
		return line.endsWith("\r") ? line.substr(0, line.length - 1) : line;
	}

	/**
		Whether stdin is a terminal and norc runs in its foreground: reading it (or changing its mode) in the
		background would stop norc (`norc &`). On Windows: whether there is a console.
	**/
	public static function isForegroundTerminal():Bool {
		if (Sys.systemName() == "Windows")
			return true;
		if (Sys.command("test -t 0") != 0)
			return false;
		// the process group of norc is the foreground group of the terminal
		final groups = output("ps", ["-o", "pgid=,tpgid=", "-p", Std.string(pid())]);
		final ids = (groups != null) ? [for (w in ~/\s+/g.split(StringTools.trim(groups))) Std.parseInt(w)] : [];
		return ids.length != 2 || ids[0] == null || ids[0] == ids[1];
	}

	@:hlNative("std", "sys_getpid")
	static function pid():Int
		return 0;

	/** Runs a program and returns its output, `null` if it can't be started or fails (exit code) **/
	public static function output(cmd:String, args:Array<String>):Null<String> {
		return try {
			final proc = new sys.io.Process(cmd, args);
			final out = proc.stdout.readAll().toString();
			final code = proc.exitCode();
			proc.close();
			(code == 0) ? out : null;
		} catch (_)
			null;
	}
}
