package norc.module;

import haxe.crypto.Base64;
import haxe.io.Bytes;
import norc.Commands;
import norc.Module;
import norc.Output;
import norc.Term;
import norc.module.Messages;
import xmpp.Jid;
import xmpp.Message;
import xmpp.PubSub;
import xmpp.Response;
import xmpp.ServiceDiscovery;
import xmpp.XML;

using StringTools;

/** A node opened with `/share open` **/
private typedef Shared = {
	final service:String;
	final node:String;

	/** Subscribed, items being requested: notifications meanwhile are kept, in order **/
	var opening:Bool;

	final buffered:Array<XML>;
}

/**
	Shared documents (e.g. shared editing in norc.nvim): a PubSub node per document, its items in one order for all
	subscribers. norc is the transport only: the payloads are opaque text (JSON of the editor) in
	`<data xmlns="urn:xmpp:norc:share:0">`.

	`/share open` subscribes with the full jid (notifications reach this client only), then requests the items: the
	reply has them in the order of the node, and the `share` events continue after them without gap or duplicate.
	A node is created with `/share create` (whitelist: the owner and the publishers added), participants are added
	and removed with `/share add` and `/share remove` (which also ends their subscriptions).

	The PubSub service is `share_service`, or the one of the server (service discovery).
**/
class Share extends Module {
	public static inline var XMLNS = "urn:xmpp:norc:share:0";

	/** Payloads up to this size (bytes): servers close the connection on large stanzas (prosody: 256 KiB) **/
	public static inline var MAX_PAYLOAD = 200 * 1024;

	static final CONFIG = [
		"pubsub#access_model" => "whitelist",
		"pubsub#publish_model" => "publishers",
		"pubsub#persist_items" => "true",
		"pubsub#max_items" => "1000",
		"pubsub#itemreply" => "publisher",
		"pubsub#deliver_payloads" => "true",
		"pubsub#notify_retract" => "false",
		"pubsub#notify_config" => "false",
		"pubsub#send_last_published_item" => "never",
		"pubsub#notification_type" => "headline"
	];

	final contacts:Contacts;
	final configured:Null<String>;

	/** The discovered service (null: not yet) **/
	var discovered:Null<String>;

	/** Open nodes, by `service node` **/
	final open = new Map<String, Shared>();

	public function new(context:Context, messages:Messages, contacts:Contacts, service:Null<String>) {
		super(context);
		this.contacts = contacts;
		this.configured = service;
		messages.incoming.push(receive);
	}

	override public function commands():Array<Commands.Command>
		return [
			{
				name: "share",
				description: "shared documents (pubsub nodes, e.g. for shared editing in norc.nvim): the open nodes",
				online: true,
				run: (_, out) -> list(out),
				subcommands: [
					{
						name: "create",
						args: "<node> [jids...]",
						description: "create a node, the jids (and you) may read and publish",
						online: true,
						run: (args, out) -> create(args[0], words(args[1]), out)
					},
					{
						name: "open",
						args: "<node> [service]",
						description: "subscribe to a node: replies its items, then share events for new ones",
						online: true,
						run: (args, out) -> openNode(args[0], args[1], out)
					},
					{
						name: "close",
						args: "<node>",
						description: "unsubscribe from a node",
						online: true,
						run: (args, out) -> close(args[0], out)
					},
					{
						name: "publish",
						args: "<node> <payload...>",
						description: "publish an item (a new id) to an open node",
						online: true,
						run: (args, out) -> publish(args[0], null, args[1], out)
					},
					{
						name: "put",
						args: "<node> <id> <payload...>",
						description: "publish an item with an id (replacing the item with this id)",
						online: true,
						run: (args, out) -> publish(args[0], args[1], args[2], out)
					},
					{
						name: "delete",
						args: "<node>",
						description: "delete a node (owner): ends it for all",
						online: true,
						run: (args, out) -> delete(args[0], out)
					},
					{
						name: "members",
						args: "<node>",
						description: "the affiliations and subscriptions of a node (owner)",
						online: true,
						run: (args, out) -> members(args[0], out)
					},
					{
						name: "add",
						args: "<node> <jid>",
						description: "let a jid read and publish (owner)",
						online: true,
						run: (args, out) -> affiliate(args[0], args[1], publisher, out)
					},
					{
						name: "remove",
						args: "<node> <jid>",
						description: "remove a jid from a node, ending its subscriptions (owner)",
						online: true,
						run: (args, out) -> affiliate(args[0], args[1], none, out)
					},
					{
						name: "invite",
						args: "<jid> <node> [name...]",
						description: "invite a contact to a node (a message, shown by other clients too), name: e.g. the file",
						online: true,
						run: (args, out) -> invite(args[0], args[1], args[2], out)
					}
				]
			}
		];

