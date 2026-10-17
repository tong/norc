package norc.module;

import norc.Commands;
import norc.Forms;
import norc.Module;
import norc.Output;
import norc.Term;
import xmpp.DataForm;
import xmpp.Jid;
import xmpp.PubSub;
import xmpp.ServiceDiscovery;
import xmpp.XML;

using StringTools;

/** A node as listed: its access model (owner only), number of items, what it is for **/
private typedef NodeInfo = {
	final node:String;
	var ?access:String;
	var ?items:Int;
	final ?purpose:String;
}

/**
	Browse and edit publish-subscribe nodes (XEP-0060): your PEP nodes by default (XEP-0163: avatar, tune, bookmarks,
	the keys of encryption, … of all your clients), those of a contact or of a pubsub service.

	The service is the optional last argument (after the node): a jid, a contact name, or a service such as
	`pubsub.example.org`. Nodes other clients depend on (bookmarks, encryption keys, avatar, …) of your own account
	are deleted, purged or changed only with `--force`.
**/
class Nodes extends Module {
	/** Items shown per node (`/pubsub items`) **/
	static inline var MAX_ITEMS = 50;

	/** Characters of an item shown on the terminal (all in the data) **/
	static inline var MAX_SHOWN = 300;

	/** Known nodes (by prefix): what they are for, and whether other clients break without them **/
	static final KNOWN:Array<{prefix:String, purpose:String, needed:Bool}> = [
		{prefix: "urn:xmpp:bookmarks:1", purpose: "bookmarks (rooms)", needed: true},
		{prefix: "storage:bookmarks", purpose: "bookmarks (old format)", needed: true},
		{prefix: "eu.siacs.conversations.axolotl.devicelist", purpose: "OMEMO devices (Conversations)", needed: true},
		{prefix: "eu.siacs.conversations.axolotl.bundles", purpose: "OMEMO keys of a device", needed: true},
		{prefix: "urn:xmpp:omemo:2", purpose: "OMEMO 2 devices and keys", needed: true},
		{prefix: "urn:xmpp:openpgp:0", purpose: "OpenPGP keys", needed: true},
		{prefix: "urn:xmpp:avatar:metadata", purpose: "avatar (its description)", needed: true},
		{prefix: "urn:xmpp:avatar:data", purpose: "avatar (the image)", needed: true},
		{prefix: "urn:xmpp:vcard4", purpose: "profile (vCard4)", needed: true},
		{prefix: "urn:xmpp:mds:displayed:0", purpose: "read up to (displayed sync)", needed: true},
		{prefix: "http://jabber.org/protocol/nick", purpose: "nickname", needed: false},
		{prefix: "http://jabber.org/protocol/tune", purpose: "tune (/tune)", needed: false},
		{prefix: "http://jabber.org/protocol/mood", purpose: "mood (/mood)", needed: false},
		{prefix: "http://jabber.org/protocol/activity", purpose: "activity", needed: false},
		{prefix: "http://jabber.org/protocol/geoloc", purpose: "location", needed: false},
		{prefix: "urn:xmpp:microblog:0", purpose: "microblog", needed: false},
		{prefix: Share.XMLNS, purpose: "shared document (/share)", needed: false}
	];

	final contacts:Contacts;

	/** The fields of the last configuration form, to complete `field=` **/
	var configForm:Null<DataForm>;

	public function new(context:Context, contacts:Contacts) {
		super(context);
		this.contacts = contacts;
	}

