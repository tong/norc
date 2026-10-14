package norc.module;

import norc.Commands;
import norc.Module;
import norc.Output;
import xmpp.Jid;
import xmpp.Ping;
import xmpp.Response;
import xmpp.client.Stream;

/**
	XMPP Ping (XEP-0199): `/ping` checks that a server or client is reachable and shows the round-trip time.
	Pings of others are answered by the client.
**/
class Pings implements Module {
	/** A contact name to its jid, other input unchanged **/
	final resolve:String->String;

	/** The available full jids of a bare jid **/
	final resources:String->Array<String>;

	var stream:Null<Stream>;

	public function new(resolve:String->String, resources:String->Array<String>) {
		this.resolve = resolve;
		this.resources = resources;
	}

	public function commands():Array<Commands.Command>
		return [
			{
				name: "ping",
				args: "[jid]",
				description: "ping a server or client and show the round-trip time (each online client of a contact; default: your server)",
				online: true,
				run: (args, out) -> ping(args[0], out)
			}
		];

	public function features():Array<String>
		return [];

	public function attach(stream:Stream)
		this.stream = stream;

	public function online() {}

	public function detach()
		stream = null;

	function ping(input:Null<String>, out:Output) {
		final jid = (input != null) ? resolve(input) : stream.domain;
		final online = (Jid.parseNode(jid) != null && Jid.parseResource(jid) == null) ? resources(jid) : [];
		final targets = (online.length > 0) ? online : [jid];
		for (target in targets) {
			final done = out.wait();
			final start = haxe.Timer.stamp();
			Ping.ping(stream, target, res -> {
				final ms = Math.round((haxe.Timer.stamp() - start) * 1000);
				switch res {
					case Result(_):
						out.data({jid: target, ms: ms}, () -> out.print('$target: pong in $ms ms'));
					case Error(e):
						out.error('$target: ${e.condition}' + (e.text != null ? ': ${e.text}' : '') + ' ($ms ms)');
				}
				done();
			});
		}
	}
}
