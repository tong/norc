package norc;

import norc.Config.Account;
import norc.Event;
import sys.thread.Deque;
import sys.thread.Thread;
import xmpp.Jid;
import xmpp.Message;
import xmpp.Presence;
import xmpp.Response;
import xmpp.XML;
import xmpp.client.Authentication;
import xmpp.client.Roster;
import xmpp.client.Stream;

using StringTools;
using xmpp.DelayedDelivery;
using xmpp.StartTLS;
using xmpp.client.Authentication;
using xmpp.client.Roster;

/**
	XMPP client session of one account.

	Runs the event loop on the main thread: everything touching the stream or the client state
	happens here, input threads (network, stdin, timers) only post events.
**/
class Client {
	/** Seconds to wait before reconnect attempts **/
	static final BACKOFF = [1, 2, 5, 10, 30, 60];

	public var debug = false;

	final account:Account;
	final password:String;
	final events = new Deque<Event>();

	var conn:Null<Connection>;
	var stream:Null<Stream>;
	var online = false;
	var quitting = false;
	var attempt = 0;
	var roster = new Array<RosterItem>();

	/** Last printed presence of each available full jid **/
	var presences = new Map<String, String>();
	var exitCode:Null<Int>;

	public function new(account:Account, password:String) {
		this.account = account;
		this.password = password;
	}

	/**
		Connects and processes events until the client quits; returns the exit code.
	**/
	public function run(readInput:Bool):Int {
		connect();
		if (readInput)
			Thread.create(readStdin);
		while (exitCode == null)
			handle(events.pop(true));
		return exitCode;
	}

	function readStdin() {
		final stdin = Sys.stdin();
		while (true) {
			final line = try stdin.readLine() catch (_:haxe.io.Eof) {
				events.add(InputClosed);
				return;
			}
			events.add(Line(line));
		}
	}

	function handle(e:Event) {
		switch e {
			case Net(c, e):
				if (c == conn)
					handleNet(e);
			case Line(line):
				command(line);
			case InputClosed:
			case Reconnect:
				if (conn == null && !quitting)
					connect();
		}
	}

	function handleNet(e:NetEvent) {
		switch e {
			case Connected:
				startStream();
			case ConnectFailed(msg):
				Term.error(msg);
				conn = null;
				retry();
			case Data(str):
				log(str, false);
				stream.recv(str);
			case TlsReady:
				stream.start(login);
			case TlsFailed(msg):
				fatal('TLS handshake failed: $msg');
			case Disconnected(msg):
				conn = null;
				stream = null;
				online = false;
				presences.clear();
				if (quitting) {
					exit(0);
				} else {
					Term.error('disconnected' + (msg != null ? ': $msg' : ''));
					retry();
				}
		}
	}

	function connect() {
		final host = account.host ?? account.jid.domain;
		Term.info('connecting to $host:${account.port}');
		conn = new Connection(events);
		conn.open(host, account.port);
	}

	function retry() {
		if (quitting)
			return;
		final delay = BACKOFF[attempt < BACKOFF.length ? attempt : BACKOFF.length - 1];
		attempt++;
		Term.info('reconnecting in ${delay}s');
		Thread.create(() -> {
			Sys.sleep(delay);
			events.add(Reconnect);
		});
	}

	function startStream() {
		final s = new Stream(account.jid.domain);
		stream = s;
		s.output = str -> {
			log(str, true);
			conn.send(str);
		}
		s.onMessage = onMessage;
		s.onPresence = onPresence;
		s.onEnd = () -> {
			// The server closed the stream: close ours too
			s.end();
			conn?.close();
		}
		s.onNonza = xml -> {
			if (xml.name == "stream:error") {
				final condition = streamError(xml);
				// Another session took over this resource: reconnecting would take it back, endlessly
				if (condition == "conflict")
					fatal('another client logged in as ${account.jid.node}@${account.jid.domain}/${account.resource}');
				else
					Term.error('stream error: $condition');
			}
			return false;
		}
		Roster.handleRequests(s, (item, ver) -> rosterPush(item));
		s.start(features -> {
			// Never authenticate without TLS
			if (!StartTLS.isOffered(features)) {
				fatal("server does not offer TLS");
				return;
			}
			s.startTLS(ok -> {
				if (ok)
					conn.startTls(account.jid.domain);
				else
					fatal("server refused TLS");
			});
		});
	}

	function login(features:XML) {
		// PLAIN is acceptable since the stream is secured with TLS
		final mechanism = Authentication.selectMechanism(features, true);
		if (mechanism == null) {
			fatal('no supported authentication mechanism: ${Authentication.getMechanisms(features).join(", ")}');
			return;
		}
		stream.authenticate(account.jid.node, account.resource, password, mechanism, (?error) -> {
			if (error != null) {
				fatal('login failed: ${error.condition}' + (error.text != null ? ' (${error.text})' : ''));
				return;
			}
			online = true;
			attempt = 0;
			Term.info('online as ${stream.jid}');
			stream.loadRoster(res -> switch res {
				case Result(payload):
					roster = Roster.parseRoster(payload).items;
				case Error(e):
					Term.error('cannot load roster: ${e.condition}');
			});
			stream.send(new Presence());
		});
	}

