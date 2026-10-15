package norc.module;

import norc.Commands;
import norc.Module;
import norc.Output;
import norc.Term;
import xmpp.Jid;
import xmpp.LastMessageCorrection;
import xmpp.Message;
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
**/
class Messages extends Module {
	/** Called with each sent message before it is sent, e.g. to add elements **/
	public final outgoing = new Array<Message->Void>();

	/**
		Called with each received message (also without body, not with errors) before it is shown;
		returning `true` ends its processing: not shown, no event.
	**/
	public final incoming = new Array<Incoming->Bool>();

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

	/** Sends a chat message with `body` to `to` (a jid), with additional `elements`; returns it **/
	public function send(to:String, body:String, ?elements:Array<XML>):Message {
		final m = new Message(to, body);
		m.id = xmpp.Stream.makeRandomId();
		for (e in elements ?? [])
			m.properties.push(e);
		for (f in outgoing)
			f(m);
		stream.send(m);
		sentEvent(m, false);
		return m;
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
		// a correction of the last message (XEP-0308), checked by the module of corrections
		final replaces = LastMessageCorrection.correction(m);
		final corrected = (replaces != null) ? " ✎" : "";
		if (carbon == sent) {
			if (m.to == null)
				return;
			final to = Jid.parseBare(m.to);
			show(to, m.body, delay?.date, '→ <${contacts.name(to)}>$corrected');
			sentEvent(m, true);
			return;
		}
		final from = (m.from != null) ? Jid.parseBare(m.from) : stream.domain;
		show(from, m.body, delay?.date, (replaces != null) ? '<${contacts.name(from)}>$corrected' : null);
		emit("message", [from, m.body], {
			from: m.from ?? from,
			name: contacts.name(from),
			body: m.body,
			id: m.id,
			type: m.type ?? "normal",
			delayed: delay != null,
			carbon: carbon == received,
			replaces: replaces
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
		emit("sent", [to, m.body], {
			to: m.to,
			name: contacts.name(to),
			body: m.body,
			id: m.id,
			carbon: carbon,
			replaces: LastMessageCorrection.correction(m)
		});
	}

	/**
		Prints a message of `jid` (bare): `12:03 <alice> text`, continuation lines aligned with the first.
		`date` is the time it was sent if delayed, `marker` replaces `<name>` (e.g. for sent messages).
	**/
	function show(jid:String, body:String, ?date:Date, ?marker:String) {
		final time = Term.timestamp(date ?? Date.now());
		final label = marker ?? '<${contacts.name(jid)}>';
		final lines = body.split("\n");
		Term.println('$time ' + Term.style(label, 36) + ' ' + lines[0]);
		final indent = "".lpad(" ", time.length + label.length + 2);
		for (i in 1...lines.length)
			Term.println(indent + lines[i]);
	}

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
