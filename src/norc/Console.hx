package norc;

import norc.Module;
import norc.Output;
import norc.module.ChatStates;
import norc.module.Contacts;
import sys.thread.Lock;
import sys.thread.Thread;
import xmpp.Jid;

using StringTools;

/**
	The interactive input (`-i`): reads lines from stdin, with the line editor on a terminal, and runs them as commands.

	Chat mode (`/chat <jid>`): lines without `/` are sent to the contact (`//` sends a line starting with `/`), commands
	keep working. `/chat` or Ctrl-C on an empty line leaves it. While typing a message, the chat state is `composing`.
**/
class Console {
	final context:Context;
	final commands:Commands;
	final contacts:Contacts;
	final chatStates:ChatStates;
	final prompt:String;

	/** The prompt in chat mode: `{name}` is replaced with the name of the contact, `{jid}` with its jid **/
	final chatPrompt:String;

	/** The line editor, `null` without terminal **/
	var editor:Null<LineEditor>;

	/** The jid of the chat mode; set on the main thread, read by the input thread (Ctrl-C) **/
	var chat:Null<String>;

	public function new(context:Context, commands:Commands, contacts:Contacts, chatStates:ChatStates, prompt:String, chatPrompt:String) {
		this.context = context;
		this.commands = commands;
		this.contacts = contacts;
		this.chatStates = chatStates;
		this.prompt = prompt;
		this.chatPrompt = chatPrompt;
	}

	/**
		Starts reading stdin on a thread: `read` is called with each line, and `null` at the end of the input.
		Call `stop` to restore the terminal.
	**/
	public function start(read:Null<String>->Void) {
		commands.register({
			name: "chat",
			args: "[jid]",
			description: "chat with a contact: lines without / are sent to it (// for a line starting with /); without jid, or Ctrl-C: leave",
			run: (args, out) -> (args[0] == null) ? leave(out) : enter(args[0], out)
		});
		editor = LineEditor.start(prompt);
		Term.editor = editor;
		if (editor != null) {
			editor.complete = complete;
			editor.changed = line -> context.post(() -> typing(line));
			// sent messages are shown by the messages module
			editor.echo = line -> chat == null || !message(line) || !commands.isOnline();
		}
		Thread.create(() -> {
			final stdin = Sys.stdin();
			while (true) {
				var line = (editor != null) ? editor.readLine() : try stdin.readLine() catch (_:haxe.io.Eof) null;
				if (line == LineEditor.INTERRUPT)
					line = (chat != null) ? "/chat" : LineEditor.QUIT;
				read(line);
				// Stop reading: exit() waits for the lock of stdin, held while a read blocks
				if (line == null || commands.exits(line))
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
			commands.run(line);
		else
			commands.call("msg", [chat, line.startsWith("//") ? line.substr(1) : line]);
	}

	function enter(input:String, out:Output) {
		final jid = contacts.resolve(input, out);
		if (jid == null)
			return;
		if (!Jid.isValid(jid)) {
			out.error('invalid jid: $jid');
			return;
		}
		if (chat != jid)
			state("active");
		chat = jid;
		final name = contacts.name(Jid.parseBare(jid)) + (Jid.parseResource(jid) != null ? '/${Jid.parseResource(jid)}' : '');
		editor?.setPrompt(chatPrompt.replace("{name}", Term.name(name, Jid.parseBare(jid))).replace("{jid}", jid));
		out.info('chat with $name: lines without / are sent, /chat or Ctrl-C to leave');
	}

	function leave(out:Output) {
		if (chat == null) {
			out.info("not in a chat (/chat <jid> starts one)");
			return;
		}
		state("active");
		chat = null;
		editor?.setPrompt(prompt);
	}

	/** A line of chat mode is a message, not a command **/
	static function message(line:String):Bool
		return !line.startsWith("/") || line.startsWith("//");

	/** The input line changed: `composing` while it is a message, else `active` **/
	function typing(line:String)
		state((line.length > 0 && message(line)) ? "composing" : "active");

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
			result = commands.complete(before);
			lock.release();
		});
		// nothing if the main thread is busy
		return lock.wait(1) ? result : null;
	}
}