	function onMessage(m:Message) {
		final from = m.from != null ? Jid.parseBare(m.from) : account.jid.domain;
		if (m.type == error) {
			Term.error('message error from $from');
			return;
		}
		if (m.body == null)
			return;
		final delay = m.delay();
		final date = delay?.date ?? Date.now();
		final lines = m.body.split("\n");
		final prefix = '${timestamp(date)} ' + Term.style('<${displayName(from)}>', 36) + ' ';
		Sys.println(prefix + lines[0]);
		for (i in 1...lines.length)
			Sys.println(StringTools.lpad("", " ", timestamp(date).length + displayName(from).length + 4) + lines[i]);
	}

	function onPresence(p:Presence) {
		if (p.from == null)
			return;
		final who = displayName(Jid.parseBare(p.from));
		final res = Jid.parseResource(p.from);
		final full = res != null ? '$who/$res' : who;
		final status = p.status != null ? ' (${p.status})' : '';
		final msg = switch p.type {
			case null:
				if (p.from == stream.jid)
					return;
				final state = '${p.show ?? "available"}$status';
				// Only print changes
				if (presences.get(p.from) == state)
					return;
				presences.set(p.from, state);
				'$full is $state';
			case unavailable:
				// Ignore contacts which were not seen online (servers send these on login)
				if (!presences.exists(p.from))
					return;
				presences.remove(p.from);
				'$full is offline$status';
			case subscribe: '$who wants to subscribe to your presence';
			case subscribed: '$who allowed you to see their presence';
			case unsubscribed: '$who removed your presence subscription';
			case unsubscribe: '$who unsubscribed from your presence';
			case error: 'presence error from $full';
			case _: return;
		}
		Sys.println(timestamp(Date.now()) + ' ' + Term.style(msg, 2));
	}

	function rosterPush(item:RosterItem) {
		roster = roster.filter(i -> i.jid != item.jid);
		if (item.subscription != remove)
			roster.push(item);
	}

	function command(line:String) {
		line = line.trim();
		if (line.length == 0)
			return;
		if (!line.startsWith("/")) {
			Term.error("use /msg <jid> <text> to send a message (/help for commands)");
			return;
		}
		final i = line.indexOf(" ");
		final cmd = i == -1 ? line.substr(1) : line.substring(1, i);
		final args = i == -1 ? "" : line.substr(i + 1).trim();
		switch cmd {
			case "msg":
				final j = args.indexOf(" ");
				if (j == -1) {
					Term.error("usage: /msg <jid> <text>");
					return;
				}
				final to = args.substr(0, j);
				final body = args.substr(j + 1).replace("\\n", "\n");
				if (!Jid.isValid(to)) {
					Term.error('invalid jid: $to');
					return;
				}
				if (!online) {
					Term.error("not connected");
					return;
				}
				stream.send(new Message(to, body));
			case "roster":
				if (roster.length == 0)
					Term.info("roster is empty");
				for (item in roster)
					Sys.println('  ${item.jid}' + (item.name != null ? ' (${item.name})' : '') + Term.style(' [${item.subscription ?? "none"}]', 2));
			case "quit":
				quit();
			case "help":
				Sys.println("  /msg <jid> <text>   send a message (\\n for a newline)\n  /roster            list contacts\n  /quit              disconnect and exit");
			case _:
				Term.error('unknown command: /$cmd');
		}
	}

	function quit() {
		quitting = true;
		if (conn == null) {
			exit(0);
			return;
		}
		if (stream != null) {
			if (online)
				stream.send(new Presence(null, null, null, unavailable));
			stream.end();
		}
		conn.close();
	}

	function fatal(msg:String) {
		Term.error(msg);
		quitting = true;
		conn?.close();
		exit(1);
	}

	inline function exit(code:Int)
		exitCode = code;

	function displayName(bare:String):String {
		for (item in roster)
			if (item.jid == bare && item.name != null)
				return item.name;
		return bare;
	}

	function log(str:String, out:Bool) {
		if (!debug)
			return;
		// Don't log credentials
		if (out && str.startsWith("<auth "))
			str = str.substr(0, str.indexOf(">") + 1) + "…</auth>";
		final pretty = try xmpp.xml.Printer.print(str, true) catch (_) str;
		Sys.stderr().writeString(Term.style(pretty.trim(), out ? 32 : 33) + "\n");
	}

	static function streamError(xml:XML):String {
		for (e in xml.elements)
			if (e.name != "text")
				return e.name;
		return "unknown";
	}

	static function timestamp(date:Date):String {
		final now = Date.now();
		final today = date.getFullYear() == now.getFullYear() && date.getMonth() == now.getMonth() && date.getDate() == now.getDate();
		return DateTools.format(date, today ? "%H:%M" : "%Y-%m-%d %H:%M");
	}
}
