package norc.module;

import haxe.Json;
import norc.Config.Account;
import norc.Module;
import norc.Output;
import norc.Styling;
import norc.Term;
import sys.FileSystem;
import sys.io.File;
import xmpp.Jid;
import xmpp.Message;
import xmpp.MessageReply;
import xmpp.LastMessageCorrection;

using StringTools;
using xmpp.DelayedDelivery;

/** A line of a chatlog: a message, a correction (`replaces`) or a retraction (`retracts`, no body) **/
private typedef Entry = {
	/** When it was sent (UTC, as XEP-0082) **/
	var date:String;

	/** The id of the message, as the contact refers to it **/
	var ?id:String;

	/** Sent by you (by any of your clients) **/
	var own:Bool;

	/** The sender: full jid **/
	var ?from:String;

	/** The text, without the quote of a reply **/
	var ?body:String;

	/** A correction: the id of the corrected message **/
	var ?replaces:String;

	/** A reply: the id of the message replied to **/
	var ?reply_id:String;

	/** A retraction: the id of the retracted message **/
	var ?retracts:String;
}

/**
	A local log of the chats with contacts (`chatlog = 1`, off by default): the messages as they are shown (also those
	of your other clients, carbons), corrections and retractions, in `$XDG_DATA_HOME/norc/chatlog/<account>/<jid>.jsonl`
	(JSON lines, readable only by you). Not the messages of rooms, nor the history of the server archive.

	When the chat mode starts with a contact, the last messages of its log are shown (`chat_history`), also offline
	and without archive on the server; a chat without log shows those of the archive instead (`History`).
**/
class Chatlog extends Module {
	/** Bytes read of the end of a log, for its last messages **/
	static inline var TAIL = 512 * 1024;

	/** Messages shown by `/chatlog` at most **/
	static inline var MAX = 500;

	final messages:Messages;
	final contacts:Contacts;
	final account:Account;
	final dir:String;

	public function new(context:Context, messages:Messages, contacts:Contacts, account:Account) {
		super(context);
		this.messages = messages;
		this.contacts = contacts;
		this.account = account;
		dir = Config.chatlogDir(account.name);
		messages.displayed.push((chat, m, own, room) -> if (!room && enabled()) write(chat, message(m, own)));
		messages.retractions.push((chat, id, own) -> if (enabled()) write(chat, {date: now(), own: own, retracts: id}));
	}

	/** Messages are logged: `chatlog = 1` (it can be changed while norc runs, `/config chatlog=1`) **/
	public function enabled():Bool
		return account.chatlog == true;

	override public function commands():Array<Commands.Command>
		return [
			{
				name: "chatlog",
				args: "[jid] [#count]",
				description: "the local log of the chats with contacts (chatlog = 1 enables it): the last messages with a contact (20, at most 500); without jid: where it is and the chats logged",
				run: (args, out) -> if (args[0] == null) status(out) else show(args[0], args[1], out),
				complete: ["jid" => arg -> [for (c in logged()) if (c.startsWith(arg)) c]]
			}
		];

	/**
		Shows the last `count` messages of the log of `jid` (a contact, not a room), e.g. when the chat mode starts.
		Returns `false` if there are none (no log, or off): then nothing is shown.
	**/
	public function recent(jid:String, count:Int, out:Output):Bool {
		if (!enabled() || count < 1)
			return false;
		final chat = Jid.parseBare(jid).toLowerCase();
		final entries = read(chat, count);
		if (entries.length == 0)
			return false;
		print(chat, entries, out);
		return true;
	}

	/** `/chatlog <jid> [#count]` **/
	function show(input:String, countArg:Null<String>, out:Output) {
		final count = (countArg != null) ? Std.parseInt(countArg.startsWith("#") ? countArg.substr(1) : countArg) : 20;
		if (count == null || count < 1 || count > MAX) {
			out.error('invalid count: $countArg (1 to $MAX)');
			return;
		}
		final jid = contacts.resolve(input, out);
		if (jid == null)
			return;
		final chat = Jid.parseBare(jid).toLowerCase();
		final entries = read(chat, count);
		if (entries.length == 0) {
			out.info('no chatlog of $chat' + (enabled() ? '' : ' (the chatlog is off: /config chatlog=1 --save)'));
			return;
		}
		print(chat, entries, out);
	}

	/** `/chatlog`: on or off, where, the chats logged **/
	function status(out:Output) {
		final chats = logged();
		out.data({enabled: enabled(), dir: dir, chats: chats}, () -> {
			out.info('chatlog: ${enabled() ? "on" : "off (/config chatlog=1 --save)"}, ${Config.contractHome(dir)}');
			if (chats.length > 0)
				out.print('  ' + [for (c in chats) contacts.name(c)].join(", "));
			out.info('the last messages with a contact: /chatlog <jid> [#count]');
		});
	}

