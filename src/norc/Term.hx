package norc;

using StringTools;

/**
	Terminal input/output helpers.
**/
class Term {
	public static var colors = true;

	public static function error(msg:String)
		Sys.stderr().writeString(style(msg, 31) + "\n");

	public static function info(msg:String)
		Sys.println(style(msg, 2));

	public static function style(str:String, code:Int):String
		return colors ? '\x1B[${code}m$str\x1B[0m' : str;

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
		final proc = Sys.systemName() == "Windows" ? new sys.io.Process("cmd", ["/c", cmd]) : new sys.io.Process("sh", ["-c", cmd]);
		final out = proc.stdout.readAll().toString();
		final code = proc.exitCode();
		proc.close();
		if (code != 0)
			throw 'command failed ($code): $cmd';
		final line = out.split("\n")[0];
		return line.endsWith("\r") ? line.substr(0, line.length - 1) : line;
	}
}
