package norc.module;

import norc.Commands;
import norc.Module;
import norc.Output;
import norc.Term;
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

	/** Emits an event (to hooks and API clients) **/
	final emit:Emit;

	public function new(emit:Emit, presence:String->Null<String>) {
		this.emit = emit;
		this.presence = presence;
	}

	public function commands():Array<Commands.Command>
		return [
			{
				name: "roster",
				description: "list contacts",
				run: (args, out) -> list(out),
				subcommands: [
					{
						name: "add",
						args: "<jid> [name...]",
						description: "add a contact and ask to see their presence",
						online: true,
						run: (args, out) -> add(args[0], args[1], out)
					},
					{
						name: "remove",
						aliases: ["rm"],
						args: "<jid>",
						description: "remove a contact (ends the presence subscriptions both ways)",
						online: true,
						run: (args, out) -> remove(args[0], out)
					},
					{
						name: "rename",
						args: "<jid> [name...]",
						description: "set the name of a contact, or clear it",
						online: true,
						run: (args, out) -> update(args[0], item -> item.name = args[1], out)
					},
					{
						name: "groups",
						args: "<jid> [groups...]",
						description: "set the groups of a contact (comma separated), or clear them",
						online: true,
						run: (args, out) -> update(args[0], item -> item.groups = parseGroups(args[1]), out)
					},
					{
						name: "requests",
						description: "list contacts asking to see your presence",
						run: (args, out) -> listRequests(out)
					},
					{
						name: "accept",
						args: "<jid>",
						description: "allow a contact to see your presence (and ask to see theirs)",
						online: true,
						run: (args, out) -> accept(args[0], out)
					},
					{
						name: "deny",
						args: "<jid>",
						description: "refuse a request to see your presence, or stop sharing it",
						online: true,
						run: (args, out) -> deny(args[0], out)
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

	/**
		The jid of a contact given by `input`: a jid (with `@`) as it is, else the roster name or the local part of
		the jid of exactly one contact (case-insensitive), or of a pending subscription request.
		A resource is kept (`alice/phone`). Returns `null` and writes an error to `out` if there is none or several.
	**/
	public function resolve(input:String, out:Output):Null<String> {
		final matches = lookup(input);
		if (matches.length == 1)
			return matches[0];
		out.error(matches.length == 0 ? 'unknown contact: $input' : '$input is ambiguous: ${matches.join(", ")}');
		return null;
	}

	/** Like `resolve`, but returns `input` if it matches no contact (e.g. a server) and without error **/
	public function resolveOptional(input:String):String {
		final matches = lookup(input);
		return (matches.length == 1) ? matches[0] : input;
	}

	/** The jids matching `input` (see `resolve`) **/
	function lookup(input:String):Array<String> {
		if (input.contains("@"))
			return [input];
		final i = input.indexOf("/");
		final name = ((i == -1) ? input : input.substr(0, i)).toLowerCase();
		final resource = (i == -1) ? "" : input.substr(i);
		final candidates = [for (item in items) {jid: item.jid, name: item.name}].concat([for (jid in requests) {jid: jid, name: null}]);
		// a roster name before the local part of a jid
		var matches = [for (c in candidates) if (c.name != null && c.name.toLowerCase() == name) c.jid];
		if (matches.length == 0)
			matches = [for (c in candidates) if ((Jid.parseNode(c.jid) ?? "").toLowerCase() == name) c.jid];
		final unique = new Array<String>();
		for (m in matches)
			if (!unique.contains(m))
				unique.push(m);
		return [for (m in unique) m + resource];
	}

	/** A contact asks to see the own presence **/
	public function request(from:String) {
		final bare = Jid.parseBare(from);
		if (!requests.contains(bare))
			requests.push(bare);
	}

	function list(out:Output) {
		final sorted = items.copy();
		sorted.sort((a, b) -> Reflect.compare(name(a.jid).toLowerCase(), name(b.jid).toLowerCase()));
		final contacts = [
			for (item in sorted)
				{
					jid: item.jid,
					name: (item.name != null && item.name.length > 0) ? item.name : null,
					subscription: (item.subscription ?? none : String),
					asked: item.ask == "subscribe",
					groups: item.groups,
					presence: presence(item.jid)
				}
		];
		out.data({contacts: contacts}, () -> {
			if (contacts.length == 0)
				out.info("roster is empty");
			for (c in contacts) {
				final details = [c.subscription];
				if (c.asked)
					details.push("asked");
				if (c.groups.length > 0)
					details.push(c.groups.join(", "));
				out.print('  ' + (c.name != null ? '${c.name} <${c.jid}>' : c.jid) + (c.presence != null ? Term.style(' ${c.presence}', 32) : '')
					+ Term.style(' [${details.join("; ")}]', 2));
			}
		});
	}

	function add(jid:String, ?name:String, out:Output) {
		if (!valid(jid, out))
			return;
		final bare = Jid.parseBare(jid);
		final groups = find(bare)?.groups ?? [];
		final done = out.wait();
		stream.addRosterItem(bare, name, groups, res -> {
			switch res {
				case Result(_):
					stream.subscribePresence(bare);
					out.info('added $bare, asked to see their presence');
				case Error(e):
					out.error('cannot add $bare: ${e.condition}');
			}
			done();
		});
	}

	function remove(jid:String, out:Output) {
		final jid = resolve(jid, out);
		if (jid == null)
			return;
		final bare = Jid.parseBare(jid);
		if (find(bare) == null) {
			out.error('$bare is not in the roster');
			return;
		}
		final done = out.wait();
		stream.removeRosterItem(bare, res -> {
			switch res {
				case Result(_): out.info('removed $bare');
				case Error(e): out.error('cannot remove $bare: ${e.condition}');
			}
			done();
		});
	}

	/** Changes a contact (name or groups) **/
	function update(jid:String, change:RosterItem->Void, out:Output) {
		final jid = resolve(jid, out);
		if (jid == null)
			return;
		final bare = Jid.parseBare(jid);
		final current = find(bare);
		if (current == null) {
			out.error('$bare is not in the roster');
			return;
		}
		final item:RosterItem = {jid: bare, name: current.name, groups: current.groups.copy()};
		change(item);
		final done = out.wait();
		stream.addRosterItem(bare, item.name, item.groups, res -> {
			switch res {
				case Result(_): out.info('updated $bare');
				case Error(e): out.error('cannot update $bare: ${e.condition}');
			}
			done();
		});
	}

	function listRequests(out:Output)
		out.data({requests: requests.copy()}, () -> {
			if (requests.length == 0)
				out.info("no subscription requests");
			for (jid in requests)
				out.print('  $jid');
		});

	function accept(input:String, out:Output) {
		final jid = resolve(input, out);
		if (jid == null || !valid(jid, out))
			return;
		final bare = Jid.parseBare(jid);
		stream.approveSubscription(bare);
		requests.remove(bare);
		// ask back, unless already subscribed to their presence
		final item = find(bare);
		final subscribed = item != null && (item.subscription == to || item.subscription == both || item.ask == "subscribe");
		if (!subscribed)
			stream.subscribePresence(bare);
		out.info('$bare can see your presence' + (subscribed ? '' : ', asked to see theirs'));
	}

	function deny(input:String, out:Output) {
		final jid = resolve(input, out);
		if (jid == null || !valid(jid, out))
			return;
		final bare = Jid.parseBare(jid);
		stream.cancelSubscription(bare);
		requests.remove(bare);
		out.info('$bare can not see your presence');
	}

	/** A roster push: the roster changed (also by another client of the account) **/
	function push(item:RosterItem) {
		final known = find(item.jid) != null;
		final removed = (item.subscription : String) == "remove";
		items = items.filter(i -> i.jid != item.jid);
		if (!removed)
			items.push(item);
		final action = removed ? "removed" : known ? "updated" : "added";
		emit("roster", [item.jid, action], {
			jid_contact: item.jid,
			name: item.name,
			subscription: removed ? "none" : (item.subscription ?? "none" : String),
			groups: item.groups.join(","),
			action: action
		});
	}

	function find(bare:String):Null<RosterItem> {
		for (item in items)
			if (item.jid == bare)
				return item;
		return null;
	}

	/** A contact jid: `user@domain` (a domain alone is most likely a mistyped command) **/
	static function valid(jid:String, out:Output):Bool {
		if (Jid.isValid(jid) && Jid.parseNode(jid) != null)
			return true;
		out.error('invalid jid: $jid (expected user@domain)');
		return false;
	}

	static function parseGroups(groups:Null<String>):Array<String>
		return (groups == null) ? [] : [for (g in groups.split(",")) if (g.trim().length > 0) g.trim()];
}
