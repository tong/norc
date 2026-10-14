package norc;

import norc.Output;
import sys.io.Process;
import sys.thread.Thread;

using StringTools;

private enum ScriptState {
	Running(proc:Process);

	/** Exited with code 0, not started again **/
	Exited;

	/** Exited with an error, started again after `delay` seconds **/
	Failed(code:Int, delay:Int);

	/** Stopped with `/scripts stop` or when norc quits **/
	Stopped;
}

private typedef Script = {
	var name:String;
	var path:String;

	/** Of the account directory (only this account), else of the config directory **/
	var account:Bool;

	var state:ScriptState;

	/** Started again after errors, since it last ran for a while (the delay before the next start) **/
	var restarts:Int;

	/** Time of the last start **/
	var started:Float;

	/** Incremented on each start: callbacks of an earlier process are ignored **/
	var run:Int;

	/** The run whose process exited (set by the thread waiting for it) **/
	var finished:Int;

	/** Closes the api connection of the running process **/
	var ?close:() -> Void;
}

/**
	Scripts: executables in `<config dir>/scripts/` (all accounts) and `<account dir>/scripts/` (one account),
	started with norc and stopped when it quits. Not executable: disabled (enabled with `chmod +x`).

	The stdin and stdout of a script are its connection to the API (JSON lines, already authenticated, see `Api`):
	it writes requests to stdout and reads replies and events from stdin. Its stderr is shown as error output.
	Environment: `NORC_ACCOUNT`, `NORC_CONFIG` (the config directory), `NORC_ACCOUNT_DIR` (if the account is a directory).

	A script exiting with an error is started again after a delay (1 s, growing to 60 s; reset after it ran for a
	minute), one exiting with 0 is done.
**/
class Scripts {
	static final BACKOFF = [1, 2, 5, 10, 30, 60];

	/** Seconds a script runs until its restart delay is reset **/
	static inline var STABLE = 60.0;

	final api:Api;
	final env:Map<String, String>;

	/** Runs a callback on the main thread **/
	final post:(() -> Void)->Void;

	final scripts = new Array<Script>();

	/** `global`: the scripts of the config directory, `account`: of the account directory (`null` if none) **/
	public function new(global:String, account:Null<String>, api:Api, env:Map<String, String>, post:(() -> Void)->Void) {
		this.api = api;
		this.env = env;
		this.post = post;
		for (dir in [global, account])
			if (dir != null) {
				final names = Hooks.executables(dir);
				names.sort(Reflect.compare);
				for (name in names)
					scripts.push({
						name: name,
						path: '$dir/$name',
						account: dir == account,
						state: Stopped,
						restarts: 0,
						started: 0,
						run: 0,
						finished: 0
					});
			}
	}

	public function commands():Array<Commands.Command>
		return [
			{
				name: "scripts",
				description: "list the scripts (config dir and account dir scripts/) and their state",
				run: (args, out) -> list(out),
				subcommands: [
					{
						name: "restart",
						args: "<name>",
						description: "start a script again",
						run: (args, out) -> restart(args[0], out),
						complete: ["name" => _ -> [for (s in scripts) s.name]]
					},
					{
						name: "stop",
						args: "<name>",
						description: "stop a script (until /scripts restart or the next start of norc)",
						run: (args, out) -> stop(args[0], out),
						complete: ["name" => _ -> [for (s in scripts) s.name]]
					}
				]
			}
		];

	/** Starts all scripts **/
	public function startAll()
		for (s in scripts)
			start(s);

	/** Stops all scripts: closes their input, kills those still running after `wait` seconds **/
	public function stopAll(wait = 1.0) {
		final running = [
			for (s in scripts)
				switch s.state {
					case Running(proc): {s: s, proc: proc, run: s.run};
					case _: null;
				}
		].filter(r -> r != null);
		for (r in running) {
			r.s.run++;
			r.s.state = Stopped;
			if (r.s.close != null)
				r.s.close();
		}
		// scripts end at the end of their input, the others are killed
		final end = Sys.time() + wait;
		for (r in running) {
			while (Sys.time() < end && r.s.finished != r.run)
				Sys.sleep(0.05);
			if (r.s.finished != r.run)
				try r.proc.kill() catch (_) {};
		}
	}

