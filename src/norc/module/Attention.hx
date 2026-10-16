package norc.module;

import norc.Commands;
import norc.Module;
import norc.Output;
import norc.Term;
import norc.module.Messages;
import xmpp.Attention as XmppAttention;
import xmpp.Jid;
import xmpp.Message;

/**
	Attention (XEP-0224): `/attention` gets the attention of a contact; attention requests of contacts in the roster
	ring the terminal bell and emit the `attention` event. Disabled with `attention = 0`.
**/
class Attention extends Module {
	final contacts:Contacts;
	final enabled:Bool;

	public function new(context:Context, messages:Messages, contacts:Contacts, enabled:Bool) {
		super(context);
		this.contacts = contacts;
		this.enabled = enabled;
		messages.incoming.push(receive);
	}

	override public function commands():Array<Commands.Command>
		return [
			{
				name: "attention",
				args: "<jid> [text...]",
				description: "get the attention of a contact (their client may ring or flash), with an optional message",
				online: true,
				run: (args, out) -> attention(args[0], args[1], out)
			}
		];

	override public function features():Array<String>
		return enabled ? [XmppAttention.XMLNS] : [];

	function attention(input:String, text:Null<String>, out:Output) {
		final to = contacts.resolve(input, out);
		if (to == null)
			return;
		stream.send(XmppAttention.captureAttention(new Message(to, text)));
		out.info('asked ${contacts.name(Jid.parseBare(to))} for attention');
	}

	/** Attention requests of contacts (not copies of other own clients) **/
	function receive(i:Incoming):Bool {
		final m = i.message;
		if (!enabled || i.carbon != null || m.from == null || !XmppAttention.wantsAttention(m))
			return false;
		final from = Jid.parseBare(m.from);
		if (!contacts.contains(from))
			return m.body == null;
		// with the terminal bell
		Term.notice('${contacts.name(from)} wants your attention' + (m.body != null ? ': ${m.body}' : '') + '\x07', 1);
		emit("attention", [from, m.body ?? ""], {from: m.from, name: contacts.name(from), text: m.body});
		return true;
	}
}
