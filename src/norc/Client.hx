package norc;

import norc.Config.Account;
import norc.Status.StatusData;
import norc.Status.Unread;
import norc.Module;
import norc.Output;
import norc.module.AdHoc;
import norc.module.Attention;
import norc.module.Avatars;
import norc.module.Blocking;
import norc.module.Calls;
import norc.module.Carbons;
import norc.module.Chatlog;
import norc.module.ChatStates;
import norc.module.Corrections;
import norc.module.Contacts;
import norc.module.Discovery;
import norc.module.FileTransfers;
import norc.module.History;
import norc.module.InlineImages;
import norc.module.JingleSessions;
import norc.module.Messages;
import norc.module.Moods;
#if norc_omemo
import norc.module.Omemo;
#end
import norc.module.Nodes;
import norc.module.Pings;
import norc.module.Profile;
import norc.module.Reactions;
import norc.module.Receipts;
import norc.module.Replies;
import norc.module.Retractions;
import norc.module.Server;
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

	/** The prompts without `prompt`, `chat_prompt`, `room_prompt` **/
	static final DEFAULT_PROMPTS:norc.Console.Prompts = {normal: "{status}> ", chat: "{name}{state}> ", room: "#{name}> "};

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

	/** What is going on (calls, unread messages, transfers, …): `/overview`, the prompt, the `status` event **/
	var overview:norc.Status;

	/** When the current session went online (kept when it is resumed), `null` before **/
	var onlineSince:Null<Float>;

	/** `/read [jid]`: marks the messages of the chat (or of all) read, set up with the unread messages **/
	var markRead:(input:Null<String>, out:Output) -> Void = (_, _) -> {};

	/** Your other clients online (full jids), by the presences of the contacts module **/
	var otherClients:() -> Array<String> = () -> [];

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
		api.complete = line -> commands.complete('/' + (line.startsWith("/") ? line.substr(1) : line));
		final env = ["account" => account.name, "config" => Config.configDir()];
		if (accountDir != null)
			env.set("account_dir", accountDir);
		scripts = new Scripts([for (dir in dirs) '$dir/scripts'], api, env, post);
		commands.registerAll(scripts.commands());
		commands.registerAll(hooks.commands());
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
						description: "show or set your status message, keeping the presence state (- clears it)",
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
				name: "xmpp-debug",
				args: "[state]",
				description: "print the XMPP stream: on (default) or off",
				run: (args, out) -> setDebug(args[0], out),
				complete: ["state" => _ -> ["on", "off"]]
			},
			{
				name: "config",
				args: "[key=value...]",
				description: "show the config of the account (values not saved marked with *), or change values (--save: also in the file)",
				run: (args, out) -> (args[0] != null) ? setConfig(args[0], out) : showConfig(out),
				complete: ["key=value" => arg -> completeConfig(arg)],
				subcommands: [
					{
						name: "save",
						description: "save the config of the account (e.g. options given on the command line)",
						run: (args, out) -> saveConfig(out)
					}
				]
			},
			{
				name: "read",
				args: "[jid]",
				description: "mark the messages of a chat as read (without jid: of all chats), e.g. read in another program",
				run: (args, out) -> markRead(args[0], out),
				complete: ["jid" => arg -> [for (c in overview.get().chats) if (c.jid.startsWith(arg)) c.jid]]
			},
			{
				name: "overview",
				description: "what is going on: calls, unread messages, file transfers, subscription requests, rooms, who is typing, a command waiting for input",
				run: (args, out) -> showOverview(out)
			},
			{
				name: "account",
				description: "your account: jid, connection, login, presence, your other clients online, the api, config and state",
				run: (args, out) -> showAccount(out)
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
		// disabled modules are not created: they would handle stanzas (see `Config.MODULES`)
		final disabled = account.disableModules ?? [];
		function enabled(name:String):Bool
			return !disabled.contains(name);
		final contacts = new Contacts(context);
		otherClients = () -> {
			final own = session?.stream.jid;
			(own == null) ? [] : [for (r in contacts.resources(xmpp.Jid.parseBare(own))) if (r != own) r];
		}
		// avatars in the terminal: of the avatars module, in the prompt (`{avatar}`) and before names (`inline_avatars`)
		Term.avatarPath = jid -> contacts.avatars.get(xmpp.Jid.parseBare(jid).toLowerCase());
		Term.inlineAvatars = account.inlineAvatars == true;
		final messages = new Messages(context, contacts);
		// what the server offers: commands requiring a feature (`requires`) are refused without it
		final server = new Server(context);
		commands.supports = server.supports;
		commands.missing = feature -> Server.FEATURES.get(feature) ?? feature;
		// before the modules adding elements to sent chat messages; without the module only used by others (no rooms)
		final rooms = new Rooms(context, messages, contacts, account.autojoinBookmarks != false, enabled("rooms"));
		final chatStates = new ChatStates(context, messages, contacts, account.chatStates != false, enabled("chat-states"));
		chatStates.isRoom = rooms.joined;
		console = new Console(context, commands, contacts, chatStates, rooms, {
			normal: account.prompt ?? DEFAULT_PROMPTS.normal,
			chat: account.chatPrompt ?? DEFAULT_PROMPTS.chat,
			room: account.roomPrompt ?? DEFAULT_PROMPTS.room
		},
			account.persistentCommandHistory != false ? '${Config.stateDir(account.name)}/history' : null);
		for (name => command in account.aliases ?? [])
			commands.aliases.set(name, command);
		commands.completers.set("jid", arg -> contacts.completions(arg));
		// unread messages: of chats other than the current chat mode
		final unread = new Unread();
		markRead = (input, out) -> {
			final chats = [for (c in unread.list((jid, _) -> jid)) c.jid];
			final jid = (input == null) ? null : chats.contains(input.toLowerCase()) ? input.toLowerCase() : (rooms.resolve(input)
				?? contacts.resolve(input, out));
			if (input != null && jid == null)
				return;
			final read = (jid == null) ? chats : [xmpp.Jid.parseBare(jid).toLowerCase()];
			for (c in read)
				unread.clear(c);
			out.data({read: read}, () -> out.info((read.length == 0) ? "nothing unread" : 'read: ${read.join(", ")}'));
		}
		final history = enabled("history") ? new History(context, contacts, rooms, messages, server) : null;
		// the local log of the chats (chatlog = 1)
		final chatlog = new Chatlog(context, messages, contacts, account);
		// entering a chat: its last messages, of the chatlog (contacts), else of the archive
		console.entered = (jid, out) -> {
			unread.clear(xmpp.Jid.parseBare(jid));
			final count = account.chatHistory ?? 10;
			if (!rooms.joined(xmpp.Jid.parseBare(jid)) && chatlog.recent(jid, count, out))
				return;
			if (history != null)
				history.recent(jid, count, out);
		}
		// Jingle sessions for file transfers and calls
		final sessions = (enabled("file-transfers") || enabled("calls")) ? new JingleSessions(context) : null;
		// shared directories (share.<name>): their listing, the hashes of their files kept in the state dir
		final shares = (account.shares != null) ? new Shares(account.shares, account.shareAccess, Config.stateDir(account.name)) : null;
		final fileTransfers = enabled("file-transfers") ? new FileTransfers(context, contacts, sessions, account.downloadDir ?? Config.downloadDir(),
			shares) : null;
		final calls = enabled("calls") ? new Calls(context, messages, contacts, sessions, account) : null;
		// the status: what is going on, for the prompt, /overview and the status event
		final adHoc = new AdHoc(context, contacts);
		messages.displayed.push((chat, m, own, room) -> {
			// writing in a chat reads it (also from another client); the history of a room on joining isn't new
			if (own)
				unread.clear(chat);
			else if (console.current()?.toLowerCase() != chat.toLowerCase() && !(room && xmpp.DelayedDelivery.delay(m) != null)) {
				final nick = room ? rooms.nickIn(chat) : null;
				unread.add(chat, room, nick != null && nick.length > 0 && (m.body ?? "").toLowerCase().contains(nick.toLowerCase()));
			}
		});
		overview = new norc.Status(() -> {
			final chats = unread.list((jid, room) -> room ? Rooms.label(jid) : contacts.name(jid));
			final s:StatusData = {
				connection: online() ? "online" : (session != null) ? "connecting" : quitting ? "offline" : "reconnecting",
				presence: (show : Null<String>) ?? "available",
				status: this.status,
				unread: Lambda.fold(chats, (c, n) -> c.room ? n : n + c.unread, 0),
				unread_rooms: Lambda.fold(chats, (c, n) -> c.room ? n + c.unread : n, 0),
				mentions: Lambda.fold(chats, (c, n) -> n + c.mentions, 0),
				chats: chats,
				calls: calls?.status() ?? [],
				transfers: fileTransfers?.status() ?? [],
				requests: contacts.pendingRequests(),
				rooms: rooms.joinedRooms(),
				typing: [for (jid => state in chatStates.typing) {jid: jid, name: contacts.name(jid), state: state}],
				command: enabled("adhoc") ? adHoc.waiting() : null
			};
			s;
		}, statusChanged);
		console.counts = () -> {
			final s = overview.get();
			final pending = s.calls.filter(c -> c.state == "ringing" || c.state == "calling").length;
			final offers = s.transfers.filter(t -> t.state == "offered").length;
			{
				calls: {active: s.calls.length - pending, pending: pending},
				transfers: {active: s.transfers.length - offers, pending: offers},
				unread: s.unread,
				mentions: s.mentions,
				requests: s.requests.length
			};
		};
		// in this order: modules handle received messages in the order they were created
		final optional:Array<{name:String, create:() -> Module}> = [
			{name: "carbons", create: () -> new Carbons(context, messages, account.carbons != false)},
			// after carbons: decrypts the copies too; before the others: they get the decrypted body
			#if norc_omemo
			{name: "omemo", create: () -> account.omemo == true ? new Omemo(context, messages, contacts, Config.stateDir(account.name)) : null},
			#end
			{name: "receipts", create: () -> new Receipts(context, messages, contacts)},
			// created above, for the console
			{name: "chat-states", create: () -> chatStates},
			{name: "profile", create: () -> new Profile(context, messages, contacts)},
			{name: "moods", create: () -> new Moods(context, messages, contacts)},
			{name: "tunes", create: () -> new Tunes(context, messages, contacts)},
			{name: "corrections", create: () -> new Corrections(context, messages)},
			{name: "reactions", create: () -> new Reactions(context, messages, contacts, rooms)},
			{name: "replies", create: () -> new Replies(context, messages, contacts, rooms)},
			{name: "retractions", create: () -> new Retractions(context, messages, contacts, rooms)},
			{name: "avatars", create: () -> new Avatars(context, messages, contacts, rooms)},
			{name: "attention", create: () -> new Attention(context, messages, contacts, account.attention != false)},
			{name: "time", create: () -> new Time(context, contacts, account.entityTime == true)},
			{name: "ping", create: () -> new Pings(context, contacts)},
			{name: "adhoc", create: () -> adHoc},
			{name: "pubsub", create: () -> new Nodes(context, contacts)},
			{name: "blocking", create: () -> new Blocking(context, contacts)}
		];
		modules = [contacts, messages, server];
		if (enabled("rooms"))
			modules.push(rooms);
		if (history != null)
			modules.push(history);
		modules.push(chatlog);
		for (m in optional)
			if (enabled(m.name)) {
				final module = m.create();
				if (module != null)
					modules.push(module);
			}
		modules.push(new Discovery(context, contacts, account.lastActivity == true ? () -> Std.int(Sys.time() - lastInput) : null));
		for (m in ([sessions, fileTransfers, calls] : Array<Null<Module>>))
			if (m != null)
				modules.push(m);
		if (enabled("upload"))
			modules.push(new Upload(context, messages, contacts));
		if (enabled("images"))
			modules.push(new InlineImages(context, messages, contacts, cast(account.inlineImages ?? "contacts")));
		// disabled for now (shared documents, /share)
		// modules.push(new Share(context, messages, contacts, account.shareService));
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
				final endpoints = Config.apiEndpoints(account);
				var tcp = endpoints.tcp;
				if (endpoints.socket != null && !UnixSocket.available && tcp == null) {
					Term.error('api: no Unix sockets here (only in the single binary on Linux and macOS), over TCP');
					tcp = {host: "127.0.0.1", port: 0};
				}
				final host = tcp?.host ?? "127.0.0.1";
				api.start(Config.stateDir(account.name), host, tcp?.port ?? 0, tcp != null, endpoints.socket);
				Term.info('api: ${Config.stateDir(account.name)}/api');
				if (tcp != null && !host.startsWith("127.") && host != "localhost" && host != "::1")
					Term.error('warning: the api is reachable over the network ($host), unencrypted: '
						+ 'the token can be read from the traffic, giving control over the account');
			} catch (e)
				Term.error('cannot start the api: $e');
		}
		// before the connection: the scripts get the login event
		scripts.startAll();
		connect();
		// after connecting: reading piped input from the start hangs the client
		if (interactive) {
			LineEditor.queryImages = account.terminalImages != false;
			console.start(line -> events.add(line != null ? Line(line) : InputClosed));
		}
		while (exitCode == null) {
			handle(events.pop(true));
			// e.g. a call or file transfer started or ended
			overview.update();
			console.refreshPrompt();
		}
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
			if (!session.resumed || onlineSince == null)
				onlineSince = Sys.time();
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

	/** `/account`: the account and its session **/
	function showAccount(out:Output) {
		final online = online();
		final s = session;
		final state = online ? "online" : (s != null) ? "connecting" : quitting ? "offline" : "reconnecting";
		final since = (online && onlineSince != null) ? onlineSince : null;
		final address = s?.address;
		final sm = (s?.sm?.id != null) ? "resumable" : (online && s?.sm != null) ? "not offered" : null;
		final clients = online ? otherClients() : [];
		clients.sort(Reflect.compare);
		final api = this.api.endpoints();
		final path = Config.accountPath(account.name);
		final stateDir = Config.stateDir(account.name);
		final presence = {state: (show : Null<String>) ?? "available", status: status};
		out.data({
			account: account.name,
			jid: s?.stream.jid ?? '${account.jid.node}@${account.jid.domain}/${account.resource}',
			state: state,
			since: (since != null) ? Std.int(since) : null,
			server: (address != null) ? '${address.host}:${address.port}' : null,
			mechanism: online ? s.mechanism : null,
			streamManagement: sm,
			presence: presence.state,
			status: status,
			priority: priority,
			clients: clients,
			api: api,
			config: path,
			stateDir: stateDir
		}, () -> {
			function line(key:String, value:String)
				out.print('  ${key.rpad(" ", 12)}$value');
			out.print('account ${account.name}');
			line("jid", s?.stream.jid ?? '${account.jid.node}@${account.jid.domain}/${account.resource}');
			line("connection", state + ((since != null)
				? ' since ${Term.timestamp(Date.fromTime(since * 1000))} (${Term.duration(Std.int(Sys.time() - since))})' : ''));
			if (address != null)
				line("server", '${address.host}:${address.port}' + (account.host == null ? Term.style(' (SRV of ${account.jid.domain})', 2) : '')
					+ (online && s.mechanism != null ? ', TLS, ${s.mechanism}' : ''));
			if (sm != null)
				line("session", (sm == "resumable") ? "resumable after disconnections (stream management)" : "not resumable (no stream management)");
			line("presence", Contacts.describe(presence) + (priority != null ? ', priority $priority' : ''));
			if (online)
				line("clients", (clients.length > 0) ? 'also online: ${clients.join(", ")}' : Term.style("no other client online", 2));
			line("api", (api.length > 0) ? api.join(", ") : Term.style("off (api = socket or --api)", 2));
			line("config", Config.contractHome(path) + (FileSystem.exists(path) ? "" : Term.style(" (not saved: /config save)", 2)));
			line("state dir", Config.contractHome(stateDir));
		});
	}

	/**
		`/config key=value… [--save]`: changes values (quoted with spaces, `\"` and `\\`), all or none if one is
		invalid; applies them where possible (see `Config.applies`), says when the others take effect.
	**/
	function setConfig(input:String, out:Output) {
		final re = ~/^(--save|([a-z_][a-z0-9_]*(?:\.[^\s=]+)?)=("((?:[^"\\]|\\.)*)"|(\S*)))\s*/;
		final changes = [];
		var save = false;
		var rest = input.trim();
		while (rest.length > 0) {
			if (!re.match(rest)) {
				out.error('invalid: ${rest.split(" ")[0]} (key=value, "value with spaces", --save)');
				return;
			}
			if (re.matched(1) == "--save")
				save = true;
			else {
				final quoted = re.matched(4);
				changes.push({key: re.matched(2), value: (quoted != null) ? ~/\\(.)/g.replace(quoted, "$1") : re.matched(5)});
			}
			rest = re.matchedRight();
		}
		if (changes.length == 0 && !save) {
			showConfig(out);
			return;
		}
		// all valid first: on a copy (with copies of its maps)
		final copy = Reflect.copy(account);
		copy.aliases = (account.aliases != null) ? account.aliases.copy() : null;
		copy.shares = (account.shares != null) ? account.shares.copy() : null;
		for (c in changes)
			try
				Config.set(copy, c.key, c.value)
			catch (e:String) {
				out.error(e);
				return;
			}
		final applied = [];
		for (c in changes) {
			Config.set(account, c.key, c.value);
			applyConfig(c.key);
			applied.push({key: c.key, value: Config.get(account, c.key), applies: (Config.applies(c.key) : String)});
		}
		final path = save ? try Config.storeAccount(account) catch (e) {
			out.error('cannot save the config: $e');
			null;
		} : null;
		out.data({changed: applied, saved: path}, () -> {
			for (a in applied)
				out.info('${a.key} = ${a.value ?? "-"}' + Term.style(' (${a.applies == (norc.Config.ConfigApplies.Now : String) ? "applied" : 'applies ${a.applies}'})', 2));
			if (path != null)
				out.info('saved ${Config.contractHome(path)}');
			else if (Lambda.exists(applied, a -> a.applies != (norc.Config.ConfigApplies.Now : String)))
				out.info(Term.style('not saved: lost when norc quits (/config save, or --save)', 2));
		});
	}

	/** Applies the changed value of `key` where it takes effect now (see `Config.applies`) **/
	function applyConfig(key:String) {
		if (key.startsWith("alias.")) {
			final name = key.substr("alias.".length);
			commands.aliases.set(name, account.aliases.get(name));
			return;
		}
		switch key {
			case "keepalive":
				if (session != null)
					session.keepalive = account.keepalive ?? 60;
			case "priority":
				priority = account.priority;
				if (online())
					sendPresence();
			case "inline_avatars":
				Term.inlineAvatars = account.inlineAvatars == true;
			case "prompt", "chat_prompt", "room_prompt":
				console.prompts = {
					normal: account.prompt ?? DEFAULT_PROMPTS.normal,
					chat: account.chatPrompt ?? DEFAULT_PROMPTS.chat,
					room: account.roomPrompt ?? DEFAULT_PROMPTS.room
				};
				console.refreshPrompt();
			case _:
		}
	}

	/** Completes `key=` of `/config` by the names of the keys **/
	function completeConfig(arg:String):Array<String>
		return arg.contains("=") ? [] : [for (k in Config.keyNames()) if (k.startsWith(arg)) '$k='];

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
	/**
		The status changed: the `status` event, to the API with all of it, to the hooks (`on-status`) the counts and
		the summary (their environment has no lists)
	**/
	function statusChanged(s:StatusData) {
		final offers = s.transfers.filter(t -> t.state == "offered").length;
		hooks.run("status", [norc.Status.summary(s)], {
			connection: s.connection,
			presence: s.presence,
			unread: s.unread,
			unread_rooms: s.unread_rooms,
			mentions: s.mentions,
			calls: s.calls.length,
			ringing: s.calls.filter(c -> c.state == "ringing").length,
			transfers: s.transfers.length - offers,
			offers: offers,
			requests: s.requests.length,
			rooms: s.rooms.length,
			typing: [for (t in s.typing) t.jid].join(" "),
			command: s.command != null,
			summary: norc.Status.summary(s)
		});
		api.event("status", s);
	}

	/** `/overview`: what is going on **/
	function showOverview(out:Output) {
		final s = overview.get();
		out.data(s, () -> {
			function line(key:String, value:String)
				out.print('  ${key.rpad(" ", 10)}$value');
			line("account", '${s.connection}, ${Contacts.describe({state: s.presence, status: s.status})}');
			for (c in s.calls)
				line("call", '#${c.id} ${c.name} ${c.media}, ${c.state}' + ((c.since != null) ? ' ${Term.duration(Std.int(Sys.time() - c.since))}' : '')
					+ (c.muted.length > 0 ? ', muted ${c.muted.join(", ")}' : '') + (c.recording ? ', recording' : ''));
			line("unread", (s.chats.length == 0) ? Term.style("nothing", 2) : [
				for (c in s.chats)
					(c.room ? '#${c.name}' : c.name) + ' ${c.unread}' + (c.mentions > 0 ? ' (@${c.mentions})' : '')
			].join(", "));
			for (t in s.transfers)
				line("file", '#${t.id} ${t.file} ' + switch t.state {
					case "offered": 'offered by ${t.jid}: /file accept ${t.id}';
					case "preparing": 'being read, then offered to ${t.jid}';
					case _: (t.direction == "send" ? 'to ' : 'from ') + t.jid
						+ ((t.size != null && t.size > 0) ? ' ${Std.int(t.bytes / t.size * 100)}%' : '');
				});
			if (s.requests.length > 0)
				line("requests", s.requests.join(", ") + Term.style(" (/contacts accept <jid>)", 2));
			if (s.rooms.length > 0)
				line("rooms", [for (r in s.rooms) r.name].join(", "));
			if (s.typing.length > 0)
				line("typing", [for (t in s.typing) t.name + (t.state == "paused" ? " (paused)" : "")].join(", "));
			if (s.command != null)
				line("command", '${s.command.node} of ${s.command.jid} waits for input: /command submit');
		});
	}

	function emit(event:String, args:Array<String>, values:haxe.DynamicAccess<Dynamic>) {
		hooks.run(event, args, values);
		api.event(event, values);
	}

	/** Runs `f` on the main thread **/
	function post(f:() -> Void)
		events.add(Call(f));
}
