package norc.module;

import norc.Commands;
import norc.Module;
import norc.Output;
import norc.Term;
import norc.module.Messages;
import xmpp.Attention;
import xmpp.Jid;
import xmpp.Message;

/**
	Attention (XEP-0224): `/buzz` gets the attention of a contact; attention requests of contacts in the roster
	ring the terminal bell and emit the `attention` event. Disabled with `attention = 0`.
**/
class Buzz extends Module {
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
				name: "buzz",
				args: "<jid> [text...]",
				description: "get the attention of a contact (their client may ring or flash), with an optional message",
				online: true,
				run: (args, out) -> buzz(args[0], args[1], out)
			}
		];

	override public function features():Array<String>
		return enabled ? [Attention.XMLNS] : [];

	function buzz(input:String, text:Null<String>, out:Output) {
		final to = contacts.resolve(input, out);
		if (to == null)
			return;
		stream.send(Attention.captureAttention(new Message(to, text)));
		out.info('buzzed ${contacts.name(Jid.parseBare(to))}');
	}

	/** Attention requests of contacts (not copies of other own clients) **/
	function receive(i:Incoming):Bool {
		final m = i.message;
		if (!enabled || i.carbon != null || m.from == null || !Attention.wantsAttention(m))
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
