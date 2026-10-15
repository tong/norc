package norc.module;

import norc.Commands;
import norc.Module;
import norc.Output;
import xmpp.Ping;

/**
	XMPP Ping (XEP-0199): `/ping` checks that a server or client is reachable and shows the round-trip time.
	Pings of others are answered by the client.
**/
class Pings extends Module {
	final contacts:Contacts;

	public function new(context:Context, contacts:Contacts) {
		super(context);
		this.contacts = contacts;
	}

	override public function commands():Array<Commands.Command>
		return [
			{
				name: "ping",
				args: "[jid]",
				description: "ping a server or client and show the round-trip time (each online client of a contact; default: your server)",
				online: true,
				run: (args, out) -> ping(args[0], out)
			}
		];

	function ping(input:Null<String>, out:Output)
		for (target in contacts.clients((input != null) ? contacts.jid(input) : stream.domain)) {
			final start = haxe.Timer.stamp();
			request(out, target, handler -> Ping.ping(stream, target, handler), _ -> {
				final ms = Math.round((haxe.Timer.stamp() - start) * 1000);
				out.data({jid: target, ms: ms}, () -> out.print('$target: pong in $ms ms'));
			});
		}
}
