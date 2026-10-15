package norc;

import haxe.Json;
import sys.FileSystem;
import sys.io.File;
import sys.net.Host;
import sys.net.Socket;

using StringTools;

/**
	`norc ctl`: runs a command in a running norc and prints its output, or follows
	its events, through the socket interface of norc (`api = 1` or `--api`, see `Api`).

	The words of the command are passed as they are (no quoting needed), a parameter taking the rest of the line
	gets the remaining words. Exit code 0, 1 if the command failed or norc doesn't run with the socket interface.
**/
class Ctl {
	public static final USAGE = 'Usage: norc ctl [options] <command> [args...]   run a command in the running norc
       norc ctl [options] events [event...]       print events (JSON lines) until norc quits
       norc ctl [options] wait <event>            wait for an event, print it

  -a, --account <name>   account of the running norc (default: the default account)
  -c, --config <dir>     config directory
      --json             the replies as JSON lines (data instead of text)
  -t, --timeout <s>      wait and events: stop after s seconds (exit code 1 for wait)

Needs a norc with the socket interface (api = 1 or --api). Examples:
  norc ctl presence away back at 3
  norc ctl msg alice hello there
  norc ctl --json contacts
  norc ctl events message call';

	public static function run(args:Array<String>, ?account:String):Int {
		var json = false;
		var timeout:Null<Float> = null;
		var i = 0;
		// options before the command
		while (i < args.length && args[i].startsWith("-")) {
			switch args[i] {
				case "-a", "--account" if (i + 1 < args.length):
					account = args[++i];
				case "-c", "--config" if (i + 1 < args.length):
					Config.dir = haxe.io.Path.removeTrailingSlashes(args[++i]);
				case "--json":
					json = true;
				case "-t", "--timeout" if (i + 1 < args.length):
					timeout = Std.parseFloat(args[++i]);
					if (Math.isNaN(timeout) || timeout <= 0)
						return fail('invalid timeout: ${args[i]} (seconds)', 2);
				case "-h", "--help":
					Sys.println(USAGE);
					return 0;
				case option:
					return fail('unknown option: $option\n\n$USAGE', 2);
			}
			i++;
		}
		final words = args.slice(i);
		if (words.length == 0)
			return fail(USAGE, 2);
		final name = try (account != null) ? Config.findAccount(account).name : Config.defaultAccount().name catch (e) {
			// e.g. an account run with --jid: its state directory is named by the jid
			if (account == null || !FileSystem.exists('${Config.stateDir(account)}/api'))
				return fail(Std.string(e));
			account;
		}
		final path = '${Config.stateDir(name)}/api';
		final info = try [
			for (line in File.getContent(path).split("\n"))
				if (line.contains(" = ")) line.substr(0, line.indexOf(" = ")) => line.substr(line.indexOf(" = ") + 3).trim()
		] catch (_) null;
		final socket = new Socket();
		try {
			if (info == null)
				throw "no api file";
			socket.connect(new Host(info.get("host")), Std.parseInt(info.get("port")));
		} catch (_)
			return fail('norc doesn\'t run for $name with the socket interface (api = 1 or --api)');
		function send(request:Dynamic) {
			socket.output.writeString(Json.stringify(request) + "\n");
			socket.output.flush();
		}
		function read():Null<Dynamic>
			return try Json.parse(socket.input.readLine()) catch (_) null;
		send({auth: info.get("token")});
		final auth = read();
		if (auth == null || auth.ok != true)
			return fail('$name: not authorized (an old api file?)');
		if (timeout != null && (words[0] == "events" || words[0] == "wait"))
			socket.setTimeout(timeout);
		final code = switch words[0] {
			case "events":
				follow(read, words.slice(1), false);
			case "wait" if (words.length == 2):
				follow(read, [words[1]], true);
			case "wait":
				fail("usage: norc ctl wait <event>", 2);
			case _:
				send({
					id: 1,
					cmd: words[0],
					args: words.slice(1),
					text: !json
				});
				replies(read, json);
		}
		socket.close();
		return code;
	}

	/** Prints the replies of the request until it is done: 0, or 1 if it failed **/
	static function replies(read:() -> Null<Dynamic>, json:Bool):Int {
		while (true) {
			final r = read();
			if (r == null)
				return fail("norc closed the connection");
			if (r.id != 1)
				continue;
			if (r.type == "done")
				return (r.ok == true) ? 0 : 1;
			if (json)
				Sys.println(Json.stringify(r));
			else if (r.type == "error")
				Sys.stderr().writeString(r.text + "\n");
			else if (r.text != null)
				Sys.println(r.text);
		}
	}

	/** Prints the events (all, or those named in `names`) until norc quits; `once`: only the first **/
	static function follow(read:() -> Null<Dynamic>, names:Array<String>, once:Bool):Int {
		while (true) {
			final r = read();
			// the end of norc, or the timeout
			if (r == null)
				return once ? fail("no such event (norc quit, or the timeout)") : 0;
			if (r.type != "event" || (names.length > 0 && !names.contains(r.event)))
				continue;
			Sys.println(Json.stringify({event: r.event, data: r.data}));
			if (once)
				return 0;
		}
	}

	static function fail(msg:String, code = 1):Int {
		Sys.stderr().writeString(msg + "\n");
		return code;
	}
}
