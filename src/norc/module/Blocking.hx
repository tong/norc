package norc.module;

import norc.Commands;
import norc.Module;
import norc.Output;
import norc.Term;
import xmpp.Block;
import xmpp.XML;
import xmpp.client.Stream;

/**
	Blocking communication with other entities (XEP-0191): `/block`.
	The server blocks, for all clients of the account; changes are pushed to all of them.
**/
class Blocking extends Module {
	final contacts:Contacts;

	/** Blocked jids, as last received from the server **/
	var blocked = new Array<String>();

	public function new(context:Context, contacts:Contacts) {
		super(context);
		this.contacts = contacts;
	}

	override public function commands():Array<Commands.Command>
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
						run: (args, out) -> block(contacts.jid(args[0]), out)
					},
					{
						name: "remove",
						args: "[jid]",
						description: "unblock a jid, or all without jid",
						online: true,
						run: (args, out) -> unblock(args[0] != null ? contacts.jid(args[0]) : null, out)
					}
				]
			}
		];

	override public function attach(stream:Stream) {
		super.attach(stream);
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

	// requesting the list also subscribes to the pushes of changes (an error: the server doesn't support blocking)
	override public function online()
		Block.getBlocklist(stream, res -> blocked = items(res.payload));

	function list(out:Output)
		request(out, "cannot load the block list", handler -> Block.getBlocklist(stream, handler), payload -> {
			blocked = items(payload);
			out.data({blocked: blocked.copy()}, () -> {
				if (blocked.length == 0)
					out.info("no blocked jids");
				for (jid in blocked)
					out.print('  $jid');
			});
		});

	function block(jid:String, out:Output)
		request(out, 'cannot block $jid', handler -> Block.block(stream, [jid], handler), _ -> out.info('blocked $jid'));

	function unblock(jid:Null<String>, out:Output)
		request(out, 'cannot unblock ${jid ?? "all"}', handler -> Block.unblock(stream, (jid != null) ? [jid] : null, handler),
			_ -> out.info('unblocked ${jid ?? "all"}'));

	static function items(payload:Null<XML>):Array<String>
		return (payload == null) ? [] : Block.getItems(payload);
}
