package norc.module;

import norc.Commands;
import norc.Module;
import norc.Output;
import norc.Term;
import xmpp.Jid;
import xmpp.LastMessageCorrection;
import xmpp.Message;
import xmpp.MessageReply;
import xmpp.PubSub;
import xmpp.XML;
import xmpp.client.Stream;

using StringTools;
using xmpp.DelayedDelivery;

/** A copy of a message of another client of the account (Message Carbons) **/
enum abstract CarbonCopy(String) to String {
	/** Sent by the other client: `to` is the contact **/
	var sent;

	/** Received by the other client **/
	var received;
}

/** A received message **/
typedef Incoming = {
	var message:Message;

	/** For a copy of a message of another client of the account, `null` for a message of this client **/
	var ?carbon:CarbonCopy;
}

/**
	Chat messages: `/msg`, showing received messages, the `message` and `sent` events.

	Other modules extend messages: `outgoing` adds elements to sent messages (e.g. a receipt request),
	`incoming` handles received messages before they are shown (e.g. receipts, chat states).
	The messages shown are kept in `recent` (for reactions and replies); a reply (XEP-0461) is shown with a line
	quoting the message replied to, its events have the text without the quote.
**/
class Messages extends Module {
	/** Called with each sent message before it is sent, e.g. to add elements **/
	public final outgoing = new Array<Message->Void>();

	/**
		Called with each received message (also without body, not with errors) before it is shown;
		returning `true` ends its processing: not shown, no event.
	**/
	public final incoming = new Array<Incoming->Bool>();

	/** The last messages of each chat, also of rooms **/
	public final recent = new Recent();

	/**
		Called after a message was shown: its chat (bare jid of the contact or room), the message, sent by the user,
		in a room; e.g. to show its image
	**/
	public final displayed = new Array<(chat:String, m:Message, own:Bool, room:Bool) -> Void>();

	/** Where sent messages were shown (see `shownAt`), the last `MAX_SHOWN` **/
	final shown = new Map<String, LineEditor.Position>();

	final shownIds = new Array<String>();

	static inline var MAX_SHOWN = 100;

	final contacts:Contacts;

	public function new(context:Context, contacts:Contacts) {
		super(context);
		this.contacts = contacts;
	}

	override public function commands():Array<Commands.Command>
		return [
			{
				name: "msg",
				args: "<jid> <text...>",
				description: "send a message to a jid or contact name (\\n for a newline)",
				online: true,
				run: (args, out) -> msg(args[0], args[1].replace("\\n", "\n"), out)
			}
		];

	override public function attach(stream:Stream) {
		super.attach(stream);
		stream.onMessage = m -> (m.type == error) ? failed(m) : receive(m);
	}

	/**
		Sends a chat message with `body` to `to` (a jid), with additional `elements`, changed by `prepare` before it is
		sent (e.g. a reply); returns it.
	**/
	public function send(to:String, body:String, ?elements:Array<XML>, ?prepare:Message->Void):Message {
		final m = new Message(to, body);
		m.id = xmpp.Stream.makeRandomId();
		for (e in elements ?? [])
			m.properties.push(e);
		if (prepare != null)
			prepare(m);
		for (f in outgoing)
			f(m);
		stream.send(m);
		// a room sends messages back to all occupants
		if (m.type != groupchat) {
			showSent(m);
			remember(Jid.parseBare(to), m, null, true);
			for (f in displayed)
				f(Jid.parseBare(to), m, true, false);
		}
		sentEvent(m, false);
		return m;
	}

	/**
		The text of `m` as shown in `chat` (bare jid): a reply starts with a line quoting the message replied to
		(`↪ <name> text`).
	**/
	public function text(chat:String, m:Message):String {
		final body = MessageReply.getBody(m) ?? "";
		final reply = MessageReply.getReply(m);
		if (reply == null)
			return body;
		final r = recent.find(chat, reply.id);
		final quote = (r != null) ? '<${r.name}> ${r.body}' : quoted(m.body) ?? "a message";
		return Term.style("↪ " + Recent.excerpt(quote, 60), 2) + "\n" + body;
	}

	/**
		Keeps a message shown in `chat` (bare jid) in `recent`: `id` the id to refer to it (the id of the message if
		`null`), a correction changes the text of the corrected message.
	**/
	public function remember(chat:String, m:Message, ?id:String, own:Bool, ?name:String) {
		final body = MessageReply.getBody(m);
		final stanzaId = id != null;
		final id = id ?? m.id;
		if (id == null || body == null)
			return;
		final replaces = LastMessageCorrection.correction(m);
		if (replaces != null) {
			recent.correct(chat, replaces, body);
			return;
		}
		recent.add(chat, {
			id: id,
			from: m.from,
			name: name ?? (own ? "you" : contacts.name(chat)),
			body: body,
			own: own,
			messageId: (m.id != id) ? m.id : null,
			stanzaId: stanzaId
		});
	}

	/** The quote at the start of `body` (lines starting with `>`), without `>`; `null` without **/
	static function quoted(body:Null<String>):Null<String> {
		final lines = [];
		for (l in (body ?? "").split("\n")) {
			if (!l.startsWith(">"))
				break;
			lines.push(l.substr(1).trim());
		}
		return (lines.length > 0) ? lines.join(" ") : null;
	}