	override public function features():Array<String>
		return [XMLNS];

	/** A new session: notifications may have been missed, the editors open the nodes again **/
	override public function online() {
		final nodes = [for (s in open) s];
		open.clear();
		for (s in nodes)
			emit("share-resync", [s.node], {service: s.service, node: s.node});
	}

	override public function detach() {
		super.detach();
		discovered = null;
	}

	static function words(input:Null<String>):Array<String>
		return (input == null) ? [] : [for (w in ~/\s+/g.split(input.trim())) if (w.length > 0) w];

	static function key(service:String, node:String):String
		return '$service $node';

	/** The PubSub service: `share_service`, or discovered (a `pubsub/service` item of the server) **/
	function service(out:Output, callback:String->Void) {
		final known = configured ?? discovered;
		if (known != null)
			return callback(known);
		final done = out.wait();
		ServiceDiscovery.discoItems(stream, stream.domain, null, res -> {
			final items = (res.payload != null) ? ServiceDiscovery.parseItems(res.payload) : [];
			function next(i:Int) {
				if (i >= items.length) {
					out.error("no pubsub service found (set share_service)");
					return done();
				}
				ServiceDiscovery.discoInfo(stream, items[i].jid, null, res -> {
					final info = (res.payload != null) ? ServiceDiscovery.parseInfo(res.payload) : null;
					if (info != null && Lambda.exists(info.identities, id -> id.category == "pubsub" && id.type == "service")) {
						discovered = items[i].jid;
						// the command waits for what the callback starts
						callback(items[i].jid);
						done();
					} else
						next(i + 1);
				});
			}
			next(0);
		});
	}

	/** The open node `node` (of any service), or an error **/
	function find(node:String, out:Output):Null<Shared> {
		for (s in open)
			if (s.node == node)
				return s;
		out.error('$node is not open (/share open)');
		return null;
	}

	function list(out:Output) {
		final nodes = [for (s in open) {service: s.service, node: s.node}];
		out.data({nodes: nodes}, () -> {
			if (nodes.length == 0)
				out.info("no open nodes (/share open)");
			for (n in nodes)
				out.print('${n.node} (${n.service})');
		});
	}

	function create(node:String, jids:Array<String>, out:Output) {
		final resolved = [];
		for (input in jids) {
			final jid = contacts.resolve(input, out);
			if (jid == null)
				return;
			resolved.push(Jid.parseBare(jid));
		}
		service(out, service -> {
			request(out, 'cannot create $node', h -> PubSub.createConfiguredNode(stream, service, node, CONFIG, h), _ -> {
				final done = out.wait();
				function next(i:Int) {
					if (i >= resolved.length) {
						out.data({service: service, node: node, members: resolved}, () -> out.info('created $node at $service'));
						return done();
					}
					PubSub.setAffiliation(stream, service, node, {jid: resolved[i], affiliation: publisher}, res -> {
						if (res.error != null)
							out.error('cannot add ${resolved[i]}: ${Term.errorText(res.error)}');
						next(i + 1);
					});
				}
				next(0);
			});
		});
	}

