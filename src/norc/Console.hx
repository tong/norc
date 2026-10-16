package norc;

import norc.Module;
import norc.Output;
import norc.module.ChatStates;
import norc.module.Contacts;
import norc.module.Rooms;
import sys.thread.Lock;
import sys.thread.Thread;
import xmpp.Jid;

using StringTools;

/**
	The interactive input (`-i`): reads lines from stdin, with the line editor on a terminal, and runs them as commands.

	Chat mode (`/chat <jid>`): lines without `/` are sent to the contact or room (`//` sends a line starting with `/`),
	commands keep working. `/chat` or Ctrl-C on an empty line leaves it. Joining a room starts it (group chat mode),
	leaving the room ends it; there the subcommands of `/room` work without `/room` (`/subject`, `/who`, `/nick`).
	Chat states (XEP-0085) are sent: `active` in the chat, `composing` while typing a message, `paused` after some seconds
	without typing, `gone` when leaving it; the state of the contact is shown in the prompt (e.g. `alice (typing)> `).
**/
/** Counts shown in the prompt **/
typedef PromptCounts = {
	var calls:{active:Int, pending:Int};
	var transfers:{active:Int, pending:Int};
}

/** The prompts of the modes, see `Config.Account` **/
typedef Prompts = {
	final normal:String;
	final chat:String;
	final room:String;
}

class Console {
	/** Seconds without typing before the chat state `paused` **/
	static inline var PAUSE = 5;

	final context:Context;
	final commands:Commands;
	final contacts:Contacts;
	final chatStates:ChatStates;
	final rooms:Rooms;
	final prompts:Prompts;

	/** The fixed placement of the avatar in the prompt (`{avatar}`), moved when the prompt is drawn again **/
	static inline var PROMPT_PLACEMENT = 1;

	/** The prompt last set (with its placeholders replaced) **/
	var shownPrompt:Null<String>;

	/** The counts of calls and file transfers for the prompt (`{calls_active}`, `{status}`, …) **/
	public var counts:Null<() -> PromptCounts>;

	/** The file keeping the history of the input line, `null` without **/
	final historyPath:Null<String>;

	/** The line editor, `null` without terminal **/
	var editor:Null<LineEditor>;

	/** Called when the chat mode starts with a contact (not a room), e.g. to show the last messages **/
	public var entered:Null<(jid:String, out:Output) -> Void>;

	/** The jid of the chat mode; set on the main thread, read by the input thread (Ctrl-C) **/
	var chat:Null<String>;

	/** The chat state of the contact of the chat mode, `null` if active or unknown **/
	var theirState:Null<String>;

	/** Time of the last change of a message being typed, for `paused` **/
	var lastTyping = 0.0;

	/** A check for `paused` is pending **/
	var pausing = false;

	public function new(context:Context, commands:Commands, contacts:Contacts, chatStates:ChatStates, rooms:Rooms, prompts:Prompts, ?historyPath:String) {
		this.context = context;
		this.commands = commands;
		this.contacts = contacts;
		this.chatStates = chatStates;
		this.rooms = rooms;
		this.prompts = prompts;
		this.historyPath = historyPath;
		chatStates.received = (from, state) -> if (chat != null && Jid.parseBare(chat) == from) {
			theirState = (state == "active") ? null : state;
			updatePrompt();
		}
		// joined on the terminal: group chat mode
		rooms.entered = (room, out) -> if (out == TermOutput.instance) enter(room, out);
		rooms.changed = room -> if (chat != null && Jid.parseBare(chat).toLowerCase() == room) {
			if (!rooms.joined(room))
				chat = null;
			updatePrompt();
		}
	}

