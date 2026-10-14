package norc.module;

import norc.Commands;
import norc.Module;
import norc.Term;
import norc.module.Messages;
import xmpp.Response;
import xmpp.client.Stream;

/**
	Message Carbons (XEP-0280): copies of the messages sent and received by the other clients of the account,
	so conversations are complete on every client. Enabled after the login (unless disabled: `carbons = 0`).
**/
class Carbons implements Module {
	final messages:Messages;
	final enabled:Bool;

	var stream:Null<Stream>;

	public function new(messages:Messages, enabled:Bool) {
		this.messages = messages;
		this.enabled = enabled;
		messages.incoming.push(unwrap);
	}

	public function commands():Array<Commands.Command>
		return [];

	public function features():Array<String>
		return [];

	public function attach(stream:Stream)
		this.stream = stream;

	public function online() {
		if (!enabled)
			return;
		xmpp.Carbons.enableMessageCarbons(stream, res -> switch res {
			case Error(e): Term.info('message carbons not available: ${e.condition}');
			case Result(_):
		});
	}

	public function detach()
		stream = null;

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
