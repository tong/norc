package norc.module;

import norc.Commands;
import norc.Module;
import norc.Output;
import norc.Term;
import xmpp.Block;
import xmpp.Response;
import xmpp.XML;
import xmpp.client.Stream;

/**
	Blocking communication with other entities (XEP-0191): `/block`.
	The server blocks, for all clients of the account; changes are pushed to all of them.
**/
class Blocking implements Module {
	/** Blocked jids, as last received from the server **/
	var blocked = new Array<String>();

	var stream:Null<Stream>;

	/** A contact name to its jid, other input unchanged **/
	final resolve:String->String;

	public function new(resolve:String->String) {
		this.resolve = resolve;
	}

	public function commands():Array<Commands.Command>
		return [
			{
				name: "block",
				description: "list blocked jids",
				online: true,
				run: (args, out) -> list(out),
				subcommands: [
					{
						name: "add",
						args: "<jid>",
						description: "block a jid, contact or domain (on the server, for all your clients)",
						online: true,
						run: (args, out) -> block(resolve(args[0]), out)
					},
					{
						name: "remove",
						args: "[jid]",
						description: "unblock a jid, or all without jid",
						online: true,
						run: (args, out) -> unblock(args[0] != null ? resolve(args[0]) : null, out)
					}
				]
			}
		];

	public function features():Array<String>
		return [];

	public function attach(stream:Stream) {
		this.stream = stream;
		Block.handlePushes(stream, (isBlocked, jids) -> {
			if (isBlocked) {
				for (jid in jids)
					if (!blocked.contains(jid))
						blocked.push(jid);
				Term.info('blocked: ${jids.join(", ")}');
			} else if (jids.length == 0) {
				blocked = [];
				Term.info("unblocked all");
			} else {
				blocked = blocked.filter(j -> !jids.contains(j));
				Term.info('unblocked: ${jids.join(", ")}');
			}
		});
	}

	public function online() {
		// requesting the list also subscribes to the pushes of changes
		Block.getBlocklist(stream, res -> switch res {
			case Result(payload):
				blocked = (payload == null) ? [] : Block.getItems(payload);
			case Error(e):
				// the server doesn't support blocking
				blocked = [];
		});
	}

	public function detach()
		stream = null;

	function list(out:Output) {
		final done = out.wait();
		Block.getBlocklist(stream, res -> {
			switch res {
				case Result(payload):
					blocked = (payload == null) ? [] : Block.getItems(payload);
					out.data({blocked: blocked.copy()}, () -> {
						if (blocked.length == 0)
							out.info("no blocked jids");
						for (jid in blocked)
							out.print('  $jid');
					});
				case Error(e):
					out.error('cannot load the block list: ${errorText(e)}');
			}
			done();
		});
	}

	function block(jid:String, out:Output) {
		final done = out.wait();
		Block.block(stream, [jid], res -> {
			switch res {
				case Result(_): out.info('blocked $jid');
				case Error(e): out.error('cannot block $jid: ${errorText(e)}');
			}
			done();
		});
	}

	function unblock(jid:Null<String>, out:Output) {
		final done = out.wait();
		Block.unblock(stream, jid != null ? [jid] : null, res -> {
			switch res {
				case Result(_): out.info(jid != null ? 'unblocked $jid' : 'unblocked all');
				case Error(e): out.error('cannot unblock ${jid ?? "all"}: ${errorText(e)}');
			}
			done();
		});
	}

	static function errorText(e:xmpp.Stanza.Error):String
		return switch (e.condition : String) {
			case "service-unavailable", "feature-not-implemented": 'your server does not support blocking (XEP-0191)';
			case c: c + (e.text != null ? ' (${e.text})' : '');
		}
}