	override public function commands():Array<Commands.Command>
		return [
			{
				name: "pubsub",
				description: "publish-subscribe nodes: your PEP nodes (avatar, tune, bookmarks, keys of your clients …), "
				+ "those of a contact or of a pubsub service (the last argument)",
				online: true,
				run: (_, out) -> nodes(null, out),
				subcommands: [
					{
						name: "nodes",
						args: "[service]",
						description: "list the nodes: what they are for, who can read them (your own: the access model), their items",
						online: true,
						run: (args, out) -> nodes(args[0], out)
					},
					{
						name: "items",
						args: "<node> [service]",
						description: 'show the items of a node (at most $MAX_ITEMS, the newest)',
						online: true,
						run: (args, out) -> items(args[0], args[1], out)
					},
					{
						name: "config",
						args: "<node> [settings...]",
						description: "show the configuration of a node (as its owner), or change it: [service] field=value … "
						+ "(short names work, e.g. access_model=presence)",
						online: true,
						run: (args, out) -> config(args[0], args[1], out),
						complete: ["settings" => completeConfig]
					},
					{
						name: "access",
						args: "<node> [args...]",
						description: "who may read or publish: [service] lists the owner, publishers, members (whitelist) "
						+ "and outcasts; <jid> <owner|publisher|publish-only|member|none|outcast> [service] changes one",
						online: true,
						run: (args, out) -> access(args[0], args[1], out)
					},
					{
						name: "subscribers",
						args: "<node> [args...]",
						description: "the subscribers of a node (as its owner): [service] lists them; <jid> none [service] ends a "
						+ "subscription, <jid> subscribed approves a pending one",
						online: true,
						run: (args, out) -> subscribers(args[0], args[1], out)
					},
					{
						name: "publish",
						args: "<node> <xml...>",
						description: "publish an item: [service] <item id=\"…\">payload</item>, or the payload alone (the service "
						+ "gives it an id); with norc ctl -s from stdin",
						online: true,
						run: (args, out) -> publish(args[0], args[1], out)
					},
					{
						name: "retract",
						args: "<node> <id> [service...]",
						description: "delete an item of a node (--force for nodes other clients need)",
						online: true,
						run: (args, out) -> modify("retract", args[0], args[1], args[2], out)
					},
					{
						name: "purge",
						args: "<node> [service...]",
						description: "delete all items of a node, as its owner (--force for nodes other clients need)",
						online: true,
						run: (args, out) -> modify("purge", args[0], null, args[1], out)
					},
					{
						name: "delete",
						args: "<node> [service...]",
						description: "delete a node with its items, as its owner (--force for nodes other clients need)",
						online: true,
						run: (args, out) -> modify("delete", args[0], null, args[1], out)
					}
				]
			}
		];

	/** The service: a jid or contact name, else your own PEP (your bare jid) **/
	function service(input:Null<String>):String
		return (input == null || input.length == 0) ? Jid.parseBare(stream.jid) : Jid.parseBare(contacts.jid(input));

	function own(service:String):Bool
		return service.toLowerCase() == Jid.parseBare(stream.jid).toLowerCase();

	static function known(node:String)
		return Lambda.find(KNOWN, k -> node.startsWith(k.prefix));

	/** Lists the nodes of `input`, each with its access model (owner only) and number of items **/
	function nodes(input:Null<String>, out:Output) {
		final jid = service(input);
		request(out, 'cannot list the nodes of $jid', h -> ServiceDiscovery.discoItems(stream, jid, null, h), payload -> {
			final list:Array<NodeInfo> = [
				for (item in ((payload == null) ? [] : ServiceDiscovery.parseItems(payload)))
					if (item.node != null) {node: item.node, purpose: known(item.node)?.purpose}
			];
			list.sort((a, b) -> Reflect.compare(a.node, b.node));
			// the access model (the configuration, owner only) and the items of each node, all requested at once
			final done = out.wait();
			var pending = list.length * 2;
			function answered() {
				if (--pending > 0)
					return;
				show(jid, list, out);
				done();
			}
			if (list.length == 0) {
				pending = 1;
				answered();
			}
			for (n in list) {
				PubSub.requestNodeConfig(stream, jid, n.node, res -> {
					final form = configOf(res.payload);
					final access = form?.getField("pubsub#access_model");
					if (access?.values != null && access.values.length > 0)
						n.access = access.values[0];
					answered();
				});
				ServiceDiscovery.discoItems(stream, jid, n.node, res -> {
					if (res.payload != null)
						n.items = ServiceDiscovery.parseItems(res.payload).length;
					answered();
				});
			}
		});
	}

	function show(jid:String, list:Array<NodeInfo>, out:Output) {
		out.data({service: jid, nodes: [for (n in list) {node: n.node, access: n.access, items: n.items, purpose: n.purpose}]}, () -> {
			if (list.length == 0) {
				out.info('$jid has no nodes');
				return;
			}
			var width = 0;
			for (n in list)
				width = Std.int(Math.max(width, n.node.length));
			for (n in list) {
				// open: readable by anybody
				final access = n.access ?? "?";
				out.print('  ${n.node.rpad(" ", width)}  '
					+ (access == "open" ? Term.style(access.rpad(" ", 9), 33) : access.rpad(" ", 9))
					+ ' ${n.items != null ? Std.string(n.items).lpad(" ", 3) : "  ?"} ${n.items == 1 ? "item " : "items"}'
					+ (n.purpose != null ? Term.style('  ${n.purpose}', 2) : ''));
			}
			out.info('access: who can read (open: anybody, presence: who sees your presence, roster, whitelist: '
				+ 'the jids allowed, ?: not the owner); /pubsub items <node> shows them');
		});
	}

