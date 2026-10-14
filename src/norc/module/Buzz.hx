package norc.module;

import norc.Commands;
import norc.Module;
import norc.Output;
import norc.Term;
import norc.module.Messages;
import xmpp.Attention;
import xmpp.Jid;
import xmpp.Message;
import xmpp.client.Stream;

/**
	Attention (XEP-0224): `/buzz` gets the attention of a contact; attention requests of contacts in the roster
	ring the terminal bell and emit the `attention` event. Disabled with `attention = 0`.
**/
class Buzz implements Module {
	final emit:Emit;
	final enabled:Bool;

	/** The jid of a contact given by name or jid, `null` (with an error) if unknown **/
	final resolve:(input:String, out:Output) -> Null<String>;

	/** The name of a contact (bare jid), or the jid **/
	final name:String->String;

	/** The bare jid is in the roster **/
	final isContact:String->Bool;

	var stream:Null<Stream>;

	public function new(messages:Messages, emit:Emit, resolve:(input:String, out:Output) -> Null<String>, name:String->String,
			isContact:String->Bool, enabled:Bool) {
		this.emit = emit;
		this.resolve = resolve;
		this.name = name;
		this.isContact = isContact;
		this.enabled = enabled;
		messages.incoming.push(receive);
	}

	public function commands():Array<Commands.Command>
		return [
			{
				name: "buzz",
				args: "<jid> [text...]",
				description: "get the attention of a contact (their client may ring or flash), with an optional message",
				online: true,
				run: (args, out) -> buzz(args[0], args[1], out)
			}
		];

	public function features():Array<String>
		return enabled ? [Attention.XMLNS] : [];

	public function attach(stream:Stream)
		this.stream = stream;

	public function online() {}

	public function detach()
		stream = null;

	function buzz(input:String, text:Null<String>, out:Output) {
		final to = resolve(input, out);
		if (to == null)
			return;
		stream.send(Attention.captureAttention(new Message(to, text)));
		out.info('buzzed ${name(Jid.parseBare(to))}');
	}

	/** Attention requests of contacts (not delayed, not copies of other own clients) **/
	function receive(i:Incoming):Bool {
		final m = i.message;
		if (!enabled || i.carbon != null || m.from == null || !Attention.wantsAttention(m))
			return false;
		final from = Jid.parseBare(m.from);
		if (!isContact(from))
			return m.body == null;
		// the terminal bell
		Term.println('\x07' + Term.timestamp(Date.now()) + ' ' + Term.style('${name(from)} wants your attention' + (m.body != null ? ': ${m.body}' : ''), 1));
		emit("attention", [from, m.body ?? ""], {from: m.from, name: name(from), text: m.body});
		return true;
	}
}
