package norc;

import norc.Config.Account;
import norc.Event;
import sys.thread.Deque;
import xmpp.Ping;
import xmpp.Presence;
import xmpp.StreamManagement;
import xmpp.XML;
import xmpp.client.Authentication;
import xmpp.client.Stream;

using StringTools;
using xmpp.StartTLS;
using xmpp.client.Authentication;

/**
	One connection to the server: connects, secures the stream with TLS and optionally logs in.

	Network events are posted to the owner's event queue; the owner passes those of this session
	(`owns`) to `handle` on its main thread.
	A session is not reused: create a new one to reconnect, or to log in after registering an account.
	With stream management (`manageStream`), a new session can resume the previous one after a disconnection.
**/
class Session {
	public final stream:Stream;
	public var online(default, null) = false;

	/** Stream management (acknowledgements and resumption, XEP-0198), if enabled with `manageStream` **/
	public var sm(default, null):Null<StreamManagement>;

	/** Online by resuming the previous session: the server kept the roster, presences and pending stanzas **/
	public var resumed(default, null) = false;

	final account:Account;
	final conn:Connection;

	/** Print the XMPP stream (passwords hidden) **/
	public var debug:Bool;

	/** Print status messages (connecting) **/
	public var verbose = true;

	/** The host and port connected to, once connected **/
	public var address(default, null):Null<{host:String, port:Int}>;

	var failed = false;

	/** Seconds without received data before pinging the server, `0` to disable (call `tick` regularly) **/
	public var keepalive = 60.0;

	/** Seconds to wait for data after a ping before closing the connection **/
	public static inline var PING_TIMEOUT = 30.0;

	var lastReceived = Sys.time();
	var pingSent:Null<Float>;

	/** Why the session closed the connection itself, passed to `onClosed` **/
	var closeReason:Null<String>;

	/**
		Filters of the stanzas (`message`, `presence`, `iq`) sent and received after the login:
		return the stanza to use, or `null` to drop it.
	**/
	public var filterSend:Null<String->Null<String>>;

	public var filterRecv:Null<String->Null<String>>;

	/** The stream is secured with TLS: `login`, or use it unauthenticated (e.g. to register) **/
	public dynamic function onSecured(features:XML) {}

	/** Logged in, the resource is bound **/
	public dynamic function onOnline() {}

	/**
		The session failed: the connection could not be established (`retry` is `true`),
		or TLS or the login failed. The connection is closed, no `onClosed` follows.
	**/
	public dynamic function onError(msg:String, retry:Bool) {}

	/** The server sent a stream error (e.g. `conflict`); the stream is closed afterwards **/
	public dynamic function onStreamError(condition:String)
		Term.error('stream error: $condition');

	/** The connection was closed (by `close`, the server or a network error) **/
	public dynamic function onClosed(?msg:String) {}

	/**
		With `previous` (a disconnected session with a resumable stream, see `resumable`) the new session resumes it.
	**/
	public function new(events:Deque<Event>, account:Account, debug = false, ?previous:Session) {
		this.account = account;
		this.debug = debug;
		conn = new Connection(events);
		stream = previous?.stream ?? new Stream(account.jid.domain);
		sm = previous?.sm;
		stream.output = str -> {
			if (online && filterSend != null && isStanza(str)) {
				final filtered = filterSend(str);
				if (filtered == null)
					return;
				str = filtered;
			}
			log(str, true);
			conn.send(str);
		}
		stream.onEnd = () -> {
			// The server closed the stream: close ours too
			stream.end();
			conn.close();
		}
		stream.onNonza = xml -> {
			if (xml.name == "stream:error")
				onStreamError(streamError(xml));
			return false;
		}
	}

	/** Enables stream management after the login (if the server offers it): stanzas are acknowledged, the session can be resumed **/
	public function manageStream()
		if (sm == null)
			sm = new StreamManagement(stream);

	/** The session can be resumed by a new one (see `new`) **/
	public function resumable():Bool
		return sm?.id != null;

	public function open() {
		// without host: the hosts of the SRV records of the domain
		final host = account.host ?? account.jid.domain;
		if (verbose)
			Term.info('connecting to $host' + (account.host != null ? ':${account.port}' : ''));
		conn.open(host, account.port, account.host == null);
	}

	public inline function owns(c:Connection):Bool
		return c == conn;