	/** Shows the items of `node` (newest first), shortened on the terminal **/
	function items(node:String, input:Null<String>, out:Output) {
		final jid = service(input);
		request(out, 'cannot get the items of $node', h -> PubSub.loadItems(stream, jid, node, MAX_ITEMS, h), payload -> {
			final list = PubSub.parseItems(payload);
			out.data({service: jid, node: node, items: [for (i in list) {id: i.get("id"), xml: [for (e in i.elements) e.toString()].join("")}]}, () -> {
				if (list.length == 0)
					out.info('$node has no items');
				for (i in list) {
					final payload = [for (e in i.elements) e.toString()].join("");
					out.print('  ${Term.style(i.get("id") ?? "-", 36)} ' + Recent.truncate(payload.replace("\n", " "), MAX_SHOWN));
				}
			});
		});
	}

	/** The configuration form in the answer to a configuration request, `null` if none **/
	static function configOf(payload:Null<XML>):Null<DataForm> {
		final configure = payload?.elements.first(e -> e.name == "configure");
		final x = configure?.elements.first(e -> e.name == "x" && e.is(DataForm.XMLNS));
		return (x == null) ? null : DataForm.fromXML(x);
	}

	/**
		Shows the configuration of `node`, or changes it: `rest` is `[service] field=value …`. The form is submitted
		with all its current values and the changed ones.
	**/
	function config(node:String, rest:Null<String>, out:Output) {
		final words = (rest ?? "").trim().split(" ").filter(w -> w.length > 0);
		final first = words[0];
		final serviceInput = (first != null && !first.contains("=") && first != "--force") ? words.shift() : null;
		final force = words.remove("--force");
		final values = words.join(" ");
		final jid = service(serviceInput);
		request(out, 'cannot get the configuration of $node', h -> PubSub.requestNodeConfig(stream, jid, node, h), payload -> {
			final form = configOf(payload);
			if (form == null) {
				out.error('$node has no configuration form');
				return;
			}
			configForm = form;
			if (values.length == 0) {
				out.data({service: jid, node: node, form: Forms.data(form)}, () -> {
					Forms.print(form, out);
					out.info('change it: /pubsub config $node ${own(jid) ? "" : '$jid '}field=value … (short names work, e.g. access_model=presence)');
				});
				return;
			}
			if (!allowed("change", node, jid, force, out))
				return;
			final changed = try Forms.parseValues(form, Forms.fullFieldNames(form, values)) catch (e:String) {
				out.error(e);
				return;
			}
			final all = [
				for (f in form.fields)
					if (f.variable != null && f.type != fixed) f.variable => f.values ?? []
			];
			for (k => v in changed)
				all.set(k, v);
			request(out, 'cannot change the configuration of $node', h -> PubSub.configNode(stream, jid, node, form.createSubmit(all), h),
				_ -> out.info('$node: changed ${[for (k in changed.keys()) k].join(", ")}'));
		});
	}

	/** Publishes an item: `input` is `[service] <item …>…</item>`, or a payload (the item gets an id of the service) **/
	function publish(node:String, input:String, out:Output) {
		var text = input.trim();
		var serviceInput:Null<String> = null;
		if (!text.startsWith("<")) {
			final i = text.indexOf(" ");
			serviceInput = (i == -1) ? text : text.substr(0, i);
			text = (i == -1) ? "" : text.substr(i + 1).trim();
		}
		final xml = try XML.fromString(text) catch (e) {
			out.error('invalid XML: $e');
			return;
		}
		final item = (xml.name == "item") ? xml : XML.create("item").append(xml);
		final jid = service(serviceInput);
		request(out, 'cannot publish to $node', h -> PubSub.publish(stream, jid, node, item, h), payload -> {
			// the id given by the service, or the own
			final id = payload?.elements.first(e -> e.name == "publish")?.elements.first(e -> e.name == "item")?.get("id") ?? item.get("id");
			out.data({service: jid, node: node, id: id}, () -> out.info('published to $node' + (id != null ? ' (item $id)' : '')));
		});
	}

	/** Retracts an item (`id`), purges or deletes `node`; `rest` is `[service] [--force]` **/
	function modify(action:String, node:String, id:Null<String>, rest:Null<String>, out:Output) {
		final words = (rest ?? "").trim().split(" ").filter(w -> w.length > 0);
		final force = words.remove("--force");
		final jid = service(words[0]);
		if (!allowed(action, node, jid, force, out))
			return;
		final what = (action == "retract") ? 'item $id of $node' : node;
		request(out, 'cannot $action $what', h -> switch action {
			case "retract": PubSub.retractItem(stream, jid, node, id, h);
			case "purge": PubSub.purgeItems(stream, jid, node, h);
			case _: PubSub.deleteNode(stream, jid, node, h);
		}, _ -> out.info(switch action {
			case "retract": 'retracted item $id of $node';
			case "purge": 'purged $node: its items deleted';
			case _: 'deleted $node';
		}));
	}

