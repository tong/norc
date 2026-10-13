package norc;

import haxe.io.Bytes;
import sys.FileSystem;
import sys.io.File;
import sys.net.Host;
import sys.net.Socket;
import sys.thread.Deque;
import sys.thread.Thread;

using StringTools;

/**
	Socket interface for other programs: a TCP server (on `127.0.0.1` by default), one line per request and reply.

	The address and a random token are written to `<state dir>/api` (`host = …`, `port = …`, `token = …`, readable only
	by the user).
	A client authenticates with `auth <token>`, then sends commands as in the REPL (the `/` is optional),
	optionally prefixed with `@<id>` to tag the replies.

	Replies and events are lines of a type and `key=value` pairs (values with spaces, quotes or `\` are quoted, with
	`\"`, `\\`, `\n`, `\r`, `\t` escapes):

		→ auth 4f3a…
		← ok
		→ @1 roster
		← out id=1 text="Alice <alice@example.org> [both]"
		← ok id=1
		→ @2 msg nobody hi
		← error id=2 text="invalid jid: nobody"
		← message from=alice@example.org/phone name=Alice body="hi there" type=chat delayed=0

	Each request is answered with `ok` or `error` once it ran; its output comes before (`out`, `info`), output of
	asynchronous results (e.g. responses of the server) after, with the same id.
	Events (the same as for hooks) are sent to all authenticated clients.
**/
@:allow(norc)
class Api {
	final post:(() -> Void)->Void;
	final dispatch:(line:String, out:Output) -> Bool;
	final clients = new Array<ApiClient>();

	var server:Null<Socket>;
	var file:Null<String>;
	var token = "";

	/**
		`dispatch` runs a command line (`/` optional), returns `false` if it could not run.
		`post` runs a callback on the main thread.
	**/
	public function new(dispatch:(line:String, out:Output) -> Bool, post:(() -> Void)->Void) {
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
	public function event(name:String, values:Map<String, String>) {
		final keys = [for (k in values.keys()) k];
		keys.sort(Reflect.compare);
		final line = format(name, [for (k in keys) {key: k, value: values.get(k)}]);
		for (c in clients)
			if (c.authenticated)
				c.send(line);
	}

	function receive(client:ApiClient, line:String) {
		if (!client.authenticated) {
			if (line.startsWith("auth ") && equals(line.substr(5).trim(), token)) {
				client.authenticated = true;
				client.send("ok");
			} else {
				client.send(format("error", [{key: "text", value: "not authorized"}]));
				client.close();
			}
			return;
		}
		var id:Null<String> = null;
		if (line.startsWith("@")) {
			final i = line.indexOf(" ");
			id = line.substring(1, i == -1 ? line.length : i);
			line = (i == -1) ? "" : line.substr(i + 1);
		}
		final out = new RequestOutput(client, id);
		final ran = dispatch(line, out);
		out.done = true;
		// the result: an error already sent, or ok
		if (ran && !out.failed)
			client.send(format("ok", id != null ? [{key: "id", value: id}] : []));
		else if (!out.failed)
			client.send(format("error", (id != null ? [{key: "id", value: id}] : []).concat([{key: "text", value: "failed"}])));
	}

	function remove(client:ApiClient)
		clients.remove(client);

	/** A line: `type key=value …` **/
	public static function format(type:String, values:Array<{key:String, value:String}>):String {
		final b = new StringBuf();
		b.add(type);
		for (v in values) {
			b.add(' ${v.key}=');
			b.add(quote(v.value ?? ""));
		}
		return b.toString();
	}

	static function quote(value:String):String {
		if (value.length > 0 && !~/[\s"\\=]/.match(value))
			return value;
		return '"' + value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t") + '"';
	}

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

/** Output of a request: lines tagged with its id **/
private class RequestOutput implements Output {
	/** An error was sent while the command ran (it is the result) **/
	public var failed = false;

	/** The command returned: later output is asynchronous **/
	public var done = false;

	final client:ApiClient;
	final id:Null<String>;

	public function new(client:ApiClient, id:Null<String>) {
		this.client = client;
		this.id = id;
	}

	public function print(text:String)
		send("out", text);

	public function info(text:String)
		send("info", text);

	public function error(text:String) {
		if (!done)
			failed = true;
		send("error", text);
	}

	function send(type:String, text:String) {
		// without colors
		text = ~/\x1B\[[0-9;]*m/g.replace(text, "");
		client.send(Api.format(type, (id != null ? [{key: "id", value: id}] : []).concat([{key: "text", value: text}])));
	}
}
