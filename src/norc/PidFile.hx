package norc;

import sys.FileSystem;
import sys.io.File;

using StringTools;

/**
	Ensures only one norc instance uses an account: `<state dir>/pid` holds the pid of the running instance.
	A pid file whose process no longer exists (or is not norc) is stale and replaced.
**/
class PidFile {
	final path:String;

	function new(path:String) {
		this.path = path;
	}

	/**
		Creates the pid file in `dir`.
		Throws if another instance is running.
	**/
	public static function acquire(dir:String):PidFile {
		final pid = running(dir);
		if (pid != null)
			throw 'already running (pid $pid)';
		FileSystem.createDirectory(dir);
		final path = '$dir/pid';
		File.saveContent(path, '${ownPid()}\n');
		return new PidFile(path);
	}

	/**
		Returns the pid of the norc instance owning `dir`, or `null` if none is running.
	**/
	public static function running(dir:String):Null<Int> {
		final path = '$dir/pid';
		if (!FileSystem.exists(path))
			return null;
		final pid = Std.parseInt(File.getContent(path).trim());
		return (pid != null && pid != ownPid() && isNorc(pid)) ? pid : null;
	}

	public function release() {
		try
			FileSystem.deleteFile(path)
		catch (_) {}
	}

	@:hlNative("std", "sys_getpid")
	static function ownPid():Int
		return 0;

	/** Returns `true` if process `pid` is running and is norc (the pid may have been reused) **/
	static function isNorc(pid:Int):Bool
		return commandLine(pid).contains("norc");

	/** The command line of process `pid`, `""` if it doesn't exist **/
	static function commandLine(pid:Int):String {
		return switch Sys.systemName() {
			case "Linux":
				// Files in /proc report size 0, so read them as a stream (File.getContent returns "")
				try {
					final f = File.read('/proc/$pid/cmdline');
					final bytes = f.readAll();
					f.close();
					// Arguments are separated by NUL, which ends the string on HL
					for (i in 0...bytes.length)
						if (bytes.get(i) == 0)
							bytes.set(i, " ".code);
					bytes.toString();
				} catch (_)
					"";
			case "Windows":
				Term.output("powershell", [
					"-NoProfile",
					"-Command",
					'(Get-CimInstance Win32_Process -Filter "ProcessId=$pid").CommandLine'
				]) ?? "";
			case _:
				Term.output("ps", ["-p", '$pid', "-o", "command="]) ?? "";
		}
	}
}
