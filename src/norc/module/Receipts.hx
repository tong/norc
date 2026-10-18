package norc.module;

import norc.Module;
import norc.Term;
import norc.module.Messages;
import xmpp.DeliveryReceipts;
import xmpp.Jid;
import xmpp.Message;

using StringTools;

/**
	Message Delivery Receipts (XEP-0184): sent messages request a receipt, shown when the recipient's client got
	the message (`✓`, and the `receipt` event). Requests are answered for contacts who may see your presence
	(a receipt reveals that you are online).
**/
class Receipts extends Module {
	/** Sent messages waiting for a receipt, at most this many **/
	static inline var MAX_PENDING = 200;

	final contacts:Contacts;
	final messages:Messages;

	/** Sent messages waiting for a receipt, in the order sent **/
	final pending = new Array<{id:String, to:String}>();

	public function new(context:Context, messages:Messages, contacts:Contacts) {
		super(context);
		this.contacts = contacts;
		this.messages = messages;
		messages.outgoing.push(requestReceipt);
		messages.incoming.push(receive);
	}

	override public function features():Array<String>
		return [DeliveryReceipts.XMLNS];

	/** Requests a receipt for a sent chat message **/
	function requestReceipt(m:Message) {
		if (m.body == null || m.type == groupchat)
			return;
		DeliveryReceipts.requestReceipt(m);
		pending.push({id: m.id, to: Jid.parseBare(m.to)});
		if (pending.length > MAX_PENDING)
			pending.shift();
	}

	function receive(i:Incoming):Bool {
		final m = i.message;
		if (m.from == null)
			return false;
		final from = Jid.parseBare(m.from);
		final id = DeliveryReceipts.receipt(m);
		if (id != null) {
			// a receipt of a message of this client (not a copy of one of another client)
			final p = (i.carbon == null) ? Lambda.find(pending, p -> p.id == id && p.to == from) : null;
			if (p != null) {
				pending.remove(p);
				// at the end of the message if it is still on the screen, else a short line (not the message again)
				if (!Term.mark(messages.shownAt(id), " " + Term.style("✓", 32)))
					Term.notice('✓ delivered to ${contacts.name(from)}');
				emit("receipt", [from, id], {from: m.from, name: contacts.name(from), id: id});
			}
			return m.body == null;
		}
		// answer requests of contacts, not of copies (the other client answers)
		if (i.carbon == null && m.body != null && m.type != groupchat && contacts.seesPresence(from) && stream != null) {
			final receipt = DeliveryReceipts.createReceipt(m);
			if (receipt != null)
				stream.send(receipt);
		}
		return false;
	}
}
