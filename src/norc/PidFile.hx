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
		final path = '$dir/pid';
		final own = ownPid();
		if (FileSystem.exists(path)) {
			final pid = Std.parseInt(File.getContent(path).trim());
			if (pid != null && pid != own && isNorc(pid))
				throw 'already running (pid $pid)';
		}
		FileSystem.createDirectory(dir);
		File.saveContent(path, '$own\n');
		return new PidFile(path);
	}

	public function release() {
		try
			FileSystem.deleteFile(path)
		catch (_) {}
	}

	static function ownPid():Int {
		// /proc/self links to /proc/<pid>
		final pid = Std.parseInt(haxe.io.Path.withoutDirectory(FileSystem.fullPath("/proc/self")));
		if (pid == null)
			throw "cannot determine own pid (no /proc?)";
		return pid;
	}

	static function isNorc(pid:Int):Bool {
		// Files in /proc report size 0, so read them as a stream (File.getContent returns "")
		final content = try {
			final f = File.read('/proc/$pid/cmdline');
			final bytes = f.readAll();
			f.close();
			// Arguments are separated by NUL, which ends the string on HL
			for (i in 0...bytes.length)
				if (bytes.get(i) == 0)
					bytes.set(i, " ".code);
			bytes.toString();
		} catch (_) "";
		return content.contains("norc");
	}
}
