package norc;

import sys.FileSystem;
import sys.io.Process;
import sys.thread.Thread;

using StringTools;

/**
	External hooks: executables in `<config dir>/hooks/` named `on-<event>`, run when the event happens
	(e.g. `hooks/on-message` for a received message, to show a notification).
	Several hooks per event: names starting with `on-<event>.` (e.g. `on-message.notify`, `on-message.log`),
	all are run, in the order of their names. Files without execute permission are skipped (disabled hooks).

	A hook gets the main values as arguments and all values as environment variables (`NORC_*`, the names
	uppercased), plus `NORC_EVENT`, `NORC_ACCOUNT` and `NORC_JID`. Hooks run asynchronously; their output is
	ignored, a failure (exit code other than 0) is reported.
**/
class Hooks {
	final dir:String;
	final account:String;

	/** Returns the own jid (empty while offline) **/
	final jid:() -> String;

	/** Runs a callback on the main thread **/
	final post:(() -> Void)->Void;

	public function new(dir:String, account:String, jid:() -> String, post:(() -> Void)->Void) {
		this.dir = dir;
		this.account = account;
		this.jid = jid;
		this.post = post;
	}

	/**
		Runs the hook of `event` (if it exists) with `args`, `values` as environment variables.
		Called on the main thread.
	**/
	public function run(event:String, args:Array<String>, ?values:Map<String, String>) {
		final hooks = find(event);
		if (hooks.length == 0)
			return;
		final env = values?.copy() ?? new Map<String, String>();
		env.set("event", event);
		env.set("account", account);
		env.set("jid", jid());
		// The environment is set for the started processes only: hooks are only started on the main thread
		final names = [for (k => v in env) 'NORC_${k.toUpperCase()}'];
		for (k => v in env)
			Sys.putEnv('NORC_${k.toUpperCase()}', v ?? "");
		final started = [
			for (name in hooks) {
				final proc = try start('$dir/$name', args) catch (e) {
					Term.error('hook $name: $e');
					null;
				}
				if (proc != null)
					{name: name, proc: proc};
			}
		];
		for (n in names)
			Sys.putEnv(n, null);
		for (h in started)
			Thread.create(() -> {
				// read the output (the hook would block on a full pipe), report failures
				final err = try h.proc.stderr.readAll().toString() catch (_) "";
				try h.proc.stdout.readAll() catch (_) {}
				final code = h.proc.exitCode();
				h.proc.close();
				if (code != 0)
					post(() -> Term.error('hook ${h.name} failed ($code)' + (err.trim().length > 0 ? ': ${err.trim().split("\n")[0]}' : '')));
			});
	}

	/**
		The hooks of `event`, sorted by name: executables named `on-<event>`, or starting with `on-<event>.`
		(e.g. `on-message.notify`, `on-message.log`). Files without execute permission are skipped.
	**/
	function find(event:String):Array<String> {
		if (!FileSystem.exists(dir) || !FileSystem.isDirectory(dir))
			return [];
		final prefix = 'on-$event';
		final windows = Sys.systemName() == "Windows";
		final hooks = [
			for (name in FileSystem.readDirectory(dir))
				if ((name == prefix || name.startsWith('$prefix.')) && !name.endsWith("~")) {
					final path = '$dir/$name';
					// not executable: disabled (e.g. a placeholder, enabled with chmod +x)
					if (!FileSystem.isDirectory(path) && (windows || FileSystem.stat(path).mode & 0x49 != 0))
						name;
				}
		];
		hooks.sort(Reflect.compare);
		return hooks;
	}

	static function start(path:String, args:Array<String>):Process {
		final proc = (Sys.systemName() == "Windows" && ~/\.(bat|cmd)$/i.match(path)) ? new Process("cmd", ["/c", path].concat(args)) : new Process(path,
			args);
		proc.stdin.close();
		return proc;
	}
}
