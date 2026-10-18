package norc;

import sys.FileSystem;
import sys.io.Process;
import sys.thread.Thread;

using StringTools;

/**
	External hooks: executables in `<config dir>/hooks/` (all accounts) and `<account dir>/hooks/` (one account)
	named `on-<event>`, run when the event happens (e.g. `hooks/on-message` for a received message, to show a
	notification). Several hooks per event: names starting with `on-<event>.` (e.g. `on-message.notify`,
	`on-message.log`), all are run, those of the config directory first, each in the order of their names.
	Files without execute permission are skipped (disabled hooks).

	A hook gets the main values as arguments and all values as environment variables (`NORC_*`, the names
	uppercased), plus `NORC_EVENT`, `NORC_ACCOUNT` and `NORC_JID`. Hooks run asynchronously; their output is
	ignored, a failure (exit code other than 0) is reported.
**/
class Hooks {
	/** The events with hooks: those emitted, and the filters of stanzas **/
	public static final EVENTS = [
		"message", "sent", "reaction", "retraction", "server", "avatar", "receipt", "chatstate", "nickname", "mood", "tune", "call",
		"recording", "room", "room-invite", "attention", "presence", "subscribe", "subscription", "roster", "file-offer", "file-received",
		"file-sent", "file-failed", "share", "share-deleted", "share-invite", "share-resync", "login", "logout", "error", "status", "stanza-send",
		"stanza-recv"
	];

	/** Runs and failures of each hook (by path) since the start, with the last error **/
	final stats = new Map<String, {runs:Int, failures:Int, ?error:String}>();

	/** Directories of hooks, in the order their hooks run **/
	final dirs:Array<String>;

	final account:String;

	/** Returns the own jid (empty while offline) **/
	final jid:() -> String;

	/** Runs a callback on the main thread **/
	final post:(() -> Void)->Void;