	function openNode(node:String, at:Null<String>, out:Output) {
		function withService(service:String) {
			final k = key(service, node);
			if (open.exists(k)) {
				out.error('$node is already open');
				return;
			}
			final shared:Shared = {
				service: service,
				node: node,
				opening: true,
				buffered: []
			};
			open.set(k, shared);
			final done = out.wait();
			function failed(text:String) {
				open.remove(k);
				out.error(text);
				done();
			}
			PubSub.subscribe(stream, service, node, stream.jid, res -> {
				if (res.error != null)
					return failed('cannot subscribe to $node: ${Term.errorText(res.error)}');
				PubSub.loadItems(stream, service, node, res -> {
					if (res.error != null) {
						PubSub.unsubscribe(stream, service, node, stream.jid, _ -> {});
						return failed('cannot load the items of $node: ${Term.errorText(res.error)}');
					}
					final items = PubSub.parseItems(res.payload);
					final ids = [for (i in items) i.get("id") => true];
					out.data({service: service, node: node, items: [for (i in items) item(i)]},
						() -> out.info('opened $node (${items.length} items)'));
					done();
					// notifications meanwhile, after the loaded items
					shared.opening = false;
					for (i in shared.buffered)
						if (!ids.exists(i.get("id")))
							emitItem(shared, i);
					shared.buffered.resize(0);
				});
			});
		}
		if (at != null)
			withService(at);
		else
			service(out, withService);
	}

	function close(node:String, out:Output) {
		final s = find(node, out);
		if (s == null)
			return;
		open.remove(key(s.service, s.node));
		request(out, 'cannot unsubscribe from $node', h -> PubSub.unsubscribe(stream, s.service, node, stream.jid, h),
			_ -> out.info('closed $node'));
	}

	function publish(node:String, id:Null<String>, payload:String, out:Output) {
		final s = find(node, out);
		if (s == null)
			return;
		final size = Bytes.ofString(payload).length;
		if (size > MAX_PAYLOAD) {
			out.error('payload too large: $size bytes (at most $MAX_PAYLOAD)');
			return;
		}
		final itemId = id ?? newId();
		final data = XML.create("data").set("xmlns", XMLNS);
		data.text = payload;
		final item = XML.create("item").set("id", itemId).append(data);
		request(out, 'cannot publish to $node', h -> PubSub.publish(stream, s.service, node, item, h), _ -> out.data({id: itemId}, () -> {}));
	}

	function delete(node:String, out:Output) {
		final s = find(node, out);
		final svc = s?.service ?? configured ?? discovered;
		if (svc == null)
			return;
		request(out, 'cannot delete $node', h -> PubSub.deleteNode(stream, svc, node, h), _ -> {
			open.remove(key(svc, node));
			out.info('deleted $node');
		});
	}

	function members(node:String, out:Output) {
		service(out, service -> {
			request(out, 'cannot get the affiliations of $node', h -> PubSub.getNodeAffiliations(stream, service, node, h), affs -> {
				request(out, 'cannot get the subscriptions of $node', h -> PubSub.getNodeSubscriptions(stream, service, node, h), subs -> {
					final affiliations = PubSub.parseAffiliations(affs);
					final subscriptions = PubSub.parseSubscriptions(subs);
					out.data({
						affiliations: [for (a in affiliations) {jid: a.jid, affiliation: a.affiliation}],
						subscriptions: [for (s in subscriptions) {jid: s.jid, subscription: s.subscription}]
					}, () -> {
						for (a in affiliations) {
							final resources = [for (s in subscriptions) if (Jid.parseBare(s.jid) == a.jid) (s.jid:Jid).resource ?? ""];
							out.print('${a.jid} ${a.affiliation}' + (resources.length > 0 ? ' (subscribed: ${resources.join(", ")})' : ''));
						}
					});
				});
			});
		});
	}

