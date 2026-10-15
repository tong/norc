package norc.module;

import norc.Commands;
import norc.Module;
import norc.Output;
import norc.module.Messages;
import xmpp.Jid;
import xmpp.LastMessageCorrection;
import xmpp.XML;

/**
	Last Message Correction (XEP-0308): `/correct` replaces your last sent message; corrections of contacts are
	shown with `✎` (the `message` event has `replaces`, the id of the corrected message).
	A correction is accepted only for the last message of its sender, else it is shown as a new message.
**/
class Corrections extends Module {
	final messages:Messages;

	/** The last sent message (not a correction), the one `/correct` replaces **/
	var last:Null<{to:String, id:String}>;

	/** Id of the last received message of each contact (bare jid), the only one they can correct **/
	final received = new Map<String, String>();

	public function new(context:Context, messages:Messages) {
		super(context);
		this.messages = messages;
		messages.outgoing.push(m -> {
			if (m.body != null && m.id != null && LastMessageCorrection.correction(m) == null)
				last = {to: m.to, id: m.id};
		});
		messages.incoming.push(receive);
	}

	override public function commands():Array<Commands.Command>
		return [
			{
				name: "correct",
				args: "<text...>",
				description: "correct your last sent message: replace it with text (\\n for a newline)",
				online: true,
				run: (args, out) -> correct(StringTools.replace(args[0], "\\n", "\n"), out)
			}
		];

	override public function features():Array<String>
		return [LastMessageCorrection.XMLNS];

	function correct(body:String, out:Output) {
		final l = last;
		if (l == null) {
			out.error("no message to correct");
			return;
		}
		// refers to the original message, also when correcting a correction
		messages.send(l.to, body, [XML.create("replace").set("xmlns", LastMessageCorrection.XMLNS).set("id", l.id)]);
	}

	/** Remembers the last message of each contact, drops the correction mark of invalid corrections **/
	function receive(i:Incoming):Bool {
		final m = i.message;
		if (m.body == null || m.from == null || i.carbon == sent)
			return false;
		final from = Jid.parseBare(m.from);
		final id = LastMessageCorrection.correction(m);
		if (id == null) {
			if (m.id != null)
				received.set(from, m.id);
		} else if (received.get(from) != id)
			for (e in m.properties.copy())
				if (e.name == "replace" && e.is(LastMessageCorrection.XMLNS))
					m.properties.remove(e);
		return false;
	}
}