	/**
		Starts reading stdin on a thread: `read` is called with each line, and `null` at the end of the input.
		Call `stop` to restore the terminal.
	**/
	public function start(read:Null<String>->Void) {
		commands.register({
			name: "chat",
			args: "[jid]",
			target: false,
			description: "chat with a contact or room: lines without / are sent to it (// for a line starting with /); without jid, or Ctrl-C: leave",
			run: (args, out) -> (args[0] == null) ? leave(out) : enter(args[0], out),
			complete: ["jid" => arg -> contacts.completions(arg).concat(rooms.completions())]
		});
		commands.register({
			name: "edit",
			args: "[text...]",
			description: "write the input line in your text editor ($VISUAL, $EDITOR), line breaks as \\n (also Ctrl-X Ctrl-E)",
			run: (args, out) -> out.error("/edit: only on a terminal (-i)")
		});
		editor = LineEditor.start(prompts.normal, historyPath);
		Term.editor = editor;
		if (editor != null) {
			refreshPrompt();
			editor.complete = complete;
			editor.changed = line -> context.post(() -> typing(line));
			// sent messages are shown by the messages module
			editor.echo = line -> chat == null || !message(line) || !commands.isOnline();
		}
		Thread.create(() -> {
			final stdin = Sys.stdin();
			// the text of the text editor (/edit), the next input line
			var initial:Null<String> = null;
			while (true) {
				var line = (editor != null) ? editor.readLine(initial) : try stdin.readLine() catch (_:haxe.io.Eof) null;
				initial = null;
				// on this thread: the text editor reads the terminal, not this thread
				// in normal mode also without / (as all commands)
				final edit = (line == null) ? null : (~/^\/edit(\s|$)/.match(line.trim()) ? "/edit" : (chat == null
					&& ~/^edit(\s|$)/.match(line.trim())) ? "edit" : null);
				if (editor != null && edit != null) {
					initial = editor.edit(line.trim().substr(edit.length).trim()) ?? "";
					continue;
				}
				if (line == LineEditor.INTERRUPT)
					line = (chat != null) ? "/chat" : LineEditor.QUIT;
				read(line);
				// Stop reading: exit() waits for the lock of stdin, held while a read blocks
				if (line == null || commands.exits(line, chat != null))
					return;
			}
		});
	}

	public function stop() {
		Term.editor = null;
		editor?.stop();
	}

	/** Runs an input line (on the main thread): a command, or a message in chat mode **/
	public function input(line:String) {
		if (chat == null || line.trim().length == 0 || !message(line))
			// in normal mode every line is a command: the / is optional
			commands.run(roomCommand(line), null, chat != null, (chat != null) ? {jid: chat, known: contacts.known} : null);
		else
			commands.call("msg", [chat, line.startsWith("//") ? line.substr(1) : line]);
	}

	function enter(input:String, out:Output) {
		final jid = rooms.resolve(input) ?? contacts.resolve(input, out);
		if (jid == null)
			return;
		if (!Jid.isValid(jid)) {
			out.error('invalid jid: $jid');
			return;
		}
		if (chat != jid) {
			state("gone");
			theirState = null;
		}
		chat = jid;
		state("active");
		updatePrompt();
		out.info('chat ${rooms.joined(jid) ? "in" : "with"} ${name(jid)}: lines without / are sent, /chat or Ctrl-C to leave');
		if (entered != null && !rooms.joined(jid))
			entered(jid, out);
	}

	function leave(out:Output) {
		if (chat == null) {
			out.info("not in a chat (/chat <jid> starts one)");
			return;
		}
		state("gone");
		chat = null;
		theirState = null;
		updatePrompt();
	}

	/** In group chat mode, a subcommand of `/room` without `/room` (e.g. `/subject`, `/who`) is the subcommand **/
	function roomCommand(line:String):String {
		if (chat == null || !rooms.joined(chat) || !line.startsWith("/"))
			return line;
		final name = line.substr(1).split(" ")[0];
		return commands.hasSubcommand("room", name) ? '/room ${line.substr(1)}' : line;
	}

	/** A line of chat mode is a message, not a command **/
	static function message(line:String):Bool
		return !line.startsWith("/") || line.startsWith("//");

	/** The name of a room (its local part) or contact, with the resource of `jid` if it has one **/
	function name(jid:String):String {
		if (rooms.joined(jid))
			return Rooms.label(jid);
		final resource = Jid.parseResource(jid);
		return contacts.name(Jid.parseBare(jid)) + (resource != null ? '/$resource' : '');
	}

	function updatePrompt() {
		final jid = chat;
		// its occupants entering and leaving are shown
		rooms.active = (jid != null && rooms.joined(jid)) ? Jid.parseBare(jid).toLowerCase() : null;
		refreshPrompt();
	}