	/** Sets the affiliation of a jid; `none` also ends its subscriptions (an affiliation alone doesn't) **/
	function affiliate(node:String, input:String, affiliation:xmpp.PubSub.AffiliationState, out:Output) {
		final jid = contacts.resolve(input, out);
		if (jid == null)
			return;
		final bare = Jid.parseBare(jid);
		if (isOwn(bare)) {
			out.error("cannot change your own affiliation");
			return;
		}
		service(out, service -> {
			request(out, 'cannot change the affiliation of $bare', h -> PubSub.setAffiliation(stream, service, node, {jid: bare, affiliation: affiliation}, h), _ -> {
				if (affiliation != none) {
					out.info('$bare may read and publish $node');
					return;
				}
				request(out, 'cannot get the subscriptions of $node', h -> PubSub.getNodeSubscriptions(stream, service, node, h), subs -> {
					final ended = [for (s in PubSub.parseSubscriptions(subs)) if (Jid.parseBare(s.jid) == bare) s.jid];
					final done = out.wait();
					function next(i:Int) {
						if (i >= ended.length) {
							out.info('removed $bare from $node' + (ended.length > 0 ? ' (ended ${ended.length} subscriptions)' : ''));
							return done();
						}
						PubSub.setSubscription(stream, service, node, ended[i], none, res -> {
							if (res.error != null)
								out.error('cannot end the subscription of ${ended[i]}: ${Term.errorText(res.error)}');
							next(i + 1);
						});
					}
					next(0);
				});
			});
		});
	}

	function invite(input:String, node:String, name:Null<String>, out:Output) {
		final to = contacts.resolve(input, out);
		if (to == null)
			return;
		final s = Lambda.find(open, s -> s.node == node);
		final svc = s?.service ?? configured ?? discovered;
		if (svc == null) {
			out.error('$node is not open (/share open)');
			return;
		}
		final m = new Message(to, 'invites you to edit ${name ?? node} together (norc: /share open $node $svc)');
		m.properties.push(XML.create("invite").set("xmlns", XMLNS).set("service", svc).set("node", node).set("name", name));
		stream.send(m);
		out.info('invited ${contacts.name(Jid.parseBare(to))} to $node');
	}

	/** A random item id **/
	static function newId():String {
		final b = Bytes.alloc(12);
		for (i in 0...b.length)
			b.set(i, Std.random(256));
		return Base64.urlEncode(b);
	}

	/** An item for the API: id, publisher (bare jid, stamped by the service), payload **/
	static function item(i:XML):{id:String, publisher:Null<String>, payload:Null<String>} {
		final data = i.elements.named("data").filter(e -> e.is(XMLNS))[0];
		return {id: i.get("id"), publisher: i.get("publisher"), payload: data?.text};
	}

	function emitItem(s:Shared, i:XML) {
		final it = item(i);
		emit("share", [s.node, it.id], {
			service: s.service,
			node: s.node,
			id: it.id,
			publisher: it.publisher,
			payload: it.payload
		});
	}

	/** Notifications of open nodes and invites; handled messages aren't shown **/
	function receive(i:Incoming):Bool {
		final m = i.message;
		if (i.carbon != null || m.from == null)
			return false;
		final event = PubSub.getEvent(m);
		if (event != null) {
			final from = m.from;
			switch event {
				case Items(node, items, _):
					final s = open.get(key(from, node));
					if (s == null)
						return isShare(items);
					for (it in items)
						if (s.opening)
							s.buffered.push(it);
						else
							emitItem(s, it);
					return true;
				case Delete(node, _):
					final s = open.get(key(from, node));
					if (s == null)
						return false;
					open.remove(key(from, node));
					Term.notice('$node was deleted');
					emit("share-deleted", [node], {service: from, node: node});
					return true;
				case _:
					return false;
			}
		}
		final inv = m.properties.filter(e -> e.name == "invite" && e.is(XMLNS))[0];
		if (inv == null)
			return false;
		final from = Jid.parseBare(m.from);
		if (!contacts.contains(from))
			return true;
		final node = inv.get("node"), service = inv.get("service"), name = inv.get("name");
		Term.notice('${contacts.name(from)} invites you to edit ${name ?? node} together: /share open $node $service');
		emit("share-invite", [from, node], {
			from: m.from,
			name: contacts.name(from),
			service: service,
			node: node,
			file: name
		});
		return true;
	}

	/** Items of nodes of norc (not open, e.g. after closing): not shown **/
	static function isShare(items:Array<XML>):Bool
		return Lambda.exists(items, i -> i.elements.named("data").filter(e -> e.is(XMLNS)).length > 0);
}
