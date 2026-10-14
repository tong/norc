package norc;

import haxe.io.Bytes;
import haxe.io.Error;
import norc.Event;
import sys.net.Host;
import sys.net.Socket;
import sys.thread.Deque;
import sys.thread.Thread;

private enum Command {
	Send(str:String);
	StartTls(servername:String);
	Close;
}

/**
	A TCP connection to the server, run by its own thread.

	All socket (and TLS) operations happen on that thread, since a TLS context must not be used
	by several threads at once: the main thread only posts commands, received data and state
	changes are posted back as `Event.Net`.
**/
class Connection {
	/** Seconds to wait for a connection to a host **/
	static inline var CONNECT_TIMEOUT = 10.0;

	/** How long to wait for data before checking for commands (seconds) **/
	static inline var POLL_INTERVAL = 0.02;

	final events:Deque<Event>;
	final commands = new Deque<Command>();

	public function new(events:Deque<Event>) {
		this.events = events;
	}

	/**
		Connects to `host:port`; with `srv`, to the hosts of the SRV records of the domain `host`
		(`_xmpp-client._tcp`) in their order, and `host:port` if there are none.
	**/
	public function open(host:String, port:Int, srv = false) {
		Thread.create(() -> {
			final records = srv ? Dns.srv('_xmpp-client._tcp.$host') : [];
			final targets = (records.length > 0) ? [for (r in records) {host: r.target, port: r.port}] : [{host: host, port: port}];
			run(targets);
		});
	}

	public function send(str:String)
		commands.add(Send(str));

	/** Upgrade the connection to TLS, verifying the certificate for `servername` **/
	public function startTls(servername:String)
		commands.add(StartTls(servername));

	/** Close the connection after all pending data has been sent **/
	public function close()
		commands.add(Close);

	inline function post(e:NetEvent)
		events.add(Net(this, e));

	/** Connects to the first reachable target, then sends and receives until closed **/
	function run(targets:Array<{host:String, port:Int}>) {
		var socket:Null<Socket> = null;
		var host:Null<Host> = null;
		final errors = [];
		for (t in targets) {
			final h = try new Host(t.host) catch (e) {
				errors.push('cannot resolve ${t.host}');
				continue;
			}
			final s = new Socket();
			try {
				s.setTimeout(CONNECT_TIMEOUT);
				s.connect(h, t.port);
			} catch (e) {
				s.close();
				errors.push('cannot connect to ${t.host}:${t.port}: $e');
				continue;
			}
			socket = s;
			host = h;
			post(Connected(t.host, t.port));
			break;
		}
		if (socket == null) {
			post(ConnectFailed(errors.join(", ")));
			return;
		}
		socket.setBlocking(false);
		final buf = Bytes.alloc(16384);
		while (true) {
			var cmd:Null<Command>;
			while ((cmd = commands.pop(false)) != null) {
				switch cmd {
					case Send(str):
						final error = write(socket, Bytes.ofString(str));
						if (error != null) {
							socket.close();
							post(Disconnected(error));
							return;
						}
					case StartTls(servername):
						try {
							socket.setBlocking(true);
							final tls = xmpp.StartTLS.upgrade(socket, host, servername);
							tls.handshake();
							tls.setBlocking(false);
							socket = tls;
						} catch (e) {
							socket.close();
							post(TlsFailed(Std.string(e)));
							return;
						}
						post(TlsReady);
					case Close:
						socket.close();
						post(Disconnected());
						return;
				}
			}
			if (Socket.select([socket], [], [], POLL_INTERVAL).read.length == 0)
				continue;
			// Read everything available, including data buffered by the TLS layer
			while (true) {
				final len = try socket.input.readBytes(buf, 0, buf.length) catch (e:Error) {
					if (e == Blocked)
						break;
					socket.close();
					post(Disconnected(Std.string(e)));
					return;
				} catch (e:haxe.io.Eof) {
					socket.close();
					post(Disconnected("connection closed by server"));
					return;
				} catch (e) {
					socket.close();
					post(Disconnected(Std.string(e)));
					return;
				}
				if (len == 0) {
					socket.close();
					post(Disconnected("connection closed by server"));
					return;
				}
				post(Data(buf.sub(0, len)));
			}
		}
	}

	/** Writes all bytes to the non-blocking socket, returns an error message on failure **/
	static function write(socket:Socket, bytes:Bytes):Null<String> {
		var pos = 0;
		while (pos < bytes.length) {
			try
				pos += socket.output.writeBytes(bytes, pos, bytes.length - pos)
			catch (e:Error) {
				if (e != Blocked)
					return Std.string(e);
				Sys.sleep(0.005);
			} catch (e) {
				return Std.string(e);
			}
		}
		return null;
	}
}
