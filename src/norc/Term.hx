package norc;

using StringTools;

/**
	Terminal input/output helpers.
**/
class Term {
	public static var colors = true;

	/** All output to stderr, e.g. while stdout carries the API (`--stdin`) **/
	public static var stderrOnly = false;

	/** The line editor reading input (`-i` on a terminal): output is printed above its input line **/
	public static var editor:Null<LineEditor>;

	/** Prints a line (to stderr if `error`), above the input line while the editor is active **/
	public static function println(text:String, error = false) {
		final e = editor;
		if (e != null)
			e.print(text, error);
		else if (error || stderrOnly)
			Sys.stderr().writeString(text + "\n");
		else
			Sys.println(text);
	}

	public static function error(msg:String)
		println(style(msg, 31), true);

	public static function info(msg:String)
		println(style(msg, 2));

	/** A notification of an event (e.g. a presence change) with its time: `12:03 alice is away` **/
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

	/** Time of an event: `12:03` today, else `2026-10-13 12:03` **/
	public static function timestamp(date:Date):String {
		final now = Date.now();
		final today = date.getFullYear() == now.getFullYear() && date.getMonth() == now.getMonth() && date.getDate() == now.getDate();
		return DateTools.format(date, today ? "%H:%M" : "%Y-%m-%d %H:%M");
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
