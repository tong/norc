package norc;

import haxe.Json;
import sys.FileSystem;
import sys.io.File;
import sys.net.Host;
import sys.net.Socket;
import sys.thread.Deque;
import sys.thread.Thread;

using StringTools;

/**
	Socket interface for other programs: a TCP server (on `127.0.0.1` by default), one JSON object per line.

	The address and a random token are written to `<state dir>/api` (`host = …`, `port = …`, `token = …`, readable only
	by the user). A client authenticates first, then sends requests:

		→ {"auth":"4f3a…"}
		← {"type":"auth","ok":true}
		→ {"id":1,"cmd":"contacts"}
		← {"type":"data","id":1,"data":{"contacts":[{"jid":"alice@example.org","name":"Alice",…}]}}
		← {"type":"done","id":1,"ok":true}
		→ {"id":2,"cmd":"msg","args":["alice","hi there"]}
		← {"type":"done","id":2,"ok":true}
		← {"type":"event","event":"message","data":{"from":"alice@example.org/phone","body":"hello","delayed":false,…}}

	Requests: `cmd` is a command (e.g. `contacts add`) with its arguments in `args` (one per parameter, a parameter
	taking the rest of the line gets the remaining ones), or without `args` a command line as in the REPL (`/` optional).
	With `"text": true` results are text (`out`) as on the terminal instead of `data`. `cwd`: the directory of the
	program, relative paths in the command are relative to it (`Files.cwd`), else to the directory of norc.
	`{"complete": "msg al"}` completes a command line as Tab on the terminal: `complete` with `word` (the end of the
	line completed) and `candidates` (replacing it), in `groups` by kind (subcommands, options, contacts, files, …).
	`id` (any JSON value) is copied into the replies of the request.
	For use by hand (e.g. with socat), plain lines work too: `auth <token>`, then command lines, optionally prefixed
	with `@<id> `.

	The same protocol works over stdin and stdout (`stdio`), without authentication, e.g. for a program running norc
	as a child process.

	Replies: `out`, `info` and `error` (`text`) as on the terminal, `data` (`data`): a result as data, instead of
	its text. Last `done` (`ok`: `false` if an error was reported), once the command finished, including responses
	of the server it waits for (or `TIMEOUT`). Later replies with the id are notifications (e.g. of a file transfer).
	Events (the same as for hooks, with typed values) are sent to all authenticated clients.
**/
@:allow(norc)
class Api {
	final post:(() -> Void)->Void;
	final dispatch:(cmd:String, args:Null<Array<Null<String>>>, out:Output) -> Bool;

	/** Completes a command line (without `/`), as Tab in the terminal; `null` if not set **/
	public var complete:Null<(line:String) -> Null<Commands.Completed>>;

	final clients = new Array<ApiClient>();

	var server:Null<Socket>;

	/** The Unix socket listening, and its path **/
	var unixServer:Null<UnixSocket>;

	var socketPath:Null<String>;

	var file:Null<String>;
	var token = "";

	/**
		`dispatch` runs command `cmd` with `args`, or the command line `cmd` (`/` optional) if `args` is `null`;
		returns `false` if it could not run. `post` runs a callback on the main thread.
	**/
	public function new(dispatch:(cmd:String, args:Null<Array<Null<String>>>, out:Output) -> Bool, post:(() -> Void)->Void) {
		this.dispatch = dispatch;
		this.post = post;
	}

