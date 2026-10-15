package norc.module;

import norc.Commands;
import norc.Module;
import norc.Output;
import norc.Term;
import xmpp.Jid;
import xmpp.Presence;
import xmpp.Response;
import xmpp.client.Roster;
import xmpp.client.Stream;

using StringTools;
using xmpp.client.Roster;

/** The presence of an available client **/
typedef PresenceState = {
	/** `available`, `chat`, `away`, `xa` or `dnd` **/
	var state:String;

	var status:Null<String>;
}

/**
	The roster (contact list), presence subscriptions (`/contacts` and its subcommands) and the presences of
	the contacts (the `presence` event).
**/
class Contacts extends Module {
	/** The roster, as last received from the server (kept while disconnected) **/
	public var items(default, null) = new Array<RosterItem>();

	/** Nicknames published by contacts (bare jid), their names if the roster has none **/
	public final nicknames = new Map<String, String>();

	/** Contacts asking to see the own presence **/
	final requests = new Array<String>();

	/** The presence of each available full jid (kept while a resumable session is disconnected) **/
	final presences = new Map<String, PresenceState>();

	/** Time of the login, presences shortly after are the initial ones of the contacts **/
	var onlineSince = 0.0;

	public function new(context:Context)
		super(context);

	override public function commands():Array<Commands.Command>
		return [
			{
				name: "contacts",
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

	override public function attach(stream:Stream) {
		super.attach(stream);
		stream.onPresence = receive;
		Roster.handleRequests(stream, (item, ver) -> push(item));
	}

	override public function online() {
		onlineSince = Sys.time();
		// the server sends the presences of the available contacts again
		presences.clear();
		stream.loadRoster(res -> switch res {
			case Result(payload): items = Roster.parseRoster(payload).items;
			case Error(e): Term.error('cannot load the roster: ${Term.errorText(e)}');
		});
	}

	override public function detach() {
		super.detach();
		requests.resize(0);
	}

	/** The name of a contact: the name in the roster, else its nickname, else the jid **/
	public function name(bare:String):String {
		final item = find(bare);
		return (item != null && item.name != null && item.name.length > 0) ? item.name : nicknames.get(bare) ?? bare;
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

	/** Like `resolve`, but `input` itself if it matches no contact (e.g. a server), without error **/
	public function jid(input:String):String {
		final matches = lookup(input);
		return (matches.length == 1) ? matches[0] : input;
	}

	/** The bare jid is in the roster **/
	public function contains(bare:String):Bool
		return find(bare) != null;

	/** The contact (bare jid) may see the own presence (subscription `from` or `both`) **/
	public function seesPresence(bare:String):Bool {
		final item = find(bare);
		return item != null && (item.subscription == from || item.subscription == both);
	}

	/** The available full jids of a contact (bare jid) **/
	public function resources(bare:String):Array<String>
		return [for (jid in presences.keys()) if (Jid.parseBare(jid) == bare) jid];

	/** The available clients (full jids) of a contact given by its bare jid, else `jid` itself (e.g. a server) **/
	public function clients(jid:String):Array<String> {
		final online = (Jid.parseResource(jid) == null) ? resources(jid) : [];
		return (online.length > 0) ? online : [jid];
	}

	/** Jids and names (without spaces) of the contacts and of pending subscription requests, to complete input **/
	public function completions():Array<String> {
		final list = requests.copy();
		for (item in items) {
			list.push(item.jid);
			if (item.name != null && item.name.length > 0 && !item.name.contains(" "))
				list.push(item.name);
		}
		return list;
	}

	/** e.g. `away (back soon)` **/
	public static function describe(p:PresenceState):String
		return p.state + (p.status != null ? ' (${p.status})' : '');

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
			matches = [
				for (c in candidates) if ((Jid.parseNode(c.jid) ?? "").toLowerCase() == name) c.jid
			];
		final unique = new Array<String>();
		for (m in matches)
			if (!unique.contains(m))
				unique.push(m);
		return [for (m in unique) m + resource];
	}

	/** Presences of contacts and subscription changes: shown (changes only) and their events **/
	function receive(p:Presence) {
		if (p.from == null)
			return;
		final bare = Jid.parseBare(p.from);
		final who = name(bare);
		final res = Jid.parseResource(p.from);
		final full = (res != null) ? '$who/$res' : who;
		final previous = presences.get(p.from);
		switch p.type {
			case null:
				final presence:PresenceState = {state: (p.show : Null<String>) ?? "available", status: p.status};
				if (p.from == stream.jid || (previous != null && describe(previous) == describe(presence)))
					return;
				presences.set(p.from, presence);
				presenceEvent(p.from, presence, previous);
				Term.notice('$full is ${describe(presence)}');
			case unavailable:
				// not seen online (servers send these on login)
				if (previous == null)
					return;
				final presence:PresenceState = {state: "offline", status: p.status};
				presences.remove(p.from);
				presenceEvent(p.from, presence, previous);
				Term.notice('$full is ${describe(presence)}');
			case subscribe:
				if (!requests.contains(bare))
					requests.push(bare);
				emit("subscribe", [bare], {from: p.from, name: who});
				Term.notice('$who wants to see your presence: /contacts accept $bare or /contacts deny $bare');
			case subscribed:
				subscription(p.from, "subscribed", '$who allowed you to see their presence');
			case unsubscribed:
				subscription(p.from, "unsubscribed", '$who removed your presence subscription');
			case unsubscribe:
				subscription(p.from, "unsubscribe", '$who unsubscribed from your presence');
			case error:
				Term.error('presence error from $full: ${Term.errorText(p.error)}');
			case _:
		}
	}

	function presenceEvent(from:String, presence:PresenceState, previous:Null<PresenceState>) {
		final bare = Jid.parseBare(from);
		emit("presence", [bare, presence.state, presence.status ?? ""], {
			from: from,
			name: name(bare),
			state: presence.state,
			status: presence.status,
			previous: previous?.state ?? "offline",
			// available clients of the contact after this change
			resources: resources(bare).length,
			// the server sends the presences of all available contacts after the login
			initial: Sys.time() - onlineSince < 5
		});
	}

	function subscription(from:String, type:String, text:String) {
		emit("subscription", [Jid.parseBare(from), type], {from: from, name: name(Jid.parseBare(from)), type: type});
		Term.notice(text);
	}

	function list(out:Output) {
		final sorted = items.copy();
		sorted.sort((a, b) -> Reflect.compare(name(a.jid).toLowerCase(), name(b.jid).toLowerCase()));
		final contacts = [
			for (item in sorted) {
				final available = resources(item.jid);
				{
					jid: item.jid,
					name: (item.name != null && item.name.length > 0) ? item.name : null,
					subscription: (item.subscription ?? none:String),
					asked: item.ask == "subscribe",
					groups: item.groups,
					// of the first available client
					presence: (stream != null && available.length > 0) ? describe(presences.get(available[0])) : null
				}
			}
		];
		out.data({contacts: contacts}, () -> {
			if (contacts.length == 0)
				out.info("no contacts");
			for (c in contacts) {
				final details = [c.subscription];
				if (c.asked)
					details.push("asked");
				if (c.groups.length > 0)
					details.push(c.groups.join(", "));
				out.print('  '
					+ (c.name != null ? '${c.name} <${c.jid}>' : c.jid)
					+ (c.presence != null ? Term.style(' ${c.presence}', 32) : '')
					+ Term.style(' [${details.join("; ")}]', 2));
			}
		});
	}

	function add(jid:String, ?name:String, out:Output) {
		if (!valid(jid, out))
			return;
		final bare = Jid.parseBare(jid);
		request(out, 'cannot add $bare', handler -> stream.addRosterItem(bare, name, find(bare)?.groups ?? [], handler), _ -> {
			stream.subscribePresence(bare);
			out.info('added $bare, asked to see their presence');
		});
	}

	function remove(input:String, out:Output) {
		final bare = findItem(input, out)?.jid;
		if (bare != null)
			request(out, 'cannot remove $bare', handler -> stream.removeRosterItem(bare, handler), _ -> out.info('removed $bare'));
	}

	/** Changes a contact (name or groups) **/
	function update(input:String, change:RosterItem->Void, out:Output) {
		final current = findItem(input, out);
		if (current == null)
			return;
		final item:RosterItem = {jid: current.jid, name: current.name, groups: current.groups.copy()};
		change(item);
		request(out, 'cannot update ${item.jid}', handler -> stream.addRosterItem(item.jid, item.name, item.groups, handler),
			_ -> out.info('updated ${item.jid}'));
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
			subscription: removed ? "none" : (item.subscription ?? "none":String),
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

	/** The roster item of the contact given by `input` (see `resolve`), `null` with an error if there is none **/
	function findItem(input:String, out:Output):Null<RosterItem> {
		final jid = resolve(input, out);
		if (jid == null)
			return null;
		final item = find(Jid.parseBare(jid));
		if (item == null)
			out.error('${Jid.parseBare(jid)} is not in the roster');
		return item;
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
