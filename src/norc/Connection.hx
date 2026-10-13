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
	/** How long to wait for data before checking for commands (seconds) **/
	static inline var POLL_INTERVAL = 0.02;

	final events:Deque<Event>;
	final commands = new Deque<Command>();

	public function new(events:Deque<Event>) {
		this.events = events;
	}

	public function open(host:String, port:Int) {
		Thread.create(() -> run(host, port));
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

	function run(hostname:String, port:Int) {
		final host = try new Host(hostname) catch (e) {
			post(ConnectFailed('cannot resolve $hostname'));
			return;
		}
		var socket = new Socket();
		try
			socket.connect(host, port)
		catch (e) {
			post(ConnectFailed('cannot connect to $hostname:$port: $e'));
			return;
		}
		socket.setBlocking(false);
		post(Connected);
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