	public function handle(e:NetEvent) {
		switch e {
			case Connected(host, port):
				address = {host: host, port: port};
				stream.start(features -> {
					// Never authenticate (or register) without TLS
					if (!StartTLS.isOffered(features)) {
						fail("server does not offer TLS");
						return;
					}
					stream.startTLS(ok -> {
						if (ok)
							conn.startTls(account.jid.domain);
						else
							fail("server refused TLS");
					});
				});
			case ConnectFailed(msg):
				onError(msg, true);
			case Data(bytes):
				lastReceived = Sys.time();
				pingSent = null;
				if (debug)
					log(bytes.toString(), false);
				stream.recvBytes(bytes);
			case TlsReady:
				stream.start(onSecured);
			case TlsFailed(msg):
				onError('TLS handshake failed: $msg', false);
			case Disconnected(msg):
				online = false;
				if (!failed)
					onClosed(closeReason ?? msg);
		}
	}

	/**
		Logs in with the features received on the secured stream (`onSecured`).
	**/
	public function login(password:String, features:XML) {
		// PLAIN is acceptable since the stream is secured with TLS
		final mechanism = Authentication.selectMechanism(features, true);
		if (mechanism == null) {
			fail('no supported authentication mechanism: ${Authentication.getMechanisms(features).join(", ")}');
			return;
		}
		if (resumable()) {
			resume(password, mechanism);
			return;
		}
		stream.authenticate(account.jid.node, account.resource, password, mechanism, (?error) -> {
			if (error != null) {
				fail('login failed: ${Term.errorText(error)}');
				return;
			}
			enableStreamManagement();
			goOnline();
		});
	}

	/**
		Authenticates and resumes the previous session; if it can not be resumed (e.g. expired), binds the resource
		for a new session and resends the messages the server did not acknowledge.
	**/
	function resume(password:String, mechanism:sasl.Mechanism) {
		Authentication.saslAuthentication(stream, account.jid.node, password, mechanism, (?error, _) -> {
			if (error != null) {
				fail('login failed: ${Term.errorText(error)}');
				return;
			}
			sm.resume((?error, ?unacked) -> {
				if (error == null) {
					resumed = true;
					goOnline();
					return;
				}
				Authentication.bindResource(stream, account.resource, (?error, _) -> {
					if (error != null) {
						fail('resource binding failed: ${error.condition}');
						return;
					}
					enableStreamManagement();
					goOnline();
					for (stanza in unacked ?? [])
						if (stanza.name == "message")
							stream.send(stanza);
				});
			});
		});
	}

	function enableStreamManagement()
		if (sm != null && StreamManagement.isOffered(stream.serverFeatures))
			sm.enable(true, null, (?error) -> if (error != null) Term.info('stream management not available: ${error.condition}'));

	function goOnline() {
		online = true;
		// received stanzas pass the filter (complete units, after the login)
		final input = stream.input;
		stream.input = str -> {
			if (filterRecv != null && isStanza(str)) {
				final filtered = filterRecv(str);
				if (filtered == null)
					return;
				str = filtered;
			}
			input(str);
		}
		onOnline();
	}

	/**
		Keepalive: pings the server after `keepalive` seconds without received data, and closes the connection
		if nothing is received within `PING_TIMEOUT` after the ping (e.g. a dead connection after a network change).
	**/
	public function tick() {
		if (!online || keepalive <= 0 || closeReason != null)
			return;
		final now = Sys.time();
		if (pingSent != null) {
			if (now - pingSent >= PING_TIMEOUT) {
				closeReason = 'no response from the server for ${Std.int(now - lastReceived)}s';
				conn.close();
			}
		} else if (now - lastReceived >= keepalive) {
			pingSent = now;
			// any data received counts as answer
			Ping.ping(stream, stream.domain);
		}
	}

	/** Ends the stream (going offline first) and closes the connection **/
	public function close() {
		if (online)
			stream.send(new Presence(null, null, null, unavailable));
		stream.end();
		conn.close();
	}

	/** Closes the connection without ending the stream **/
	public function abort()
		conn.close();

	/** Closes the connection without ending the stream, e.g. to reconnect and resume the session **/
	public function drop(reason:String) {
		closeReason = reason;
		conn.close();
	}

	function fail(msg:String) {
		failed = true;
		conn.close();
		onError(msg, false);
	}

	function log(str:String, out:Bool) {
		if (!debug)
			return;
		// Don't log credentials
		if (out && (str.startsWith("<auth ") || str.contains("<password")))
			str = str.substr(0, str.indexOf(">") + 1) + "…";
		final pretty = try xmpp.xml.Printer.print(str, true) catch (_) str;
		Term.println(Term.style(pretty.trim(), out ? 32 : 33), true);
	}

	static function isStanza(str:String):Bool
		return str.startsWith("<message") || str.startsWith("<presence") || str.startsWith("<iq");

	static function streamError(xml:XML):String {
		for (e in xml.elements)
			if (e.name != "text")
				return e.name;
		return "unknown";
	}
}
