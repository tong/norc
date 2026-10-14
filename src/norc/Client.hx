package norc;

import norc.Config.Account;
import norc.Output;
import norc.module.AdHoc;
import norc.module.Blocking;
import norc.module.Carbons;
import norc.module.ChatStates;
import norc.module.Corrections;
import norc.module.Contacts;
import norc.module.Discovery;
import norc.module.FileTransfers;
import norc.module.Messages;
import norc.module.Moods;
import norc.module.Pings;
import norc.module.Profile;
import norc.module.Receipts;
import norc.module.Time;
import norc.module.Tunes;
import norc.module.Upload;
import sys.FileSystem;
import sys.thread.Deque;
import sys.thread.Lock;
import sys.thread.Thread;
import xmpp.EntityCapabilities;
import xmpp.Jid;
import xmpp.Ping;
import xmpp.Message;
import xmpp.Presence;
import xmpp.XML;
import xmpp.Response;

using StringTools;

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

	/** The disconnected session, if the next one can resume it (stream management) **/
	var resumable:Null<Session>;

	/** Own presence, sent on login and with `/presence` **/
	var show:Null<Show>;
	var status:Null<String>;

	/** Creates the capabilities element of the current session **/
	var caps:Null<() -> XML>;

	final commands:Commands;

	/** External programs run on events (`<config dir>/hooks/on-<event>`) **/
	final hooks:Hooks;

	/** Socket interface for other programs, if enabled **/
	var api:Null<Api>;

	/** Features of the client, each with its commands and part of the session **/
	final modules = new Array<Module>();

	/** Failed connection attempts since the last login, for the reconnect delay **/
	var attempt = 0;

	/** Roster and presence subscriptions **/
	final contacts:Contacts;

	/** Chat messages, extended by other modules **/
	final messages:Messages;

	/** Last printed presence of each available full jid **/
	final presences = new Map<String, String>();

	/** State (`available`, `away`, …) of each available full jid, for the presence hook **/
	final states = new Map<String, String>();

	/** Time of the login, presences shortly after are the initial ones of the contacts **/
	var onlineSince = 0.0;

	/** Time of the last input of the user (commands from the terminal or api), for last activity requests **/
	var lastInput = Sys.time();

	/** The session was online (for the logout event) **/
	var wasOnline = false;

	var exitCode:Null<Int>;

	public function new(account:Account, password:String) {
		this.account = account;
		this.password = password;
		hooks = new Hooks(Config.configDir() + "/hooks", account.name, () -> session?.stream.jid ?? "", f -> events.add(Call(f)));
		commands = new Commands(online);
		commands.registerAll([
			{
				name: "presence",
				args: "[state] [status...]",
				description: "show or set your presence: available, chat, away, xa (extended away), dnd (busy), with a status message",
				run: (args, out) -> setPresence(args[0], args[1], out),
				complete: ["state" => _ -> ["available", "chat", "away", "xa", "dnd"]]
			},
			{
				name: "status",
				args: "[text...]",
				description: "show or set your status message, keeping the presence state (- clears it)",
				run: (args, out) -> setStatus(args[0], out)
			},
			{
				name: "xmpp-debug",
				args: "[state]",
				description: "print the XMPP stream: on (default) or off",
				run: (args, out) -> setDebug(args[0], out),
				complete: ["state" => _ -> ["on", "off"]]
			},
			{
				name: "config",
				description: "show the config of the account (values not saved marked with *)",
				run: (args, out) -> showConfig(out),
				subcommands: [
					{
						name: "save",
						description: "save the config of the account (e.g. options given on the command line)",
						run: (args, out) -> saveConfig(out)
					}
				]
			},
			{
				name: "reconnect",
				description: "close the connection and reconnect (resuming the session if possible), e.g. after a network change",
				online: true,
				run: (args, out) -> session.drop("reconnect")
			},
			{
				name: "quit",
				aliases: ["exit"],
				description: "disconnect and exit",
				exit: true,
				run: (args, out) -> quit()
			}
		]);
		contacts = new Contacts(emit, bare -> {
			// the presence of the first available resource
			for (jid => state in presences)
				if (Jid.parseBare(jid) == bare)
					return state;
			return null;
		});
		addModule(contacts);
		commands.completers.set("jid", _ -> contacts.completions());
		messages = new Messages(emit, contacts.resolve, contacts.name);
		addModule(messages);
		addModule(new Carbons(messages, account.carbons != false));
		addModule(new Receipts(messages, emit, contacts.name, contacts.seesPresence));
		addModule(new ChatStates(messages, emit, contacts.resolve, contacts.name, account.chatStates != false));
		addModule(new Profile(messages, emit, contacts.resolveOptional, contacts.name, contacts.nicknames));
		addModule(new Moods(messages, emit, contacts.name));
		addModule(new Tunes(messages, emit, contacts.name));
		addModule(new Time(contacts.resolveOptional, resourcesOf, account.entityTime == true));
		addModule(new AdHoc(contacts.resolveOptional));
		addModule(new Pings(contacts.resolveOptional, resourcesOf));
		addModule(new Corrections(messages));
		addModule(new Blocking(contacts.resolveOptional));
		addModule(new Discovery(contacts.resolveOptional, resourcesOf, account.lastActivity == true ? () -> Std.int(Sys.time() - lastInput) : null));
		addModule(new FileTransfers(account.downloadDir ?? Config.downloadDir(), emit, contacts.resolve, f -> events.add(Call(f)), resourcesOf));
		addModule(new Upload(messages, contacts.resolve, f -> events.add(Call(f))));
	}

	public function addModule(module:Module) {
		modules.push(module);
		commands.registerAll(module.commands());
	}

	/**
		Connects and processes events until the client quits; returns the exit code.
	**/
	public function run(interactive:Bool):Int {
		// regular checks, e.g. the keepalive of the session
		Thread.create(() -> while (true) {
			Sys.sleep(5);
			events.add(Call(() -> session?.tick()));
		});
		if (account.api == true) {
			final api = new Api((line, args, out) -> {
				lastInput = Sys.time();
				return (args == null) ? commands.run(line, out, false) : commands.call(line, args, out);
			}, f -> events.add(Call(f)));
			try {
				final host = account.apiHost ?? "127.0.0.1";
				api.start(Config.stateDir(account.name), host, account.apiPort ?? 0);
				this.api = api;
				Term.info('api: ${Config.stateDir(account.name)}/api');
				if (!host.startsWith("127.") && host != "localhost" && host != "::1")
					Term.error('warning: the api is reachable over the network ($host), unencrypted: '
						+ 'the token can be read from the traffic, giving control over the account');
			} catch (e)
				Term.error('cannot start the api: $e');
		}
		final editor = interactive ? LineEditor.start(account.prompt) : null;
		Term.editor = editor;
		if (editor != null)
			editor.complete = complete;
		connect();
		if (interactive)
			Thread.create(() -> readStdin(editor));
		while (exitCode == null)
			handle(events.pop(true));
		api?.stop();
		Term.editor = null;
		editor?.stop();
		return exitCode;
	}

	/** Completes the input of the editor (on the input thread): on the main thread, as the commands use its state **/
	function complete(before:String):Null<{word:String, candidates:Array<String>}> {
		var result = null;
		final lock = new Lock();
		events.add(Call(() -> {
			result = commands.complete(before);
			lock.release();
		}));
		// nothing if the main thread is busy
		return lock.wait(1) ? result : null;
	}

	function readStdin(editor:Null<LineEditor>) {
		final stdin = Sys.stdin();
		while (true) {
			final line = if (editor != null) editor.readLine() else try stdin.readLine() catch (_:haxe.io.Eof) null;
			if (line == null) {
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
				lastInput = Sys.time();
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
		final session = new Session(events, account, debug, resumable);
		this.session = session;
		session.manageStream();
		if (account.keepalive != null)
			session.keepalive = account.keepalive;
		// filter hooks: modify or drop stanzas
		session.filterSend = xml -> hooks.filter("stanza-send", xml, validStanza);
		session.filterRecv = xml -> hooks.filter("stanza-recv", xml, validStanza);
		final stream = session.stream;
		stream.onMessage = onMessage;
		stream.onPresence = onPresence;
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
			resumable = null;
			wasOnline = true;
			if (session.resumed) {
				// the server kept the roster, presences and subscriptions
				Term.info('online as ${stream.jid} (resumed)');
				emit("login", [stream.jid], {jid: stream.jid, resumed: true});
				return;
			}
			Term.info('online as ${stream.jid}');
			onlineSince = Sys.time();
			// the presences kept for resuming are sent again by the server
			presences.clear();
			states.clear();
			emit("login", [stream.jid], {jid: stream.jid, resumed: false});
			for (m in modules)
				m.online();
			sendPresence();
		}
		session.onError = (msg, retryable) -> {
			if (retryable) {
				Term.error(msg);
				errorEvent("connection", msg);
				this.session = null;
				if (session.resumable())
					resumable = session;
				retry();
			} else
				fatal("login", msg);
		}
		session.onStreamError = condition -> {
			// Another session took over this resource: reconnecting would take it back, endlessly
			if (condition == "conflict")
				fatal("stream", 'another client logged in as ${account.jid.node}@${account.jid.domain}/${account.resource}');
			else {
				Term.error('stream error: $condition');
				errorEvent("stream", condition);
			}
		}
		session.onClosed = (?msg) -> {
			this.session = null;
			resumable = (!quitting && session.resumable()) ? session : null;
			// kept if the session is resumed
			if (resumable == null) {
				presences.clear();
				states.clear();
			}
			for (m in modules)
				m.detach();
			if (quitting) {
				logout("quit", false);
				exit(0);
			} else {
				Term.error('disconnected' + (msg != null ? ': $msg' : ''));
				logout(msg ?? "", true);
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
		if (m.type == error) {
			final from = m.from != null ? Jid.parseBare(m.from) : account.jid.domain;
			final condition:Null<String> = m.error?.condition;
			Term.error('message error from $from' + describeError(m.error));
			errorEvent("message", condition ?? "error", {from: m.from ?? from});
			return;
		}
		messages.receive(m);
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
				presenceHook(p.from, p.show ?? "available", p.status);
				'$full is $state';
			case unavailable:
				// Ignore contacts which were not seen online (servers send these on login)
				if (!presences.exists(p.from))
					return;
				presences.remove(p.from);
				presenceHook(p.from, "offline", p.status);
				'$full is offline$status';
			case subscribe:
				contacts.request(p.from);
				emit("subscribe", [Jid.parseBare(p.from)], {from: p.from, name: who});
				'$who wants to see your presence: /roster accept ${Jid.parseBare(p.from)} or /roster deny ${Jid.parseBare(p.from)}';
			case subscribed:
				subscriptionEvent(p.from, "subscribed", who);
				'$who allowed you to see their presence';
			case unsubscribed:
				subscriptionEvent(p.from, "unsubscribed", who);
				'$who removed your presence subscription';
			case unsubscribe:
				subscriptionEvent(p.from, "unsubscribe", who);
				'$who unsubscribed from your presence';
			case error:
				Term.error('presence error from $full' + describeError(p.error));
				return;
			case _: return;
		}
		Term.println(Term.timestamp(Date.now()) + ' ' + Term.style(msg, 2));
	}

	function setPresence(state:Null<String>, status:Null<String>, out:Output) {
		if (state == null) {
			presenceData(out, () -> out.info('presence: ${describePresence()}' + (online() ? '' : ' (not connected)')));
			return;
		}
		switch state {
			case "available", "online":
				show = null;
			case _:
				final s = Show.fromString(state);
				if (s == null) {
					out.error('unknown presence: $state (available, chat, away, xa, dnd)');
					return;
				}
				show = s;
		}
		this.status = status;
		if (online())
			sendPresence();
		presenceData(out, () -> out.info('presence: ${describePresence()}' + (online() ? '' : ' (sent once connected)')));
	}

	function setStatus(text:Null<String>, out:Output) {
		if (text == null) {
			out.data({status: status, online: online()}, () -> out.info('status: ${status ?? "-"}' + (online() ? '' : ' (not connected)')));
			return;
		}
		status = (text == "-") ? null : text;
		if (online())
			sendPresence();
		presenceData(out, () -> out.info('presence: ${describePresence()}' + (online() ? '' : ' (sent once connected)')));
	}

	function presenceData(out:Output, show:() -> Void)
		out.data({state: (this.show : Null<String>) ?? "available", status: status, online: online()}, show);

	function sendPresence() {
		final presence = new Presence(show, status);
		if (caps != null)
			presence.properties.push(caps());
		session.stream.send(presence);
	}

	function describePresence():String
		return (show ?? "available") + (status != null ? ' ($status)' : '');

	function showConfig(out:Output) {
		final path = Config.accountPath(account.name);
		final exists = FileSystem.exists(path);
		final unsaved = try Config.unsaved(account) catch (e) {
			out.error(Std.string(e));
			[];
		}
		final values = Config.values(account);
		final map:haxe.DynamicAccess<Null<String>> = {};
		for (v in values)
			map.set(v.key, v.value);
		out.data({account: account.name, path: path, exists: exists, values: map, unsaved: unsaved}, () -> {
			out.print('account ${account.name}' + Term.style(exists ? ' ($path)' : ' (no config file: /config save creates $path)', 2));
			var width = 0;
			for (v in values)
				if (v.key.length > width)
					width = v.key.length;
			for (v in values)
				out.print('  ${v.key.rpad(" ", width + 2)}' + (v.value ?? Term.style("-", 2)) + (unsaved.contains(v.key) ? Term.style(" *", 33) : ""));
		});
	}

	function saveConfig(out:Output) {
		final unsaved = try Config.unsaved(account) catch (e) {
			out.error(Std.string(e));
			return;
		}
		final path = Config.accountPath(account.name);
		if (unsaved.length == 0 && FileSystem.exists(path)) {
			out.info('nothing to save, $path is up to date');
			return;
		}
		try {
			Config.storeAccount(account);
			out.info('saved $path' + (unsaved.length > 0 ? ': ${unsaved.join(", ")}' : ''));
		} catch (e)
			out.error('cannot save $path: $e');
	}

	function quit() {
		quitting = true;
		if (session == null)
			exit(0);
		else
			session.close();
	}

	function fatal(kind:String, msg:String) {
		Term.error(msg);
		errorEvent(kind, msg);
		logout(msg, false);
		quitting = true;
		resumable = null;
		session?.abort();
		exit(1);
	}

	/**
		The error event (`kind`: `connection`, `stream`, `login`, `message`).
		Not for failing hooks: a failing error hook would trigger itself.
	**/
	function errorEvent(kind:String, text:String, ?values:haxe.DynamicAccess<Dynamic>) {
		final v = values ?? {};
		v.set("kind", kind);
		v.set("text", text);
		emit("error", [kind, text], v);
	}

	/** The condition and text of a stanza error, e.g. `: remote-server-timeout: Server-to-server connection failed` **/
	static function describeError(e:Null<xmpp.Stanza.Error>):String {
		if (e == null)
			return '';
		final parts = [(e.condition : Null<String>), e.text].filter(v -> v != null && v.length > 0);
		return parts.length > 0 ? ': ${parts.join(": ")}' : '';
	}

	function subscriptionEvent(from:String, type:String, name:String)
		emit("subscription", [Jid.parseBare(from), type], {from: from, name: name, type: type});

	/** Output of a stanza filter hook: one well-formed element **/
	static function validStanza(xml:String):Bool
		return try {
			final x = Xml.parse(xml);
			[for (e in x.elements()) e].length == 1;
		} catch (_) false;

	/** An online session ended: the logout event (once per session) **/
	function logout(reason:String, reconnect:Bool) {
		if (!wasOnline)
			return;
		wasOnline = false;
		emit("logout", [reason], {reason: reason, reconnect: reconnect});
	}

	function setDebug(state:Null<String>, out:Output) {
		debug = switch state {
			case null, "on": true;
			case "off": false;
			case _:
				out.error('invalid state: $state (on or off)');
				return;
		}
		if (session != null)
			session.debug = debug;
		out.info('xmpp debug: ${debug ? "on" : "off"}');
	}

	/** The available full jids of a contact (bare jid) **/
	function resourcesOf(bare:String):Array<String>
		return [for (jid in presences.keys()) if (Jid.parseBare(jid) == bare) jid];

	function online():Bool
		return session != null && session.online;

	inline function exit(code:Int)
		exitCode = code;

	/** See `Module.Emit` **/
	function emit(event:String, args:Array<String>, values:haxe.DynamicAccess<Dynamic>) {
		hooks.run(event, args, values);
		api?.event(event, values);
	}

	function presenceHook(from:String, state:String, status:Null<String>) {
		final bare = Jid.parseBare(from);
		final previous = states.get(from) ?? "offline";
		if (state == "offline")
			states.remove(from);
		else
			states.set(from, state);
		// available resources of the contact after this change
		var resources = 0;
		for (jid in states.keys())
			if (Jid.parseBare(jid) == bare)
				resources++;
		emit("presence", [bare, state, status ?? ""], {
			from: from,
			name: displayName(bare),
			state: state,
			status: status,
			previous: previous,
			resources: resources,
			// the server sends the presences of all available contacts after the login
			initial: Sys.time() - onlineSince < 5
		});
	}

	inline function displayName(bare:String):String
		return contacts.name(bare);
}
