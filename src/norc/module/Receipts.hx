package norc.module;

import norc.Commands;
import norc.Module;
import norc.Term;
import norc.module.Messages;
import xmpp.DeliveryReceipts;
import xmpp.Jid;
import xmpp.Message;
import xmpp.client.Stream;

using StringTools;

/**
	Message Delivery Receipts (XEP-0184): sent messages request a receipt, shown when the recipient's client got
	the message (`✓`, and the `receipt` event). Requests are answered for contacts who may see your presence
	(a receipt reveals that you are online).
**/
class Receipts implements Module {
	/** Sent messages waiting for a receipt, at most this many **/
	static inline var MAX_PENDING = 200;

	final messages:Messages;
	final emit:Emit;

	/** The name of a contact (bare jid), or the jid **/
	final name:String->String;

	/** The contact (bare jid) may see the own presence **/
	final seesPresence:String->Bool;

	var stream:Null<Stream>;

	/** Ids of sent messages waiting for a receipt, in the order sent **/
	final pending = new Array<{id:String, to:String, body:String}>();

	public function new(messages:Messages, emit:Emit, name:String->String, seesPresence:String->Bool) {
		this.messages = messages;
		this.emit = emit;
		this.name = name;
		this.seesPresence = seesPresence;
		messages.outgoing.push(request);
		messages.incoming.push(receive);
	}

	public function commands():Array<Commands.Command>
		return [];

	public function features():Array<String>
		return [DeliveryReceipts.XMLNS];

	public function attach(stream:Stream)
		this.stream = stream;

	public function online() {}

	public function detach()
		stream = null;

	/** Requests a receipt for a sent chat message **/
	function request(m:Message) {
		if (m.body == null || m.type == groupchat)
			return;
		DeliveryReceipts.requestReceipt(m);
		pending.push({id: m.id, to: Jid.parseBare(m.to), body: m.body});
		if (pending.length > MAX_PENDING)
			pending.shift();
	}

	function receive(i:Incoming):Bool {
		final m = i.message;
		if (m.from == null)
			return false;
		final id = DeliveryReceipts.receipt(m);
		if (id != null) {
			// a receipt of a message of this client (not a copy of one of another client)
			final index = (i.carbon == null) ? indexOf(id, Jid.parseBare(m.from)) : -1;
			if (index != -1) {
				final p = pending[index];
				pending.splice(index, 1);
				Term.println(Term.timestamp(Date.now()) + ' ' + Term.style('✓ ${name(p.to)}: ${excerpt(p.body)}', 2));
				emit("receipt", [p.to, id], {from: m.from, name: name(p.to), id: id});
			}
			return m.body == null;
		}
		// answer requests of contacts, not of copies (the other client answers) or delayed messages
		if (i.carbon == null && m.body != null && m.type != groupchat && seesPresence(Jid.parseBare(m.from)) && stream != null) {
			final receipt = DeliveryReceipts.createReceipt(m);
			if (receipt != null)
				stream.send(receipt);
		}
		return false;
	}

	function indexOf(id:Null<String>, from:String):Int {
		for (i in 0...pending.length)
			if (pending[i].id == id && pending[i].to == from)
				return i;
		return -1;
	}

	/** The start of a message, on one line **/
	static function excerpt(body:String):String {
		final line = body.split("\n")[0];
		return (line.length > 40 || body.contains("\n")) ? line.substr(0, 40) + "…" : line;
	}
}
