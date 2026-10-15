package norc;

import norc.Config.Account;
import norc.Module;
import norc.Output;
import norc.module.AdHoc;
import norc.module.Avatars;
import norc.module.Blocking;
import norc.module.Buzz;
import norc.module.Calls;
import norc.module.Carbons;
import norc.module.ChatStates;
import norc.module.Corrections;
import norc.module.Contacts;
import norc.module.Discovery;
import norc.module.FileTransfers;
import norc.module.History;
import norc.module.JingleSessions;
import norc.module.Messages;
import norc.module.Moods;
import norc.module.Pings;
import norc.module.Profile;
import norc.module.Reactions;
import norc.module.Receipts;
import norc.module.Replies;
import norc.module.Retractions;
import norc.module.Rooms;
import norc.module.Time;
import norc.module.Tunes;
import norc.module.Share;
import norc.module.Upload;
import sys.FileSystem;
import sys.thread.Deque;
import sys.thread.Thread;
import xmpp.EntityCapabilities;
import xmpp.Ping;
import xmpp.Presence;
import xmpp.XML;

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

	/** Priority of the own presence (-128 to 127), `null`: none sent (0) **/
	var priority:Null<Int>;

	/** Creates the capabilities element of the current session **/
	var caps:Null<() -> XML>;

	final commands:Commands;

	/** External programs run on events (`<config dir>/hooks/on-<event>`) **/
	final hooks:Hooks;

	/** Socket interface for other programs, if enabled **/
	final api:Api;

	/** Programs started with norc, connected to the api (`<config dir>/scripts/`, `<account dir>/scripts/`) **/
	final scripts:Scripts;

	/** The interactive input (`-i`) **/
	final console:Console;

	/** Features of the client, each with its commands and part of the session **/
	final modules:Array<Module>;

	/** Failed connection attempts since the last login, for the reconnect delay **/
	var attempt = 0;

	/** Time of the last input of the user (commands from the terminal or api), for last activity requests **/
	var lastInput = Sys.time();

	/** The session was online (for the logout event) **/
	var wasOnline = false;

	var exitCode:Null<Int>;

	public function new(account:Account, password:String) {
		this.account = account;
		this.password = password;
		priority = account.priority;
		// the hooks and scripts of all accounts, then those of this account (if its config is a directory)
		final accountDir = Config.accountDir(account.name);
		final dirs = [Config.configDir()].concat(accountDir != null ? [accountDir] : []);
		hooks = new Hooks([for (dir in dirs) '$dir/hooks'], account.name, () -> session?.stream.jid ?? "", post);
		commands = new Commands(online);
		// the socket is only opened with api = 1 (run), stdin/stdout (--stdin) and scripts use it too
		api = new Api((line, args, out) -> {
			lastInput = Sys.time();
			return (args == null) ? commands.run(line, out, false) : commands.call(line, args, out);
		}, post);
		final env = ["account" => account.name, "config" => Config.configDir()];
		if (accountDir != null)
			env.set("account_dir", accountDir);
		scripts = new Scripts([for (dir in dirs) '$dir/scripts'], api, env, post);
		commands.registerAll(scripts.commands());
		commands.registerAll([
			{
				name: "presence",
				args: "[state] [status...]",
				description: "show or set your presence: available, chat, away, xa (extended away), dnd (busy), with a status message",
				run: (args, out) -> setPresence(args[0], args[1], out),
				complete: ["state" => _ -> ["available", "chat", "away", "xa", "dnd"]],
				subcommands: [
					{
						name: "status",
						args: "[text...]",
						description: "show or set your status message, keeping the presence state (- clears it), as /status",
						run: (args, out) -> setStatus(args[0], out)
					},
					{
						name: "priority",
						args: "[priority]",
						description: "show or set the priority of your presence (-128 to 127): messages to your bare jid go to the client with the highest",
						run: (args, out) -> setPriority(args[0], out)
					}
				]
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
		final context:Context = {emit: emit, post: post};
		final contacts = new Contacts(context);
		final messages = new Messages(context, contacts);
		// before the modules adding elements to sent chat messages
		final rooms = new Rooms(context, messages, contacts, account.autojoinBookmarks != false);
		final chatStates = new ChatStates(context, messages, contacts, account.chatStates != false);
		chatStates.isRoom = rooms.joined;
		console = new Console(context, commands, contacts, chatStates, rooms, {
			normal: account.prompt ?? "> ",
			chat: account.chatPrompt ?? "{name}{state}> ",
			room: account.roomPrompt ?? "#{name}> "
		},
			account.persistentCommandHistory != false ? '${Config.stateDir(account.name)}/history' : null);
		for (name => command in account.aliases ?? [])
			commands.aliases.set(name, command);
		commands.completers.set("jid", arg -> contacts.completions(arg));
		final sessions = new JingleSessions(context);
		final history = new History(context, contacts, rooms, messages);
		console.entered = (jid, out) -> history.recent(jid, account.chatHistory ?? 10, out);
		modules = [
			contacts,
			messages,
			rooms,
			history,
			new Carbons(context, messages, account.carbons != false),
			new Receipts(context, messages, contacts),
			chatStates,
			new Profile(context, messages, contacts),
			new Moods(context, messages, contacts),
			new Tunes(context, messages, contacts),
			new Corrections(context, messages),
			new Reactions(context, messages, contacts, rooms),
			new Replies(context, messages, contacts, rooms),
			new Retractions(context, messages, contacts, rooms),
			new Avatars(context, messages, contacts, rooms),
			new Buzz(context, messages, contacts, account.attention != false),
			new Time(context, contacts, account.entityTime == true),
			new Pings(context, contacts),
			new AdHoc(context, contacts),
			new Blocking(context, contacts),
			new Discovery(context, contacts, account.lastActivity == true ? () -> Std.int(Sys.time() - lastInput) : null),
			sessions,
			new FileTransfers(context, contacts, sessions, account.downloadDir ?? Config.downloadDir()),
			new Calls(context, contacts, sessions, account),
			new Upload(context, messages, contacts) // disabled for now (shared documents, /share)
				// new Share(context, messages, contacts, account.shareService)
		];
		for (m in modules)
			commands.registerAll(m.commands());
	}

	/**
		Connects and processes events until the client quits; returns the exit code.
		With `stdio`, API requests are read from stdin and replies and events written to stdout (`--stdin`);
		the client quits at the end of the input.
	**/
	public function run(interactive:Bool, stdio = false):Int {
		// regular checks, e.g. the keepalive of the session
		Thread.create(() -> while (true) {
			Sys.sleep(5);
			post(() -> session?.tick());
		});
		if (stdio)
			api.stdio(quit);
		if (account.api == true) {
			try {
				final host = account.apiHost ?? "127.0.0.1";
				api.start(Config.stateDir(account.name), host, account.apiPort ?? 0);
				Term.info('api: ${Config.stateDir(account.name)}/api');
				if (!host.startsWith("127.") && host != "localhost" && host != "::1")
					Term.error('warning: the api is reachable over the network ($host), unencrypted: '
						+ 'the token can be read from the traffic, giving control over the account');
			} catch (e)
				Term.error('cannot start the api: $e');
		}
		// before the connection: the scripts get the login event
		scripts.startAll();
		connect();
		// after connecting: reading piped input from the start hangs the client
		if (interactive)
			console.start(line -> events.add(line != null ? Line(line) : InputClosed));
		while (exitCode == null)
			handle(events.pop(true));
		scripts.stopAll();
		api.stop();
		console.stop();
		return exitCode;
	}

	function handle(e:Event) {
		switch e {
			case Net(c, e):
				if (session != null && session.owns(c))
					session.handle(e);
			case Line(line):
				lastInput = Sys.time();
				console.input(line);
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
		if (account.streamManagement != false)
			session.manageStream();
		if (account.keepalive != null)
			session.keepalive = account.keepalive;
		// filter hooks: modify or drop stanzas
		session.filterSend = xml -> hooks.filter("stanza-send", xml, validStanza);
		session.filterRecv = xml -> hooks.filter("stanza-recv", xml, validStanza);
		final stream = session.stream;
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

	function setPresence(state:Null<String>, status:Null<String>, out:Output) {
		if (state == null)
			return showPresence(out, false);
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
		updatePresence(out);
	}

	function setStatus(text:Null<String>, out:Output) {
		if (text == null) {
			out.data({status: status, online: online()}, () -> out.info('status: ${status ?? "-"}' + (online() ? '' : ' (not connected)')));
			return;
		}
		status = (text == "-") ? null : text;
		updatePresence(out);
	}

	/** Sends the changed presence (if online) and shows it **/
	function updatePresence(out:Output) {
		if (online())
			sendPresence();
		showPresence(out, true);
	}

	function showPresence(out:Output, changed:Bool) {
		final presence = {state: (show : Null<String>) ?? "available", status: status};
		final note = online() ? '' : changed ? ' (sent once connected)' : ' (not connected)';
		out.data({
			state: presence.state,
			status: status,
			priority: priority,
			online: online()
		},
			() -> out.info('presence: ${Contacts.describe(presence)}' + (priority != null ? ', priority $priority' : '') + note));
	}

	function setPriority(value:Null<String>, out:Output) {
		if (value == null) {
			out.data({priority: priority ?? 0}, () -> out.info('priority: ${priority ?? 0}'));
			return;
		}
		final p = Std.parseInt(value);
		if (p == null || Std.string(p) != value.trim() || p < Priority.MIN || p > Priority.MAX) {
			out.error('invalid priority: $value (-128 to 127)');
			return;
		}
		priority = p;
		updatePresence(out);
	}

	function sendPresence() {
		final presence = new Presence(show, status, (priority != null) ? (priority : Priority) : null);
		if (caps != null)
			presence.properties.push(caps());
		session.stream.send(presence);
	}

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
		out.data({
			account: account.name,
			path: path,
			exists: exists,
			values: map,
			unsaved: unsaved
		}, () -> {
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

	/** Output of a stanza filter hook: one well-formed element **/
	static function validStanza(xml:String):Bool
		return try {
			final x = Xml.parse(xml);
			[for (e in x.elements()) e].length == 1;
		} catch (_)
			false;

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

	function online():Bool
		return session != null && session.online;

	inline function exit(code:Int)
		exitCode = code;

	/** See `Module.Emit` **/
	function emit(event:String, args:Array<String>, values:haxe.DynamicAccess<Dynamic>) {
		hooks.run(event, args, values);
		api.event(event, values);
	}

	/** Runs `f` on the main thread **/
	function post(f:() -> Void)
		events.add(Call(f));
}