	/**
		Listens at the Unix socket `socket` (if set, where `UnixSocket.available`) and on `host:port` (`tcp`, port `0`:
		a free port), and writes where to `<dir>/api`: `socket = <path>`, `host`, `port` and `token`. If the Unix
		socket can't be opened (reported), TCP is used.

		The Unix socket is readable only by the user, and connections of other users are refused: no token needed,
		clients are authenticated (an `auth` request is answered `ok`). Over TCP any local process can connect, the
		token authenticates. Other hosts than `127.0.0.1` make the API reachable over the network: the connection is not
		encrypted.
	**/
	public function start(dir:String, host = "127.0.0.1", port = 0, tcp = true, ?socket:String) {
		FileSystem.createDirectory(dir);
		final lines = [];
		final unix = (socket != null && UnixSocket.available) ? try listenUnix(socket) catch (e) {
			Term.error('api: no Unix socket ($e), over TCP');
			tcp = true;
			null;
		} : null;
		if (unix != null)
			lines.push(unix);
		if (tcp)
			try
				lines.push(listenTcp(host, port))
			catch (e) {
				stop();
				throw e;
			}
		final path = '$dir/api';
		// create it empty and private before writing the token
		File.saveContent(path, "");
		if (Sys.systemName() != "Windows")
			Sys.command("chmod", ["600", path]);
		File.saveContent(path, lines.join("\n") + "\n");
		file = path;
	}

	/** Listens at the Unix socket `path` (in a directory only the user may access), returns the line of the api file **/
	function listenUnix(path:String):String {
		final dir = haxe.io.Path.directory(path);
		if (!FileSystem.exists(dir)) {
			FileSystem.createDirectory(dir);
			Sys.command("chmod", ["700", dir]);
		}
		final socket = UnixSocket.listen(path);
		unixServer = socket;
		socketPath = path;
		final uid = UnixSocket.uid();
		Thread.create(() -> while (true) {
			final s = try socket.accept() catch (_) return;
			// only the own user (the permissions of the socket refuse others already)
			final peer = s.peerUid();
			if (uid >= 0 && peer >= 0 && peer != uid) {
				s.close();
				continue;
			}
			post(() -> {
				final client = new ApiClient(s.input, s.output, s.close, this);
				client.authenticated = true;
				clients.push(client);
			});
		});
		return 'socket = $path';
	}

	/** Listens on `host:port`, returns the lines of the api file **/
	function listenTcp(host:String, port:Int):String {
		final socket = new Socket();
		socket.bind(new Host(host), port);
		socket.listen(10);
		server = socket;
		token = xmpp.Random.bytes(24).toHex();
		Thread.create(() -> while (true) {
			final s = try socket.accept() catch (_) return;
			post(() -> clients.push(new ApiClient(s.input, s.output, () -> {
				try
					s.shutdown(true, true)
				catch (_) {};
				try
					s.close()
				catch (_) {};
			}, this)));
		});
		return 'host = $host\nport = ${socket.host().port}\ntoken = $token';
	}

	/**
		Takes requests from stdin and writes replies and events to stdout, as an authenticated client.
		`closed` is called when stdin is closed.
	**/
	public function stdio(closed:() -> Void)
		connect(Sys.stdin(), Sys.stdout(), () -> {}, closed);

	/**
		An authenticated client reading requests from `input` and writing replies and events to `output`
		(e.g. a script: its stdout and stdin). `shutdown` is called after the last write when the client is closed,
		`closed` when the input ended. Returns the function closing the client.
	**/
	public function connect(input:haxe.io.Input, output:haxe.io.Output, shutdown:() -> Void, ?closed:() -> Void):() -> Void {
		final client = new ApiClient(input, output, shutdown, this);
		client.authenticated = true;
		client.onClose = closed;
		clients.push(client);
		return client.close;
	}

	public function stop() {
		if (file != null)
			try
				FileSystem.deleteFile(file)
			catch (_) {};
		file = null;
		for (c in clients.copy())
			c.close();
		if (server != null)
			try
				server.close()
			catch (_) {};
		server = null;
		if (unixServer != null)
			unixServer.close();
		unixServer = null;
		if (socketPath != null)
			try
				FileSystem.deleteFile(socketPath)
			catch (_) {};
		socketPath = null;
	}

	/** Sends an event to all authenticated clients **/
	public function event(name:String, values:Dynamic) {
		final line = Json.stringify({type: "event", event: name, data: values});
		for (c in clients)
			if (c.authenticated)
				c.send(line);
	}