	function start(s:Script) {
		final run = ++s.run;
		final values = env.copy();
		for (k => v in values)
			Sys.putEnv('NORC_$k', v);
		final proc = try Hooks.start(s.path, [], true) catch (e) {
			for (k in values.keys())
				Sys.putEnv('NORC_$k', null);
			Term.error('script ${s.name}: $e');
			s.state = Failed(-1, 0);
			return;
		}
		for (k in values.keys())
			Sys.putEnv('NORC_$k', null);
		s.state = Running(proc);
		s.started = Sys.time();
		// the api over its stdout and stdin
		s.close = api.connect(proc.stdout, proc.stdin, () -> try proc.stdin.close() catch (_) {});
		// its exit
		Thread.create(() -> {
			final code = try proc.exitCode() catch (_) -1;
			s.finished = run;
			post(() -> exited(s, run, code));
		});
		// its error output
		Thread.create(() -> {
			while (true) {
				final line = try proc.stderr.readLine() catch (_) break;
				post(() -> Term.error('${s.name}: $line'));
			}
		});
	}

	function exited(s:Script, run:Int, code:Int) {
		// stopped or started again meanwhile
		if (run != s.run)
			return;
		if (s.close != null)
			s.close();
		if (code == 0) {
			s.state = Exited;
			return;
		}
		if (Sys.time() - s.started >= STABLE)
			s.restarts = 0;
		final delay = BACKOFF[Std.int(Math.min(s.restarts, BACKOFF.length - 1))];
		s.restarts++;
		s.state = Failed(code, delay);
		Term.error('script ${s.name} failed ($code), starting it again in ${delay}s');
		Thread.create(() -> {
			Sys.sleep(delay);
			post(() -> if (s.run == run && s.state.match(Failed(_))) start(s));
		});
	}

	function list(out:Output) {
		final data = [
			for (s in scripts)
				{
					name: s.name,
					path: s.path,
					account: s.account,
					state: switch s.state {
						case Running(_): "running";
						case Exited: "exited";
						case Failed(_): "failed";
						case Stopped: "stopped";
					},
					code: switch s.state {
						case Failed(code, _): code;
						case _: null;
					},
					restarts: s.restarts
				}
		];
		out.data({scripts: data}, () -> {
			if (scripts.length == 0)
				out.info('no scripts (executables in ${Config.configDir()}/scripts/ or the account directory)');
			for (s in scripts) {
				final state = switch s.state {
					case Running(proc): 'running (pid ${proc.getPid()})';
					case Exited: "exited";
					case Failed(code, delay): 'failed ($code), restarting (after ${delay}s)';
					case Stopped: "stopped";
				}
				out.print('  ${s.name}' + (s.account ? Term.style(" (account)", 2) : "") + '  $state'
					+ (s.restarts > 0 ? Term.style('  ${s.restarts} restarts', 2) : ""));
			}
		});
	}

	function restart(name:String, out:Output) {
		final found = byName(name, out);
		for (s in found) {
			stopOne(s);
			s.restarts = 0;
			start(s);
			out.info('started ${s.name}');
		}
	}

	function stop(name:String, out:Output) {
		final found = byName(name, out);
		for (s in found) {
			stopOne(s);
			out.info('stopped ${s.name}');
		}
	}

	function stopOne(s:Script) {
		s.run++;
		switch s.state {
			case Running(proc):
				if (s.close != null)
					s.close();
				try proc.kill() catch (_) {};
			case _:
		}
		s.state = Stopped;
	}

	function byName(name:String, out:Output):Array<Script> {
		final found = [for (s in scripts) if (s.name == name) s];
		if (found.length == 0)
			out.error('no script $name (/scripts)');
		return found;
	}
}
