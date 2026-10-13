package norc;

import norc.Config.Account;
import sys.thread.Deque;
import sys.thread.Thread;
import xmpp.EntityCapabilities;
import xmpp.Jid;
import xmpp.Ping;
import xmpp.Message;
import xmpp.Presence;
import xmpp.XML;
import xmpp.Response;
import xmpp.client.Roster;

using StringTools;
using xmpp.DelayedDelivery;
using xmpp.client.Roster;

/**
	XMPP client session of one account.

	Runs the event loop on the main thread: everything touching the stream or the client state
	happens here, input threads (network, stdin, timers) only post events.
**/
class Client {
	/** Identifies norc in its capabilities (XEP-0115) **/
	static inline var NODE = "https://github.com/tong/norc";

	/** Seconds to wait before reconnect attempts **/
	static final BACKOFF = [1, 2, 5, 10, 30, 60];

	public var debug = false;

	final account:Account;
	final password:String;
	final events = new Deque<Event>();

	var session:Null<Session>;
	var quitting = false;

	/** Own presence, sent on login and with `/presence` **/
	var show:Null<Show>;
	var status:Null<String>;

	/** Creates the capabilities element of the current session **/
	var caps:Null<() -> XML>;

	final commands:Commands;

	/** Features of the client, each with its commands and part of the session **/
	final modules = new Array<Module>();
	var attempt = 0;
	var roster = new Array<RosterItem>();

	/** Last printed presence of each available full jid **/
	var presences = new Map<String, String>();

	var exitCode:Null<Int>;

	public function new(account:Account, password:String) {
		this.account = account;
		this.password = password;
		commands = new Commands(online);
		commands.registerAll([
			{
				name: "msg",
				args: "<jid> <text...>",
				description: "send a message (\\n for a newline)",
				online: true,
				run: args -> sendMessage(args[0], args[1].replace("\\n", "\n"))
			},
			{
				name: "presence",
				args: "[state] [status...]",
				description: "show or set your presence: available, chat, away, xa (extended away), dnd (busy), with a status message",
				run: args -> setPresence(args[0], args[1])
			},
			{
				name: "roster",
				description: "list contacts",
				run: args -> printRoster()
			},
			{
				name: "quit",
				aliases: ["exit"],
				description: "disconnect and exit",
				exit: true,
				run: args -> quit()
			}
		]);
		addModule(new FileTransfers(account.downloadDir ?? Config.downloadDir(), f -> events.add(Call(f)), bare -> [
			for (jid in presences.keys())
				if (Jid.parseBare(jid) == bare) jid
		]));
	}

	public function addModule(module:Module) {
		modules.push(module);
		commands.registerAll(module.commands());
	}

	/**
		Connects and processes events until the client quits; returns the exit code.
	**/
	public function run(interactive:Bool):Int {
		connect();
		if (interactive)
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
			// Stop reading: exit() waits for the lock of stdin, held while a read blocks
			if (commands.exits(line))
				return;
		}
	}

	function handle(e:Event) {
		switch e {
			case Net(c, e):
				if (session != null && session.owns(c))
					session.handle(e);
			case Line(line):
				commands.run(line);
			case InputClosed:
			case Reconnect:
				if (session == null && !quitting)
					connect();
			case Call(f):
				f();
		}
	}

	function connect() {
		final session = new Session(events, account, debug);
		this.session = session;
		final stream = session.stream;
		stream.onMessage = onMessage;
		stream.onPresence = onPresence;
		Roster.handleRequests(stream, (item, ver) -> rosterPush(item));
		Ping.handleRequests(stream);
		final features = new Array<String>();
		for (m in modules) {
			m.attach(stream);
			for (f in m.features())
				features.push(f);
		}
		// after all request handlers are registered: the features are part of the capabilities
		caps = EntityCapabilities.handleRequests(stream, {category: "client", type: "console", name: "norc"}, NODE, features);
		session.onSecured = features -> session.login(password, features);
		session.onOnline = () -> {
			attempt = 0;
			Term.info('online as ${stream.jid}');
			for (m in modules)
				m.online();
			stream.loadRoster(res -> switch res {
				case Result(payload):
					roster = Roster.parseRoster(payload).items;
				case Error(e):
					Term.error('cannot load roster: ${e.condition}');
			});
			sendPresence();
		}
		session.onError = (msg, retryable) -> {
			if (retryable) {
				Term.error(msg);
				this.session = null;
				retry();
			} else
				fatal(msg);
		}
		session.onStreamError = condition -> {
			// Another session took over this resource: reconnecting would take it back, endlessly
			if (condition == "conflict")
				fatal('another client logged in as ${account.jid.node}@${account.jid.domain}/${account.resource}');
			else
				Term.error('stream error: $condition');
		}
		session.onClosed = (?msg) -> {
			this.session = null;
			presences.clear();
			for (m in modules)
				m.detach();
			if (quitting) {
				exit(0);
			} else {
				Term.error('disconnected' + (msg != null ? ': $msg' : ''));
				retry();
			}
		}
		session.open();
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
				if (p.from == session?.stream.jid)
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

	function sendMessage(to:String, body:String) {
		if (!Jid.isValid(to)) {
			Term.error('invalid jid: $to');
			return;
		}
		session.stream.send(new Message(to, body));
	}

	function setPresence(state:Null<String>, status:Null<String>) {
		if (state == null) {
			Term.info('presence: ${describePresence()}' + (online() ? '' : ' (not connected)'));
			return;
		}
		switch state {
			case "available", "online":
				show = null;
			case _:
				final s = Show.fromString(state);
				if (s == null) {
					Term.error('unknown presence: $state (available, chat, away, xa, dnd)');
					return;
				}
				show = s;
		}
		this.status = status;
		if (online())
			sendPresence();
		Term.info('presence: ${describePresence()}' + (online() ? '' : ' (sent once connected)'));
	}

	function sendPresence() {
		final presence = new Presence(show, status);
		if (caps != null)
			presence.properties.push(caps());
		session.stream.send(presence);
	}

	function describePresence():String
		return (show ?? "available") + (status != null ? ' ($status)' : '');

	function printRoster() {
		if (roster.length == 0)
			Term.info("roster is empty");
		for (item in roster)
			Sys.println('  ${item.jid}' + (item.name != null ? ' (${item.name})' : '') + Term.style(' [${item.subscription ?? "none"}]', 2));
	}

	function quit() {
		quitting = true;
		if (session == null)
			exit(0);
		else
			session.close();
	}

	function fatal(msg:String) {
		Term.error(msg);
		quitting = true;
		session?.abort();
		exit(1);
	}

	function online():Bool
		return session != null && session.online;

	inline function exit(code:Int)
		exitCode = code;

	function displayName(bare:String):String {
		for (item in roster)
			if (item.jid == bare && item.name != null)
				return item.name;
		return bare;
	}

	static function timestamp(date:Date):String {
		final now = Date.now();
		final today = date.getFullYear() == now.getFullYear() && date.getMonth() == now.getMonth() && date.getDate() == now.getDate();
		return DateTools.format(date, today ? "%H:%M" : "%Y-%m-%d %H:%M");
	}
}