	public function new(dirs:Array<String>, account:String, jid:() -> String, post:(() -> Void)->Void) {
		this.dirs = dirs;
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
		final started = withEnv(environment(event, values), () -> [
			for (h in hooks) {
				count(h.path);
				final proc = try start(h.path, args) catch (e) {
					failure(h.path, Std.string(e));
					Term.error('hook ${h.name}: $e');
					null;
				}
				if (proc != null) {name: h.name, path: h.path, proc: proc};
			}
		]);
		for (h in started)
			// read the output (the hook would block on a full pipe), report failures
			Thread.create(() -> {
				final err = try h.proc.stderr.readAll().toString() catch (_) "";
				try
					h.proc.stdout.readAll()
				catch (_) {}
				final code = h.proc.exitCode();
				h.proc.close();
				if (code != 0)
					post(() -> {
						failure(h.path, failed(code, err));
						Term.error('hook ${h.name} ${failed(code, err)}');
					});
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
		return withEnv(environment(event), () -> {
			var result:Null<String> = data;
			for (h in hooks) {
				final name = h.name;
				count(h.path);
				final out = try runFilter(h.path, result).trim() catch (e) {
					failure(h.path, Std.string(e));
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

	function count(path:String) {
		final s = stats.get(path) ?? {runs: 0, failures: 0};
		s.runs++;
		stats.set(path, s);
	}

	function failure(path:String, error:String) {
		final s = stats.get(path) ?? {runs: 0, failures: 0};
		s.failures++;
		s.error = error;
		stats.set(path, s);
	}

	public function commands():Array<Commands.Command>
		return [
			{
				name: "hooks",
				description: "list the hooks (config dir and account dir hooks/): their event, enabled (executable) or not, "
				+ "how often they ran and failed since the start",
				run: (_, out) -> list(out)
			}
		];

	/** Lists the files of the hook directories: hooks with their event and state, and files which are no hooks **/
	function list(out:Output) {
		final found = [];
		for (dir in dirs) {
			if (!FileSystem.exists(dir) || !FileSystem.isDirectory(dir))
				continue;
			final enabled = executables(dir);
			final names = [
				for (name in FileSystem.readDirectory(dir))
					if (!name.startsWith(".") && !name.endsWith("~") && !FileSystem.isDirectory('$dir/$name')) name
			];
			names.sort(Reflect.compare);
			for (name in names) {
				final path = '$dir/$name';
				// on-<event> or on-<event>.<anything>
				final event = name.startsWith("on-") ? name.substr(3).split(".")[0] : null;
				final s = stats.get(path);
				found.push({
					dir: dir,
					name: name,
					path: path,
					event: event,
					known: event != null && EVENTS.contains(event),
					enabled: enabled.contains(name),
					runs: s?.runs ?? 0,
					failures: s?.failures ?? 0,
					error: s?.error
				});
			}
		}
		out.data({hooks: found}, () -> {
			if (found.length == 0) {
				out.info('no hooks (executables named on-<event> in ${[for (d in dirs) Config.contractHome(d)].join(", ")})');
				return;
			}
			var width = 0;
			for (h in found)
				width = Std.int(Math.max(width, h.name.length));
			var dir = null;
			for (h in found) {
				if (h.dir != dir) {
					dir = h.dir;
					out.print(Term.style(Config.contractHome(dir), 2));
				}
				final state = if (h.event == null) Term.style("not a hook (named on-<event>)", 2)
				else if (!h.known) Term.style('unknown event ${h.event}', 31)
				else if (!h.enabled) Term.style("disabled (chmod +x to enable)", 2)
				else if (h.runs == 0) "enabled"
				else 'enabled, ran ${h.runs}×' + (h.failures > 0 ? Term.style(', failed ${h.failures}×: ${h.error}', 31) : '');
				out.print('  ${h.name.rpad(" ", width)}  $state');
			}
		});
	}

	/** The variables of the hooks of `event`: its `values`, `event`, `account` and `jid` **/
	function environment(event:String, ?values:haxe.DynamicAccess<Dynamic>):Map<String, String> {
		final env = new Map<String, String>();
		for (k => v in values ?? {})
			// matching a Dynamic against true would cast it to Bool
			env.set(k, (v == null) ? "" : Std.isOfType(v, Bool) ? ((v : Bool) ? "1" : "0") : Std.string(v));
		env.set("event", event);
		env.set("account", account);
		env.set("jid", jid());
		return env;
	}

	/**
		Runs `f` with the variables `env` set as `NORC_<NAME>` (uppercased), inherited by the processes it starts.
		Only on the main thread: the environment is shared by all threads.
	**/
	public static function withEnv<T>(env:Map<String, String>, f:() -> T):T {
		function set(unset:Bool)
			for (k => v in env)
				Sys.putEnv('NORC_${k.toUpperCase()}', unset ? null : v);
		set(false);
		final result = try f() catch (e) {
			set(true);
			throw e;
		}
		set(true);
		return result;
	}

	/** e.g. `failed (1): the first line of the error output` **/
	static function failed(code:Int, err:String):String
		return 'failed ($code)' + (err.trim().length > 0 ? ': ${err.trim().split("\n")[0]}' : '');

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
			throw failed(code, err);
		return out;
	}

	/**
		The hooks of `event`: executables named `on-<event>`, or starting with `on-<event>.` (e.g. `on-message.notify`,
		`on-message.log`), of each directory sorted by name. Files without execute permission are skipped.
	**/
	function find(event:String):Array<{name:String, path:String}> {
		final prefix = 'on-$event';
		final hooks = [];
		for (dir in dirs) {
			final names = [
				for (name in executables(dir))
					if ((name == prefix || name.startsWith('$prefix.')) && !name.endsWith("~")) name
			];
			names.sort(Reflect.compare);
			for (name in names)
				hooks.push({name: name, path: '$dir/$name'});
		}
		return hooks;
	}

	/** The executable files of `dir` (not executable: disabled, e.g. an example, enabled with chmod +x) **/
	public static function executables(dir:String):Array<String> {
		if (!FileSystem.exists(dir) || !FileSystem.isDirectory(dir))
			return [];
		final windows = Sys.systemName() == "Windows";
		return [
			for (name in FileSystem.readDirectory(dir)) {
				final path = '$dir/$name';
				if (!name.startsWith(".") && !FileSystem.isDirectory(path) && (windows || FileSystem.stat(path).mode & 0x49 != 0)) name;
			}
		];
	}

	/** Starts a hook (batch files with `cmd` on Windows), with stdin closed unless `input` **/
	public static function start(path:String, args:Array<String>, input = false):Process {
		final proc = (Sys.systemName() == "Windows" && ~/\.(bat|cmd)$/i.match(path)) ? new Process("cmd", ["/c", path].concat(args)) : new Process(path, args);
		if (!input)
			proc.stdin.close();
		return proc;
	}
}
