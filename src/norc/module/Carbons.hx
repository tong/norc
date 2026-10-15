package norc.module;

import norc.Module;
import norc.Term;
import norc.module.Messages;

/**
	Message Carbons (XEP-0280): copies of the messages sent and received by the other clients of the account,
	so conversations are complete on every client. Enabled after the login (unless disabled: `carbons = 0`).
**/
class Carbons extends Module {
	final messages:Messages;
	final enabled:Bool;

	public function new(context:Context, messages:Messages, enabled:Bool) {
		super(context);
		this.messages = messages;
		this.enabled = enabled;
		messages.incoming.push(unwrap);
	}

	override public function online()
		if (enabled)
			xmpp.Carbons.enableMessageCarbons(stream, res -> if (res.error != null) Term.info('message carbons not available: ${Term.errorText(res.error)}'));

	/** A copy is processed as message of its own (copies of forged senders are ignored) **/
	function unwrap(m:Incoming):Bool {
		if (m.carbon != null || stream == null)
			return false;
		final copy = xmpp.Carbons.getCarbon(stream, m.message);
		if (copy == null)
			return false;
		messages.receive(copy.message, copy.sent ? sent : received);
		return true;
	}
}