	/**
		Sets the prompt of the current mode, with the counts of calls, rooms and file transfers (`counts`), if it changed;
		after each event, the counts may have changed.
	**/
	public function refreshPrompt() {
		if (editor == null)
			return;
		final jid = chat;
		final room = jid != null && rooms.joined(jid);
		var prompt = (jid == null) ? prompts.normal : (room ? prompts.room : prompts.chat);
		if (jid != null)
			prompt = prompt.replace("{name}", Term.name(name(jid), Jid.parseBare(jid)))
				.replace("{jid}", jid)
				.replace("{nick}", rooms.nickIn(jid) ?? "")
				.replace("{avatar}", room ? "" : Term.avatarIcon(Jid.parseBare(jid), PROMPT_PLACEMENT))
				.replace("{state}", (!room && theirState != null) ? Term.style(' (${theirState == "composing" ? "typing" : theirState})', 2) : "");
		if (prompt.contains("{")) {
			final c = (counts != null) ? counts() : {calls: {active: 0, pending: 0}, transfers: {active: 0, pending: 0}};
			prompt = prompt.replace("{calls_active}", Std.string(c.calls.active))
				.replace("{calls_pending}", Std.string(c.calls.pending))
				.replace("{rooms}", Std.string(rooms.count()))
				.replace("{transfers_active}", Std.string(c.transfers.active))
				.replace("{transfers_pending}", Std.string(c.transfers.pending))
				.replace("{status}", status(c));
		}
		// the avatar of the previous chat, not drawn anymore
		if (!prompt.contains("\x1B_Ga=p"))
			Term.clearPlacement(PROMPT_PLACEMENT);
		if (prompt != shownPrompt) {
			shownPrompt = prompt;
			editor.setPrompt(prompt);
		}
	}

	/** `☎1/0 #3 ⇅2/1 `: calls (active/pending), rooms, file transfers (active/pending), only those there are; dimmed **/
	function status(c:PromptCounts):String {
		final parts = [];
		if (c.calls.active + c.calls.pending > 0)
			parts.push('☎${c.calls.active}/${c.calls.pending}');
		final n = rooms.count();
		if (n > 0)
			parts.push('#$n');
		if (c.transfers.active + c.transfers.pending > 0)
			parts.push('⇅${c.transfers.active}/${c.transfers.pending}');
		return (parts.length > 0) ? Term.style(parts.join(" "), 2) + " " : "";
	}

	/** The input line changed: `composing` while it is a message (`paused` after a while), else `active` **/
	function typing(line:String) {
		if (line.length == 0 || !message(line)) {
			state("active");
			return;
		}
		state("composing");
		lastTyping = Sys.time();
		checkPaused(PAUSE);
	}

	/** Sends `paused` if the message being typed did not change for `PAUSE` seconds, checked after `delay` **/
	function checkPaused(delay:Float) {
		if (pausing)
			return;
		pausing = true;
		Thread.create(() -> {
			Sys.sleep(delay);
			context.post(() -> {
				pausing = false;
				if (chat == null || chatStates.last(chat) != "composing")
					return;
				final idle = Sys.time() - lastTyping;
				if (idle >= PAUSE)
					state("paused");
				else
					checkPaused(PAUSE - idle);
			});
		});
	}

	/** Sends the chat state to the contact of the chat mode **/
	function state(s:String) {
		if (chat != null && commands.isOnline())
			chatStates.set(chat, s);
	}

	/** Completes the input of the editor (on the input thread): on the main thread, as the commands use its state **/
	function complete(before:String):Null<{word:String, candidates:Array<String>}> {
		var result = null;
		final lock = new Lock();
		context.post(() -> {
			final line = roomCommand(before);
			result = commands.complete(line, chat != null);
			// in normal mode a command without /: completed as with it, the candidates without it
			if (chat == null && before.length > 0 && !before.startsWith("/")) {
				final c = commands.complete('/$before');
				result = (c == null) ? null : c.word.startsWith("/") ? {
					word: c.word.substr(1),
					candidates: [for (v in c.candidates) v.startsWith("/") ? v.substr(1) : v]
				} : c;
			}
			// a command being typed: also the subcommands of /room in group chat mode
			if (line == before && chat != null && rooms.joined(chat) && before.startsWith("/") && !before.contains(" ")) {
				final subs = commands.complete('/room ${before.substr(1)}');
				if (subs != null) {
					final candidates = (result?.candidates ?? []).concat([for (s in subs.candidates) '/$s']);
					candidates.sort(Reflect.compare);
					result = {word: before, candidates: candidates};
				}
			}
			lock.release();
		});
		// nothing if the main thread is busy
		return lock.wait(1) ? result : null;
	}
}
