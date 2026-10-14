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
		→ {"id":1,"cmd":"roster"}
		← {"type":"data","id":1,"data":{"contacts":[{"jid":"alice@example.org","name":"Alice",…}]}}
		← {"type":"done","id":1,"ok":true}
		→ {"id":2,"cmd":"msg","args":["alice","hi there"]}
		← {"type":"done","id":2,"ok":true}
		← {"type":"event","event":"message","data":{"from":"alice@example.org/phone","body":"hello","delayed":false,…}}

	Requests: `cmd` is a command (e.g. `roster add`) with its arguments in `args` (one per parameter, a parameter
	taking the rest of the line gets the remaining ones), or without `args` a command line as in the REPL (`/` optional).
	`id` (any JSON value) is copied into the replies of the request.
	For use by hand (e.g. with socat), plain lines work too: `auth <token>`, then command lines, optionally prefixed
	with `@<id> `.

	Replies: `out`, `info` and `error` (`text`) as on the terminal, `data` (`data`): a result as data, instead of
	its text. Last `done` (`ok`: `false` if an error was reported), once the command finished, including responses
	of the server it waits for (or `TIMEOUT`). Later replies with the id are notifications (e.g. of a file transfer).
	Events (the same as for hooks, with typed values) are sent to all authenticated clients.
**/
@:allow(norc)
class Api {
	final post:(() -> Void)->Void;
	final dispatch:(cmd:String, args:Null<Array<Null<String>>>, out:Output) -> Bool;
	final clients = new Array<ApiClient>();

	var server:Null<Socket>;
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
		Listens on `host:port` (port `0`: a free port) and writes host, port and token to `<dir>/api`.
		Other hosts than `127.0.0.1` make the API reachable over the network: the connection is not encrypted.
	**/
	public function start(dir:String, host = "127.0.0.1", port = 0) {
		final socket = new Socket();
		socket.bind(new Host(host), port);
		socket.listen(10);
		server = socket;
		token = xmpp.Random.bytes(24).toHex();
		FileSystem.createDirectory(dir);
		final path = '$dir/api';
		// create it empty and private before writing the token
		File.saveContent(path, "");
		if (Sys.systemName() != "Windows")
			Sys.command("chmod", ["600", path]);
		File.saveContent(path, 'host = $host\nport = ${socket.host().port}\ntoken = $token\n');
		file = path;
		Thread.create(() -> while (true) {
			final s = try socket.accept() catch (_) return;
			post(() -> clients.push(new ApiClient(s, this)));
		});
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
			try Json.parse(line) catch (e) {
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
		final out = new RequestOutput(client, Reflect.field(request, "id"), post);
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
				(a == null) ? null : Std.isOfType(a, String) ? a : Json.stringify(a)
		];
		final ran = try dispatch(cmd, list, out) catch (e) {
			// a bug in a command must not end the client
			out.error('internal error: $e');
			false;
		}
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
	A connected program: a thread reads its lines, a thread writes (writes don't block the main thread).
**/
@:allow(norc.Api)
private class ApiClient {
	/** Queued to close the connection after the queued lines **/
	static final CLOSE = "\x00close";

	public var authenticated = false;

	final socket:Socket;
	final api:Api;
	final writes = new Deque<String>();
	var closed = false;

	function new(socket:Socket, api:Api) {
		this.socket = socket;
		this.api = api;
		Thread.create(readLoop);
		Thread.create(writeLoop);
	}

	public function send(line:String)
		if (!closed)
			writes.add(line);

	public function close() {
		if (closed)
			return;
		closed = true;
		writes.add(CLOSE);
		api.remove(this);
	}

	function readLoop() {
		while (true) {
			final line = try socket.input.readLine() catch (_) null;
			if (line == null)
				break;
			final l = line.endsWith("\r") ? line.substr(0, line.length - 1) : line;
			api.post(() -> if (!closed) api.receive(this, l));
		}
		api.post(close);
	}

	function writeLoop() {
		while (true) {
			final line = writes.pop(true);
			if (line == CLOSE)
				break;
			try
				socket.output.writeString(line + "\n")
			catch (_)
				break;
		}
		try
			socket.shutdown(true, true)
		catch (_) {};
		try
			socket.close()
		catch (_) {};
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

	public function new(client:ApiClient, id:Dynamic, post:(() -> Void)->Void) {
		this.client = client;
		this.id = id;
		this.post = post;
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