	function receive(client:ApiClient, line:String) {
		line = line.trim();
		if (line.length == 0)
			return;
		final request:Dynamic = if (line.startsWith("{")) {
			try
				Json.parse(line)
			catch (e) {
				client.send(Json.stringify({type: "error", text: 'invalid request: $e'}));
				return;
			}
		} else textRequest(line);
		if (!client.authenticated) {
			// typed Dynamic: inferred from the use, the value would be cast before it is checked
			final token:Dynamic = Reflect.field(request, "auth");
			if (Std.isOfType(token, String) && equals(token, this.token)) {
				client.authenticated = true;
				client.send(Json.stringify({type: "auth", ok: true}));
			} else {
				client.send(Json.stringify({type: "auth", ok: false, text: "not authorized"}));
				client.close();
			}
			return;
		}
		// already authenticated (the Unix socket, stdin): as clients of TCP authenticate first
		if (Reflect.hasField(request, "auth")) {
			client.send(Json.stringify({type: "auth", ok: true}));
			return;
		}
		// "text": true, the text of data results (as on the terminal) instead of the data
		final out = new RequestOutput(client, Reflect.field(request, "id"), post, Reflect.field(request, "text") == true);
		final cwd:Dynamic = Reflect.field(request, "cwd");
		final line:Dynamic = Reflect.field(request, "complete");
		if (line != null) {
			if (!Std.isOfType(line, String) || complete == null) {
				out.error("invalid request: complete must be a command line");
				out.ran(false);
				return;
			}
			Files.cwd = Std.isOfType(cwd, String) ? cwd : null;
			final c = try complete(line) catch (_) null;
			Files.cwd = null;
			out.completed(c);
			out.ran(true);
			return;
		}
		final cmd:Dynamic = Reflect.field(request, "cmd");
		final args:Dynamic = Reflect.field(request, "args");
		if (!Std.isOfType(cmd, String)) {
			out.error("invalid request: cmd (a string) missing");
			out.ran(false);
			return;
		}
		if (args != null && !Std.isOfType(args, Array)) {
			out.error("invalid request: args must be an array");
			out.ran(false);
			return;
		}
		final list:Null<Array<Null<String>>> = (args == null) ? null : [
			for (a in (args : Array<Dynamic>))
				(a == null)
			?null:Std.isOfType
			(a, String)
			? a : Json.stringify(a)
		];
		// relative paths of the command: of the program sending it (resolved while the command starts)
		Files.cwd = Std.isOfType(cwd, String) ? cwd : null;
		final ran = try dispatch(cmd, list, out) catch (e) {
			// a bug in a command must not end the client
			out.error('internal error: $e');
			false;
		}
		Files.cwd = null;
		out.ran(ran);
	}

	/** A plain line: `auth <token>`, or a command line, optionally prefixed with `@<id> ` **/
	static function textRequest(line:String):Dynamic {
		if (line.startsWith("auth "))
			return {auth: line.substr(5).trim()};
		if (line.startsWith("@")) {
			final i = line.indexOf(" ");
			return {id: line.substring(1, i == -1 ? line.length : i), cmd: (i == -1) ? "" : line.substr(i + 1)};
		}
		return {cmd: line};
	}

	function remove(client:ApiClient)
		clients.remove(client);

	/** Compares in constant time (the token) **/
	static function equals(a:String, b:String):Bool {
		if (a.length != b.length)
			return false;
		var diff = 0;
		for (i in 0...a.length)
			diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
		return diff == 0;
	}
}

/**
	A connected program (a socket, or stdin and stdout): a thread reads its lines, a thread writes
	(writes don't block the main thread).
**/
@:allow(norc.Api)
private class ApiClient {
	/** Queued to close the connection after the queued lines **/
	// not "\x00close": HashLink/C writes it as a C string, where "\x00c" is one character
	static final CLOSE = "\x00:close";

	/** Lines not yet written, more are dropped (a client not reading, e.g. a script ignoring events) **/
	static inline var MAX_QUEUED = 1000;

	public var authenticated = false;

	/** Called on the main thread when the client closed the connection (end of input) **/
	public var onClose:Null<() -> Void>;

	final input:haxe.io.Input;
	final output:haxe.io.Output;

