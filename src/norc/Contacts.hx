package norc;

import xmpp.Jid;
import xmpp.Response;
import xmpp.XML;
import xmpp.client.Roster;
import xmpp.client.Stream;

using StringTools;
using xmpp.client.Roster;

/**
	The roster (contact list) and presence subscriptions: `/roster` and its subcommands.
**/
class Contacts implements Module {
	/** The roster, as last received from the server (kept while disconnected) **/
	public var items(default, null) = new Array<RosterItem>();

	/** Contacts asking to see the own presence **/
	final requests = new Array<String>();

	/** Returns a description of the presence of a bare jid, `null` if offline **/
	final presence:String->Null<String>;

	var stream:Null<Stream>;

	public function new(presence:String->Null<String>) {
		this.presence = presence;
	}

	public function commands():Array<Commands.Command>
		return [
			{
				name: "roster",
				description: "list contacts",
				run: args -> list(),
				subcommands: [
					{
						name: "add",
						args: "<jid> [name...]",
						description: "add a contact and ask to see their presence",
						online: true,
						run: args -> add(args[0], args[1])
					},
					{
						name: "remove",
						aliases: ["rm"],
						args: "<jid>",
						description: "remove a contact (ends the presence subscriptions both ways)",
						online: true,
						run: args -> remove(args[0])
					},
					{
						name: "rename",
						args: "<jid> [name...]",
						description: "set the name of a contact, or clear it",
						online: true,
						run: args -> update(args[0], item -> item.name = args[1])
					},
					{
						name: "groups",
						args: "<jid> [groups...]",
						description: "set the groups of a contact (comma separated), or clear them",
						online: true,
						run: args -> update(args[0], item -> item.groups = parseGroups(args[1]))
					},
					{
						name: "requests",
						description: "list contacts asking to see your presence",
						run: args -> listRequests()
					},
					{
						name: "accept",
						args: "<jid>",
						description: "allow a contact to see your presence (and ask to see theirs)",
						online: true,
						run: args -> accept(args[0])
					},
					{
						name: "deny",
						args: "<jid>",
						description: "refuse a request to see your presence, or stop sharing it",
						online: true,
						run: args -> deny(args[0])
					}
				]
			}
		];

	public function features():Array<String>
		return [];

	public function attach(stream:Stream) {
		this.stream = stream;
		Roster.handleRequests(stream, (item, ver) -> push(item));
	}

	public function online() {
		stream.loadRoster(res -> switch res {
			case Result(payload):
				items = Roster.parseRoster(payload).items;
			case Error(e):
				Term.error('cannot load roster: ${e.condition}');
		});
	}

	public function detach() {
		stream = null;
		requests.resize(0);
	}

	/** The name of a contact, or the jid **/
	public function name(bare:String):String {
		final item = find(bare);
		return (item != null && item.name != null && item.name.length > 0) ? item.name : bare;
	}

	/** A contact asks to see the own presence **/
	public function request(from:String) {
		final bare = Jid.parseBare(from);
		if (!requests.contains(bare))
			requests.push(bare);
	}

	function list() {
		if (items.length == 0) {
			Term.info("roster is empty");
			return;
		}
		final sorted = items.copy();
		sorted.sort((a, b) -> Reflect.compare(name(a.jid).toLowerCase(), name(b.jid).toLowerCase()));
		for (item in sorted) {
			final state = presence(item.jid);
			final details = [(item.subscription ?? none : String)];
			if (item.ask == "subscribe")
				details.push("asked");
			if (item.groups.length > 0)
				details.push(item.groups.join(", "));
			Sys.println('  ' + (item.name != null && item.name.length > 0 ? '${item.name} <${item.jid}>' : item.jid)
				+ (state != null ? Term.style(' $state', 32) : '') + Term.style(' [${details.join("; ")}]', 2));
		}
	}

	function add(jid:String, ?name:String) {
		if (!valid(jid))
			return;
		final bare = Jid.parseBare(jid);
		final groups = find(bare)?.groups ?? [];
		stream.addRosterItem(bare, name, groups, res -> switch res {
			case Result(_):
				stream.subscribePresence(bare);
				Term.info('added $bare, asked to see their presence');
			case Error(e):
				Term.error('cannot add $bare: ${e.condition}');
		});
	}

	function remove(jid:String) {
		final bare = Jid.parseBare(jid);
		if (find(bare) == null) {
			Term.error('$bare is not in the roster');
			return;
		}
		stream.removeRosterItem(bare, res -> switch res {
			case Result(_): Term.info('removed $bare');
			case Error(e): Term.error('cannot remove $bare: ${e.condition}');
		});
	}

	/** Changes a contact (name or groups) **/
	function update(jid:String, change:RosterItem->Void) {
		final bare = Jid.parseBare(jid);
		final current = find(bare);
		if (current == null) {
			Term.error('$bare is not in the roster');
			return;
		}
		final item:RosterItem = {jid: bare, name: current.name, groups: current.groups.copy()};
		change(item);
		stream.addRosterItem(bare, item.name, item.groups, res -> switch res {
			case Result(_): Term.info('updated $bare');
			case Error(e): Term.error('cannot update $bare: ${e.condition}');
		});
	}

	function listRequests() {
		if (requests.length == 0)
			Term.info("no subscription requests");
		for (jid in requests)
			Sys.println('  $jid');
	}

	function accept(jid:String) {
		if (!valid(jid))
			return;
		final bare = Jid.parseBare(jid);
		stream.approveSubscription(bare);
		requests.remove(bare);
		// ask back, unless already subscribed to their presence
		final item = find(bare);
		final subscribed = item != null && (item.subscription == to || item.subscription == both || item.ask == "subscribe");
		if (!subscribed)
			stream.subscribePresence(bare);
		Term.info('$bare can see your presence' + (subscribed ? '' : ', asked to see theirs'));
	}

	function deny(jid:String) {
		if (!valid(jid))
			return;
		final bare = Jid.parseBare(jid);
		stream.cancelSubscription(bare);
		requests.remove(bare);
		Term.info('$bare can not see your presence');
	}

	function push(item:RosterItem) {
		items = items.filter(i -> i.jid != item.jid);
		if ((item.subscription : String) != "remove")
			items.push(item);
	}

	function find(bare:String):Null<RosterItem> {
		for (item in items)
			if (item.jid == bare)
				return item;
		return null;
	}

	/** A contact jid: `user@domain` (a domain alone is most likely a mistyped command) **/
	static function valid(jid:String):Bool {
		if (Jid.isValid(jid) && Jid.parseNode(jid) != null)
			return true;
		Term.error('invalid jid: $jid (expected user@domain)');
		return false;
	}

	static function parseGroups(groups:Null<String>):Array<String>
		return (groups == null) ? [] : [for (g in groups.split(",")) if (g.trim().length > 0) g.trim()];
}
