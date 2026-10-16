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
