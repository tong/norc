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
	public function run(event:String, args:Array<String>, ?values:haxe.DynamicAccess<Dynamic>) {
		final hooks = find(event);
		if (hooks.length == 0)
			return;
		final env = new Map<String, String>();
		if (values != null)
			for (k => v in values)
				// matching a Dynamic against true would cast it to Bool
				env.set(k, (v == null) ? "" : Std.isOfType(v, Bool) ? ((v : Bool) ? "1" : "0") : Std.string(v));
		final started = withEnv(event, env, () -> [
			for (name in hooks) {
				final proc = try start('$dir/$name', args) catch (e) {
					Term.error('hook $name: $e');
					null;
				}
				if (proc != null)
					{name: name, proc: proc};
			}
		]);
		for (h in started)
			// read the output (the hook would block on a full pipe), report failures
			Thread.create(() -> {
				final err = try h.proc.stderr.readAll().toString() catch (_) "";
				try h.proc.stdout.readAll() catch (_) {}
				final code = h.proc.exitCode();
				h.proc.close();
				if (code != 0)
					post(() -> Term.error('hook ${h.name} failed ($code)' + (err.trim().length > 0 ? ': ${err.trim().split("\n")[0]}' : '')));
			});
	}

	/** Seconds a filter hook may take, else the data is passed on unchanged **/
	public static inline var FILTER_TIMEOUT = 5.0;

	/**
		Filter hooks: passes `data` through the hooks of `event` (stdin to stdout, chained in the order of their
		names) and returns the result, `null` if a hook dropped it (empty output).
		A hook failing (exit code, timeout, output rejected by `valid`) is reported and skipped.
		Blocks until the hooks are done.
	**/
	public function filter(event:String, data:String, ?valid:String->Bool):Null<String> {
		final hooks = find(event);
		if (hooks.length == 0)
			return data;
		return withEnv(event, null, () -> {
			var result:Null<String> = data;
			for (name in hooks) {
				final out = try runFilter('$dir/$name', result).trim() catch (e) {
					Term.error('hook $name: $e');
					continue;
				}
				if (out.length == 0) {
					result = null;
					break;
				}
				if (valid != null && !valid(out)) {
					Term.error('hook $name: invalid output, ignored: ${out.substr(0, 80)}');
					continue;
				}
				result = out;
			}
			result;
		});
	}

	/**
		Runs `f` with the `NORC_*` variables of `event` and `values` set, inherited by the processes it starts.
		Only on the main thread: the environment is shared by all threads.
	**/
	function withEnv<T>(event:String, values:Null<Map<String, String>>, f:() -> T):T {
		final env = values?.copy() ?? new Map<String, String>();
		env.set("event", event);
		env.set("account", account);
		env.set("jid", jid());
		for (k => v in env)
			Sys.putEnv('NORC_${k.toUpperCase()}', v ?? "");
		final result = try f() catch (e) {
			unset(env);
			throw e;
		}
		unset(env);
		return result;
	}

	static function unset(env:Map<String, String>)
		for (k in env.keys())
			Sys.putEnv('NORC_${k.toUpperCase()}', null);

	/** Runs a filter hook: `input` on stdin, returns stdout; throws on failure or timeout **/
	static function runFilter(path:String, input:String):String {
		final proc = start(path, [], false);
		final done = new sys.thread.Lock();
		var out = "";
		var err = "";
		var code = -1;
		Thread.create(() -> {
			try {
				proc.stdin.writeString(input);
				proc.stdin.close();
			} catch (_) {}
			err = try proc.stderr.readAll().toString() catch (_) "";
			done.release();
		});
		Thread.create(() -> {
			out = try proc.stdout.readAll().toString() catch (_) "";
			code = proc.exitCode();
			done.release();
		});
		if (!done.wait(FILTER_TIMEOUT) || !done.wait(FILTER_TIMEOUT)) {
			proc.kill();
			proc.close();
			throw 'timeout after ${FILTER_TIMEOUT}s';
		}
		proc.close();
		if (code != 0)
			throw 'failed ($code)' + (err.trim().length > 0 ? ': ${err.trim().split("\n")[0]}' : '');
		return out;
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

	/** Starts a hook (batch files with `cmd` on Windows), with stdin closed unless `input` **/
	static function start(path:String, args:Array<String>, input = false):Process {
		final proc = (Sys.systemName() == "Windows" && ~/\.(bat|cmd)$/i.match(path)) ? new Process("cmd", ["/c", path].concat(args)) : new Process(path, args);
		if (!input)
			proc.stdin.close();
		return proc;
	}
}