	static final AFFILIATIONS = ["owner", "publisher", "publish-only", "member", "none", "outcast"];

	static final SUBSCRIPTIONS = ["none", "subscribed"];

	/**
		The words of `rest`: a change (`jid state`, if the second word is one of `states`) or none, the service, and
		`--force`
	**/
	static function changeArgs(rest:Null<String>, states:Array<String>):{?jid:String, ?state:String, ?service:String, force:Bool} {
		final words = (rest ?? "").trim().split(" ").filter(w -> w.length > 0);
		final force = words.remove("--force");
		// a listing has the service only
		if (words.length >= 2 && !states.contains(words[1]))
			throw 'not one of ${states.join(", ")}: ${words[1]}';
		return (words.length >= 2 && states.contains(words[1])) ? {jid: words[0], state: words[1], service: words[2], force: force} : {service: words[0], force: force};
	}

	/** Lists the affiliations of `node` (owner), or changes the one of a jid **/
	function access(node:String, rest:Null<String>, out:Output) {
		final a = try changeArgs(rest, AFFILIATIONS) catch (e:String) {
			out.error(e);
			return;
		}
		final jid = service(a.service);
		if (a.jid != null) {
			if (!allowed("change", node, jid, a.force, out))
				return;
			final who = Jid.parseBare(contacts.jid(a.jid));
			request(out, 'cannot change the access of $who to $node', h -> PubSub.setAffiliation(stream, jid, node, {jid: who, affiliation: a.state}, h),
				_ -> out.info('$node: $who is ${a.state == "none" ? "no longer affiliated" : a.state}'));
			return;
		}
		request(out, 'cannot get the access to $node', h -> PubSub.getNodeAffiliations(stream, jid, node, h), payload -> {
			final list = PubSub.parseAffiliations(payload).filter(a -> a.jid != null);
			out.data({service: jid, node: node, affiliations: [for (a in list) {jid: a.jid, affiliation: (a.affiliation : String)}]}, () -> {
				if (list.length == 0)
					out.info('$node: no affiliations');
				for (a in list)
					out.print('  ${(a.affiliation : String).rpad(" ", 12)} ${a.jid}');
				out.info('owner, publisher: publish (publish-only: without reading), member: read a whitelist node, outcast: banned; '
					+ 'change: /pubsub access $node <jid> <affiliation>${own(jid) ? "" : ' $jid'}');
			});
		});
	}

	/** Lists the subscribers of `node` (owner), or changes the subscription of a jid **/
	function subscribers(node:String, rest:Null<String>, out:Output) {
		final a = try changeArgs(rest, SUBSCRIPTIONS) catch (e:String) {
			out.error(e);
			return;
		}
		final jid = service(a.service);
		if (a.jid != null) {
			// a full jid subscribes a single client
			final who = contacts.jid(a.jid);
			request(out, 'cannot change the subscription of $who', h -> PubSub.setSubscription(stream, jid, node, who, a.state, h),
				_ -> out.info('$node: ' + (a.state == "none" ? '$who unsubscribed' : '$who subscribed')));
			return;
		}
		request(out, 'cannot get the subscribers of $node', h -> PubSub.getNodeSubscriptions(stream, jid, node, h), payload -> {
			final list = PubSub.parseSubscriptions(payload);
			out.data({
				service: jid,
				node: node,
				subscriptions: [for (s in list) {jid: s.jid, subscription: (s.subscription : String), subid: s.subid}]
			}, () -> {
				if (list.length == 0)
					out.info('$node: no subscribers' + (own(jid) ? " (clients of contacts get PEP nodes without subscribing, through your presence)" : ""));
				for (s in list)
					out.print('  ${(s.subscription : String).rpad(" ", 12)} ${s.jid}' + (s.subid != null ? Term.style(' (${s.subid})', 2) : ''));
			});
		});
	}

	/** Changes of your own nodes other clients need only with `--force`, else an error explaining it **/
	function allowed(action:String, node:String, jid:String, force:Bool, out:Output):Bool {
		final k = known(node);
		if (force || !own(jid) || k == null || !k.needed)
			return true;
		out.error('$node holds the ${k.purpose} of your account: other clients rely on it; to $action anyway add --force');
		return false;
	}

	function completeConfig(arg:String):Commands.Candidates {
		final i = arg.lastIndexOf(" ") + 1;
		return (configForm == null) ? [] : [
			for (f in configForm.fields)
				if (f.variable != null && f.type != fixed && f.type != hidden) arg.substr(0, i) + f.variable + "="
		];
	}
}
