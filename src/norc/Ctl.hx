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
	/** The most of a text from stdin, a message **/
	static inline var MAX_TEXT = 64 * 1024;

	/** Lines from stdin (`--lines`): seconds at least between two messages **/
	static inline var INTERVAL = 1.0;

	public static final USAGE = 'Usage: norc ctl [options] <command> [args...]   run a command in the running norc
       norc ctl [options] events [event...]       print events (JSON lines) until norc quits
       norc ctl [options] wait <event>            wait for an event, print it

  -a, --account <name>   account of the running norc (default: the default account)
  -r, --resource <res>   the norc with this resource (started with --resource; default: the one with the
                         configured resource, else the only one running)
  -c, --config <dir>     config directory
      --json             the replies as JSON lines (data instead of text)
  -t, --timeout <s>      wait and events: stop after s seconds (exit code 1 for wait)
  -s, --stdin            the last argument from stdin: a text, or the file of a path (e.g. file share)
  -l, --lines            a text from stdin line by line, until its end (lines coming at once together)
  -n, --name <name>      the name of the file from stdin (default: stdin, with the extension of its type)

Needs a norc with the socket interface (api = 1 or --api). Examples:
  norc ctl presence away back at 3
  norc ctl msg alice hello there
  make 2>&1 | tail | norc ctl -s msg alice
  tail -f app.log | norc ctl -l msg alice
  grim - | norc ctl -s -n screen.png file share alice
  norc ctl --json contacts
  norc ctl events message call';

	/** `norc complete`: errors are not shown (they would appear in the shell's completion) **/
	static var quiet = false;

	/**
		Runs `norc ctl` with `args`; with `completing` (`norc complete`) the words are a command line to complete:
		prints the candidates for the last word, one per line (nothing without a running norc).
	**/
	public static function run(args:Array<String>, ?account:String, completing = false):Int {
		quiet = completing;
		var json = false;
		var timeout:Null<Float> = null;
		var stdin = false;
		var lines = false;
		var file:Null<String> = null;
		var resource:Null<String> = null;
		var i = 0;
		// options before the command
		while (i < args.length && args[i].startsWith("-")) {
			// the end of the options: the words follow (e.g. a word being completed starting with -)
			if (args[i] == "--") {
				i++;
				break;
			}
			switch args[i] {
				case "-a", "--account" if (i + 1 < args.length):
					account = args[++i];
				case "-r", "--resource" if (i + 1 < args.length):
					resource = args[++i];
				case "-c", "--config" if (i + 1 < args.length):
					Config.dir = haxe.io.Path.removeTrailingSlashes(args[++i]);
				case "--json":
					json = true;
				case "-t", "--timeout" if (i + 1 < args.length):
					timeout = Std.parseFloat(args[++i]);
					if (Math.isNaN(timeout) || timeout <= 0)
						return fail('invalid timeout: ${args[i]} (seconds)', 2);
				case "-s", "--stdin":
					stdin = true;
				case "-l", "--lines":
					lines = true;
				case "-n", "--name" if (i + 1 < args.length):
					file = args[++i];
				case "-h", "--help":
					Sys.println(USAGE);
					return 0;
				case option:
					return fail('unknown option: $option\n\n$USAGE', 2);
			}
			i++;
		}
		final words = args.slice(i);
		if (words.length == 0 && !completing)
			return fail(USAGE, 2);
		final configured = try (account != null) ? Config.findAccount(account) : Config.defaultAccount() catch (e) {
			// e.g. an account run with --jid: its state directory is named by the jid
			if (account == null || !FileSystem.exists('${Config.stateDir(account)}/api'))
				return fail(Std.string(e));
			null;
		}
		final name = configured?.name ?? account;
		final path = '${apiDir(name, (resource == configured?.resource) ? null : resource)}/api';
		final info = try [
			for (line in File.getContent(path).split("\n"))
				if (line.contains(" = ")) line.substr(0, line.indexOf(" = ")) => line.substr(line.indexOf(" = ") + 3).trim()
		] catch (_) null;
		final socket = try connect(info) catch (_) null;
		if (socket == null)
			return fail((info != null && info.exists("socket") && !info.exists("port") && !UnixSocket.available)
				? '$name: norc listens only at a Unix socket, which this norc can\'t use (the single binary on Linux and macOS can): api = socket,tcp'
				: 'norc doesn\'t run for $name with the socket interface (api = 1 or --api)');
		function send(request:Dynamic) {
			socket.output.writeString(Json.stringify(request) + "\n");
			socket.output.flush();
		}
		function read():Null<Dynamic>
			return try Json.parse(socket.input.readLine()) catch (_) null;
		// the Unix socket needs no token (answered ok)
		send({auth: info.get("token") ?? ""});
		final auth = read();
		if (auth == null || auth.ok != true)
			return fail('$name: not authorized (an old api file?)');
		if (timeout != null && (words[0] == "events" || words[0] == "wait"))
			socket.setTimeout(timeout);
		final code = switch words[0] {
			case _ if (completing):
				complete(send, read, words);
			case "events":
				follow(read, words.slice(1), false);
			case "wait" if (words.length == 2):
				follow(read, [words[1]], true);
			case "wait":
				fail("usage: norc ctl wait <event>", 2);
			case _ if (stdin || lines):
				fromStdin(send, read, words, json, lines, file);
			case _:
				send({
					id: 1,
					cmd: words[0],
					args: words.slice(1),
					text: !json,
					cwd: Sys.getCwd()
				});
				replies(read, json, 1);
		}
		socket.close();
		return code;
	}

	/**
		The state of the norc of `account` with the resource `resource` (`null`: the configured one), with its api file.
		Without `resource`, if that norc doesn't run: the only other one running with the api.
	**/
	static function apiDir(account:String, resource:Null<String>):String {
		final dir = Config.instanceDirOf(account, resource);
		// an api file stays after norc was killed: by the running norc
		if (resource != null || PidFile.running(dir) != null)
			return dir;
		final others = [
			for (i in PidFile.instances(Config.stateDir(account)))
				if (i.resource != null && FileSystem.exists('$dir/resources/${i.resource}/api')) '$dir/resources/${i.resource}'
		];
		return (others.length == 1) ? others[0] : dir;
	}

	/**
		Runs the command `words` with its last argument (a parameter taking the rest of the line) from stdin: a text,
		or for a path a temporary file with the input (named `file`); with `lines` a command per line.
	**/
	static function fromStdin(send:Dynamic->Void, read:() -> Null<Dynamic>, words:Array<String>, json:Bool, lines:Bool, file:Null<String>):Int {
		// the parameters: from the help of the command
		send({id: 0, cmd: "help", args: [words[0]]});
		var commands:Null<Array<Dynamic>> = null;
		while (true) {
			final r = read();
			if (r == null)
				return fail("norc closed the connection");
			if (r.id != 0)
				continue;
			if (r.type == "data")
				commands = r.data.commands;
			else if (r.type == "error")
				return fail(r.text);
			else if (r.type == "done")
				break;
		}
		if (commands == null || commands.length == 0)
			return fail('${words[0]}: unknown command');
		// the command, or its subcommand named by the next word
		var command:Dynamic = commands[0];
		var used = 1;
		if (words.length > 1)
			for (c in commands.slice(1))
				if ((c.command : String).split(" ").pop() == words[1]) {
					command = c;
					used = 2;
				}
		final params = ((command.args ?? "") : String).split(" ").filter(p -> p.length > 0);
		final last = params[params.length - 1];
		final usage = '${command.command}${params.length > 0 ? " " + params.join(" ") : ""}';
		if (last == null || !last.endsWith("...>") && !last.endsWith("...]"))
			return fail('${command.command}: no argument to read from stdin (usage: $usage)', 2);
		if (words.length - used >= params.length)
			return fail('${command.command}: the last argument comes from stdin (usage: $usage)', 2);
		final name = ~/[<>\[\].#]/g.replace(last, "");
		final args = words.slice(1);
		if (name == "path") {
			if (lines)
				return fail('${command.command}: a file, not lines', 2);
			final data = Sys.stdin().readAll();
			if (data.length == 0)
				return fail("no input");
			// readable only by you, removed when norc has read it (sending or uploading it)
			final dir = '${Sys.getEnv("TMPDIR") ?? "/tmp"}/norc-ctl-${Std.random(1 << 30)}';
			final path = '$dir/${file ?? "stdin" + extension(data)}';
			try {
				FileSystem.createDirectory(dir);
				Sys.command("chmod", ["700", dir]);
				File.saveBytes(path, data);
			} catch (e)
				return fail('cannot store the input: $e');
			send({
				id: 1,
				cmd: words[0],
				args: args.concat([path]),
				text: !json,
				cwd: Sys.getCwd()
			});
			final code = replies(read, json, 1);
			try {
				FileSystem.deleteFile(path);
				FileSystem.deleteDirectory(dir);
			} catch (_) {}
			return code;
		}
		// texts with line breaks as \n
		function request(id:Int, text:String) {
			send({
				id: id,
				cmd: words[0],
				args: args.concat([name == "text" ? Commands.escape(text) : text]),
				text: !json,
				cwd: Sys.getCwd()
			});
			return replies(read, json, id);
		}
		if (!lines) {
			final text = ~/[\r\n]+$/.replace(Sys.stdin().readAll().toString(), "");
			if (text.trim().length == 0)
				return fail("no input");
			if (text.length > MAX_TEXT)
				return fail('too long for a message: ${Term.size(text.length)} (max ${Term.size(MAX_TEXT)}; file share or file send for a file)');
			return request(1, text);
		}
		// the lines: read in a thread, those waiting together in one message, at most one per INTERVAL
		final queue = new sys.thread.Deque<{line:Null<String>}>();
		sys.thread.Thread.create(() -> {
			try
				while (true)
					queue.add({line: Sys.stdin().readLine()})
			catch (_) {}
			queue.add({line: null});
		});
		var code = 0;
		var id = 1;
		var sent = 0.0;
		while (true) {
			final first = queue.pop(true).line;
			if (first == null)
				break;
			final wait = sent + INTERVAL - haxe.Timer.stamp();
			if (wait > 0)
				Sys.sleep(wait);
			final batch = [first];
			var size = first.length;
			var end = false;
			while (true) {
				final next = queue.pop(false);
				if (next == null)
					break;
				if (next.line == null || size + next.line.length > MAX_TEXT) {
					// the end, or the next message
					queue.push(next);
					break;
				}
				batch.push(next.line);
				size += next.line.length + 1;
			}
			final text = [for (l in batch) StringTools.replace(l, "\r", "")].filter(l -> l.trim().length > 0).join("\n");
			if (text.length == 0)
				continue;
			sent = haxe.Timer.stamp();
			switch request(id++, text) {
				case 0:
				case 1:
					code = 1;
				case c:
					return c;
			}
		}
		return code;
	}

	/**
		Prints the candidates completing the last of `words` (a command line), one per line: as the shell replaces
		that word, without the words before it (a parameter taking the rest of the line completes several).
		Files are completed in the directory of the shell (`cwd`).
	**/
	static function complete(send:Dynamic->Void, read:() -> Null<Dynamic>, words:Array<String>):Int {
		final line = words.join(" ");
		send({id: 1, complete: line, cwd: Sys.getCwd()});
		while (true) {
			final r = read();
			if (r == null)
				return 1;
			if (r.id != 1)
				continue;
			if (r.type == "done")
				return 0;
			if (r.type != "complete")
				continue;
			final word:String = r.word;
			final first = words.length <= 1;
			// the command itself: without `/`, also the words of norc ctl
			final candidates:Array<String> = (r.candidates : Array<String>).concat(first ? ["events", "wait"].filter(w -> w.startsWith(line)) : []);
			final cut = first ? (word.startsWith("/") ? 1 : 0) : word.lastIndexOf(" ") + 1;
			for (c in candidates)
				Sys.println(first && !c.startsWith("/") ? c : c.substr(cut));
		}
	}

	/** The extension of a file by its first bytes (`.png`, …), `""` if not known **/
	static function extension(data:haxe.io.Bytes):String {
		final head = data.sub(0, Std.int(Math.min(data.length, 16))).toString();
		final hex = data.sub(0, Std.int(Math.min(data.length, 4))).toHex();
		return if (hex.startsWith("89504e47")) ".png"
		else if (hex.startsWith("ffd8ff")) ".jpg"
		else if (head.startsWith("GIF8")) ".gif"
		else if (head.startsWith("RIFF") && head.substr(8, 4) == "WEBP") ".webp"
		else if (head.startsWith("%PDF")) ".pdf"
		else if (hex.startsWith("1a45dfa3")) ".webm"
		else if (head.substr(4, 4) == "ftyp") ".mp4"
		else if (head.startsWith("OggS")) ".ogg"
		else if (head.startsWith("ID3") || hex.startsWith("fffb")) ".mp3"
		else if (hex.startsWith("504b0304")) ".zip"
		else if (hex.startsWith("1f8b")) ".gz"
		else if (data.length <= 1 << 20 && text(data)) ".txt"
		else "";
	}

	/** `data` is text: UTF-8 without control characters other than tab, line breaks, form feed and escape **/
	static function text(data:haxe.io.Bytes):Bool {
		var i = 0;
		while (i < data.length) {
			final b = data.get(i++);
			final more = if (b < 0x80) 0 else if (b >= 0xc2 && b < 0xe0) 1 else if (b >= 0xe0 && b < 0xf0) 2 else if (b >= 0xf0 && b < 0xf5) 3 else -1;
			if (more == -1 || (b < 0x20 && !["\t".code, "\n".code, "\r".code, 0x0c, 0x1b].contains(b)) || b == 0x7f)
				return false;
			for (_ in 0...more)
				if (i >= data.length || data.get(i++) & 0xc0 != 0x80)
					return false;
		}
		return true;
	}

	/**
		Connects to the norc of `info` (the api file): its Unix socket if it has one (and this binary supports them),
		else over TCP. Throws if it can't connect.
	**/
	static function connect(info:Null<Map<String, String>>):{input:haxe.io.Input, output:haxe.io.Output, setTimeout:Float->Void, close:() -> Void} {
		if (info == null)
			throw "no api file";
		final path = info.get("socket");
		if (path != null && UnixSocket.available) {
			final s = try UnixSocket.connect(path) catch (_) null;
			if (s != null)
				return {input: s.input, output: s.output, setTimeout: s.setTimeout, close: s.close};
		}
		if (!info.exists("port"))
			throw "no tcp";
		final socket = new Socket();
		socket.connect(new Host(info.get("host")), Std.parseInt(info.get("port")));
		return {input: socket.input, output: socket.output, setTimeout: socket.setTimeout, close: socket.close};
	}

	/** Prints the replies of request `id` until it is done: 0, or 1 if it failed **/
	static function replies(read:() -> Null<Dynamic>, json:Bool, id:Int):Int {
		while (true) {
			final r = read();
			if (r == null)
				return fail("norc closed the connection");
			if (r.id != id)
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
		if (!quiet)
			Sys.stderr().writeString(msg + "\n");
		return code;
	}
}