	/**
		Processes a received message (not an error), or a copy of a message of another client of the account:
		the `incoming` handlers, then it is shown.
	**/
	public function receive(m:Message, ?carbon:CarbonCopy) {
		for (f in incoming)
			if (f({message: m, carbon: carbon}))
				return;
		if (m.body == null)
			return;
		final delay = m.delay();
		if (carbon == sent) {
			if (m.to == null)
				return;
			showSent(m, delay?.date);
			remember(Jid.parseBare(m.to), m, null, true);
			for (f in displayed)
				f(Jid.parseBare(m.to), m, true, false);
			sentEvent(m, true);
			return;
		}
		// a correction of the last message (XEP-0308), checked by the module of corrections
		final replaces = LastMessageCorrection.correction(m);
		final from = (m.from != null) ? Jid.parseBare(m.from) : stream.domain;
		show('<${contacts.name(from)}>' + corrected(m), from, text(from, m), delay?.date);
		remember(from, m, null, false);
		for (f in displayed)
			f(from, m, false, false);
		final body = MessageReply.getBody(m);
		final reply = MessageReply.getReply(m);
		emit("message", [from, body], {
			from: m.from ?? from,
			name: contacts.name(from),
			body: body,
			id: m.id,
			type: m.type ?? "normal",
			delayed: delay != null,
			carbon: carbon == received,
			replaces: replaces,
			reply_id: reply?.id,
			reply_to: reply?.to,
			avatar: contacts.avatars.get(from.toLowerCase())
		});
	}

	/**
		Handles the PEP notifications (XEP-0163) of `node` in a received message: `item` is called with the sender
		(bare jid) and the payload of each item (`null` if empty). Returns `true` if the message is such a notification.
	**/
	public static function pep(i:Incoming, node:String, item:(from:String, payload:Null<XML>) -> Void):Bool {
		final m = i.message;
		return switch (m.from != null) ?PubSub.getEvent
		(m) : null
		{
			case Items(n, items, _) if (n == node):
				for (e in items)
					item(Jid.parseBare(m.from), e.firstElement);
				true;
			case _:
				false;
		}
	}

	/** An error returned for a sent message, e.g. the recipient doesn't exist **/
	function failed(m:Message) {
		final from = m.from ?? stream.domain;
		Term.error('message error from ${Jid.parseBare(from)}: ${Term.errorText(m.error)}');
		final condition:String = m.error?.condition ?? "error";
		emit("error", ["message", condition], {kind: "message", text: condition, from: from});
	}

	/** The `sent` event: a message sent by this client, or by another client of the account (`carbon`) **/
	function sentEvent(m:Message, carbon:Bool) {
		final to = Jid.parseBare(m.to);
		final body = MessageReply.getBody(m);
		final reply = MessageReply.getReply(m);
		emit("sent", [to, body], {
			to: m.to,
			name: contacts.name(to),
			body: body,
			id: m.id,
			type: m.type ?? "normal",
			carbon: carbon,
			replaces: LastMessageCorrection.correction(m),
			reply_id: reply?.id,
			reply_to: reply?.to
		});
	}

	/** Prints a message sent by this client or another of the account: `12:03:41 → <alice> text`, in the own color **/
	function showSent(m:Message, ?date:Date) {
		final to = Jid.parseBare(m.to);
		final end = show('→ <${contacts.name(to)}>' + corrected(m), null, text(to, m), date, "", 0, to);
		if (end != null && m.id != null && date == null) {
			shown.set(m.id, end);
			shownIds.push(m.id);
			if (shownIds.length > MAX_SHOWN)
				shown.remove(shownIds.shift());
		}
	}

	/** ` ✎` for a correction of the last message (XEP-0308) **/
	static function corrected(m:Message):String
		return (LastMessageCorrection.correction(m) != null) ? " ✎" : "";

	/**
		Prints a message: `12:03:41 <alice> text`, continuation lines aligned with the first. `label` is in the color
		of `from` (a jid, `null`: own message), `date` is the time it was sent if delayed, `prefix` is printed before
		the label (e.g. the room), `prefixLength` is its length without styles.
	**/
	public static function show(label:String, from:Null<String>, body:String, ?date:Date, prefix = "", prefixLength = 0, ?avatar:String):Null<LineEditor.Position> {
		final time = Term.timestamp(date ?? Date.now());
		final lines = body.split("\n");
		// the avatar of the contact (of `avatar`, else of the sender) before the name: three columns
		final icon = Term.avatarBefore(avatar ?? from);
		var end = Term.println('$time $prefix' + icon + Term.name(label, from) + ' ' + lines[0]);
		final indent = "".lpad(" ", time.length + prefixLength + label.length + 2 + (icon.length > 0 ? 3 : 0));
		for (i in 1...lines.length)
			end = Term.println(indent + lines[i]);
		return end;
	}

	/** Where a message sent by this client was shown (the end of its last line), by id, e.g. to mark its receipt **/
	public function shownAt(id:String):Null<LineEditor.Position>
		return shown.get(id);

	function msg(input:String, body:String, out:Output) {
		final to = contacts.resolve(input, out);
		if (to == null)
			return;
		if (!Jid.isValid(to)) {
			out.error('invalid jid: $to');
			return;
		}
		send(to, body);
	}
}