	/** The contacts (bare jids) with a log **/
	function logged():Array<String> {
		final names = try FileSystem.readDirectory(dir) catch (_) [];
		final chats = [for (n in names) if (n.endsWith(".jsonl")) n.substr(0, n.length - ".jsonl".length)];
		chats.sort(Reflect.compare);
		return chats;
	}

	/** Prints `entries` of the chat with `chat` as messages are shown (also as data for the API) **/
	function print(chat:String, entries:Array<Entry>, out:Output) {
		final name = contacts.name(chat);
		out.data({jid: chat, messages: entries}, () -> {
			for (e in entries) {
				final date = xmpp.DelayedDelivery.parseStamp(e.date);
				final quote = (e.reply_id != null) ? Lambda.find(entries, r -> r.id == e.reply_id) : null;
				final text = ((quote != null) ? Term.style("↪ " + Recent.excerpt('<${quote.own ? "you" : name}> ${quote.body}', 60), 2) + "\n" : "")
					+ (messages.styling ? Styling.format(e.body) : e.body) + ((e.replaces != null) ? " ✎" : "");
				if (e.own)
					Messages.show('→ <$name>', null, text, date);
				else
					Messages.show('<$name>', chat, text, date);
			}
		});
		// replies and reactions can refer to them (^2), as to messages shown
		messages.recent.addOlder(chat, [
			for (e in entries)
				if (e.id != null) {id: e.id, from: e.from, name: e.own ? "you" : name, body: e.body, own: e.own}
		]);
	}

	/**
		The last `count` messages of the log of `chat`: corrections applied to the messages they correct (the text
		replaced, `replaces` kept as mark), retracted messages left out.
	**/
	function read(chat:String, count:Int):Array<Entry> {
		final path = file(chat);
		final text = try tail(path) catch (_) return [];
		final list = new Array<Entry>();
		final byId = new Map<String, Entry>();
		for (line in text.split("\n")) {
			final e:Null<Entry> = try Json.parse(line) catch (_) null;
			if (e == null || e.date == null)
				continue;
			if (e.retracts != null) {
				final target = byId.get(e.retracts);
				// only of its author
				if (target != null && target.own == e.own)
					list.remove(target);
				continue;
			}
			if (e.body == null)
				continue;
			if (e.replaces != null) {
				final target = byId.get(e.replaces);
				if (target != null && target.own == e.own) {
					target.body = e.body;
					target.replaces = e.replaces;
					continue;
				}
			}
			list.push(e);
			if (e.id != null)
				byId.set(e.id, e);
		}
		return list.slice(Std.int(Math.max(0, list.length - count)));
	}

	/** The end of the file at `path` (at most `TAIL` bytes, from the start of a line) **/
	static function tail(path:String):String {
		final size = FileSystem.stat(path).size;
		if (size <= TAIL)
			return File.getContent(path);
		final input = File.read(path, true);
		input.seek(size - TAIL, SeekBegin);
		final text = input.readAll().toString();
		input.close();
		final nl = text.indexOf("\n");
		return (nl >= 0) ? text.substr(nl + 1) : "";
	}

	/** The entry of a shown message **/
	static function message(m:Message, own:Bool):Entry {
		final entry:Entry = {
			date: xmpp.DelayedDelivery.formatStamp(m.delay()?.date ?? Date.now()),
			id: m.id,
			own: own,
			from: m.from,
			body: MessageReply.getBody(m)
		};
		final replaces = LastMessageCorrection.correction(m);
		if (replaces != null)
			entry.replaces = replaces;
		final reply = MessageReply.getReply(m)?.id;
		if (reply != null)
			entry.reply_id = reply;
		return entry;
	}

	static function now():String
		return xmpp.DelayedDelivery.formatStamp(Date.now());

	function file(chat:String):String
		return '$dir/${chat.toLowerCase()}.jsonl';

	/** Appends `entry` to the log of `chat` (bare jid); the directory and files readable only by you **/
	function write(chat:String, entry:Entry) {
		final path = file(chat);
		try {
			if (!FileSystem.exists(dir)) {
				FileSystem.createDirectory(dir);
				if (Sys.systemName() != "Windows")
					Sys.command("chmod", ["700", dir]);
			}
			final created = !FileSystem.exists(path);
			final output = File.append(path, false);
			output.writeString(Json.stringify(entry) + "\n");
			output.close();
			if (created && Sys.systemName() != "Windows")
				Sys.command("chmod", ["600", path]);
		} catch (e)
			Term.error('chatlog: cannot write $path: $e');
	}
}