	/** Closes the connection, after the last write **/
	final shutdown:() -> Void;

	final api:Api;
	final writes = new Deque<String>();
	var closed = false;

	/** Lines queued and not written yet (approximately: changed by two threads) **/
	var queued = 0;

	/** Lines are dropped because the client doesn't read **/
	var dropping = false;

	function new(input:haxe.io.Input, output:haxe.io.Output, shutdown:() -> Void, api:Api) {
		this.input = input;
		this.output = output;
		this.shutdown = shutdown;
		this.api = api;
		Thread.create(readLoop);
		Thread.create(writeLoop);
	}

	public function send(line:String) {
		if (closed)
			return;
		if (queued >= MAX_QUEUED) {
			if (!dropping) {
				dropping = true;
				Term.error('api: a client does not read its replies and events, dropping them');
			}
			return;
		}
		dropping = false;
		queued++;
		writes.add(line);
	}

	public function close() {
		if (closed)
			return;
		closed = true;
		writes.add(CLOSE);
		api.remove(this);
	}

	function readLoop() {
		while (true) {
			final line = try input.readLine() catch (_) null;
			if (line == null)
				break;
			final l = line.endsWith("\r") ? line.substr(0, line.length - 1) : line;
			api.post(() -> if (!closed) api.receive(this, l));
		}
		api.post(() -> {
			close();
			if (onClose != null)
				onClose();
		});
	}

	function writeLoop() {
		while (true) {
			final line = writes.pop(true);
			if (line == CLOSE)
				break;
			queued--;
			try {
				output.writeString(line + "\n");
				output.flush();
			} catch (_)
				break;
		}
		shutdown();
	}
}

/** Output of a request: replies tagged with its id, `done` once the command and what it waits for finished **/
private class RequestOutput implements Output {
	/** Seconds to wait for asynchronous results (`wait`) **/
	static inline var TIMEOUT = 60.0;

	final client:ApiClient;
	final id:Dynamic;
	final post:(() -> Void)->Void;

	/** An error was reported **/
	var failed = false;

	/** The command returned **/
	var returned = false;

	/** Asynchronous results waited for **/
	var pending = 0;

	/** `done` was sent **/
	var finished = false;

	/** Data results as text **/
	final text:Bool;

	public function new(client:ApiClient, id:Dynamic, post:(() -> Void)->Void, text = false) {
		this.client = client;
		this.id = id;
		this.post = post;
		this.text = text;
	}

	public function print(text:String)
		send({type: "out", text: plain(text)});

	public function info(text:String)
		send({type: "info", text: plain(text)});

	public function error(text:String) {
		if (!finished)
			failed = true;
		send({type: "error", text: plain(text)});
	}

	public function data(value:Dynamic, show:() -> Void)
		if (text)
			show();
		else
			send({type: "data", data: value});

	public function wait():() -> Void {
		pending++;
		var called = false;
		function finish() {
			if (called)
				return;
			called = true;
			pending--;
			check();
		}
		Thread.create(() -> {
			Sys.sleep(TIMEOUT);
			post(() -> if (!called) {
				error('no response within ${TIMEOUT}s');
				finish();
			});
		});
		return finish;
	}

	/** The candidates of a completion (`null`: none) **/
	public function completed(c:Null<Commands.Completed>)
		send({
			type: "complete",
			word: c?.word ?? "",
			candidates: c?.candidates ?? [],
			groups: c?.groups ?? []
		});

	/** The command returned, `false` if it could not run **/
	public function ran(ok:Bool) {
		returned = true;
		if (!ok)
			failed = true;
		check();
	}

	function check() {
		if (returned && pending == 0 && !finished) {
			finished = true;
			send({type: "done", ok: !failed});
		}
	}

	function send(reply:haxe.DynamicAccess<Dynamic>) {
		if (id != null)
			reply.set("id", id);
		client.send(Json.stringify(reply));
	}

	/** Without colors **/
	static function plain(text:String):String
		return ~/\x1B\[[0-9;]*m/g.replace(text, "");
}
