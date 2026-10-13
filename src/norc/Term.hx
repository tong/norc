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
		final echoOff = Sys.command("stty -echo 2>/dev/null") == 0;
		final password = try Sys.stdin().readLine() catch (_:haxe.io.Eof) "";
		if (echoOff) {
			Sys.command("stty echo 2>/dev/null");
			Sys.stderr().writeString("\n");
		}
		return password;
	}

	/**
		Runs `cmd` with the shell and returns the first line of its output.
	**/
	public static function readCommand(cmd:String):String {
		final proc = new sys.io.Process("sh", ["-c", cmd]);
		final out = proc.stdout.readAll().toString();
		final code = proc.exitCode();
		proc.close();
		if (code != 0)
			throw 'command failed ($code): $cmd';
		final line = out.split("\n")[0];
		return line.endsWith("\r") ? line.substr(0, line.length - 1) : line;
	}
}
