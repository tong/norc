package norc.module;

import norc.Commands;
import norc.Module;
import norc.Output;
import norc.Term;
import xmpp.Jid;
import xmpp.LastActivity;
import xmpp.Response;
import xmpp.ServiceDiscovery;
import xmpp.SoftwareVersion;
import xmpp.client.Stream;

/**
	Information about other entities: service discovery (XEP-0030, `/disco info`, `/disco items`),
	software version (XEP-0092, `/software`) and last activity (XEP-0012, `/lastactivity`).
	Answers software version requests, and last activity requests if enabled (`last_activity`).
**/
class Discovery extends Module {
	final contacts:Contacts;

	/** Seconds since the last input of the user, to answer last activity requests; `null` to not answer them **/
	final idle:Null<() -> Int>;

	public function new(context:Context, contacts:Contacts, ?idle:() -> Int) {
		super(context);
		this.contacts = contacts;
		this.idle = idle;
	}

	override public function commands():Array<Commands.Command>
		return [
			{
				name: "lastactivity",
				args: "[jid]",
				description: "uptime of a server (default: yours), when an account was last online, idle time of a client",
				online: true,
				run: (args, out) -> lastActivity(target(args[0]), out)
			},
			{
				name: "software",
				args: "<jid>",
				description: "software and version of a client or server (of each online client of a contact)",
				online: true,
				run: (args, out) -> software(contacts.jid(args[0]), out)
			},
			{
				name: "disco",
				description: "service discovery",
				subcommands: [
					{
						name: "info",
						args: "[jid] [node]",
						description: "identities and features of an entity (default: the server)",
						online: true,
						run: (args, out) -> info(target(args[0]), args[1], out)
					},
					{
						name: "items",
						args: "[jid] [node]",
						description: "items of an entity, e.g. the services of the server (default: the server)",
						online: true,
						run: (args, out) -> items(target(args[0]), args[1], out)
					}
				]
			}
		];

	override public function attach(stream:Stream) {
		super.attach(stream);
		SoftwareVersion.handleRequests(stream, {name: "norc", version: norc.Version.VERSION, os: Sys.systemName()});
		// reveals when the user was last active: only if enabled (last_activity)
		if (idle != null)
			LastActivity.handleRequests(stream, idle);
	}

	/**
		The first of `jids` supporting `feature` (by service discovery), `null` if none does.
	**/
	public static function findFeature(stream:Stream, jids:Array<String>, feature:String, callback:Null<String>->Void) {
		if (jids.length == 0)
			return callback(null);
		ServiceDiscovery.discoInfo(stream, jids[0], null, res -> switch res {
			case Result(payload) if (payload != null && ServiceDiscovery.parseInfo(payload).features.contains(feature)):
				callback(jids[0]);
			case _:
				findFeature(stream, jids.slice(1), feature, callback);
		});
	}

	/** The jid of a contact given by `input`, the own server if `null` **/
	function target(input:Null<String>):String
		return (input != null) ? contacts.jid(input) : stream.domain;

	function info(jid:String, node:Null<String>, out:Output) {
		final target = describe(jid, node);
		request(out, target, handler -> ServiceDiscovery.discoInfo(stream, jid, node, handler), payload -> {
			if (payload == null) {
				out.data({
					jid: jid,
					node: node,
					identities: [],
					features: [],
					forms: []
				}, () -> out.info('$target: no information'));
				return;
			}
			final info = ServiceDiscovery.parseInfo(payload);
			final features = info.features.copy();
			features.sort(Reflect.compare);
			final data = {
				jid: jid,
				node: node,
				identities: [
					for (i in info.identities) {
						category: i.category,
						type: i.type,
						name: i.name,
						lang: i.lang
					}
				],
				features: features,
				forms: [
					for (form in info.forms)
						{
							type: form.formType,
							fields: [
								for (f in form.fields)
									if (f.variable != null && f.variable != xmpp.DataForm.FORM_TYPE) {name: f.variable, label: f.label, values: f.values ?? []}
							]
						}
				]
			};
			out.data(data, () -> {
				out.print(Term.style(target, 1));
				if (data.identities.length > 0) {
					out.print("  identities:");
					for (i in data.identities)
						out.print('    ${i.category}/${i.type}' + (i.name != null ? '  ${i.name}' : '') + (i.lang != null ? Term.style(' [${i.lang}]',
							2) : ''));
				}
				if (features.length > 0) {
					out.print("  features:");
					for (f in features)
						out.print('    $f');
				}
				for (form in data.forms) {
					out.print('  ${form.type ?? "form"}:');
					for (field in form.fields)
						out.print('    ${field.label ?? field.name}: ${field.values.join(", ")}');
				}
			});
		});
	}

	function items(jid:String, node:Null<String>, out:Output) {
		final target = describe(jid, node);
		request(out, target, handler -> ServiceDiscovery.discoItems(stream, jid, node, handler), payload -> {
			final items = (payload == null) ? [] : [
				for (item in ServiceDiscovery.parseItems(payload)) {jid: item.jid, node: item.node, name: item.name}
			];
			out.data({jid: jid, node: node, items: items}, () -> {
				if (items.length == 0)
					out.info('$target: no items');
				else
					out.print(Term.style(target, 1));
				for (item in items)
					out.print('  ${item.jid}' + (item.node != null ? Term.style(' node=${item.node}', 2) : '') + (item.name != null ? '  ${item.name}' : ''));
			});
		});
	}

	/**
		`/software`: the software (name, version, operating system) of an entity.
		For a contact without resource, of each of its available clients.
	**/
	function software(jid:String, out:Output)
		for (target in contacts.clients(jid))
			request(out, target, handler -> SoftwareVersion.getSoftwareVersion(stream, target, handler), payload -> {
				final info = SoftwareVersion.parse(payload);
				out.data({
					jid: target,
					name: info.name,
					version: info.version,
					os: info.os
				}, () -> {
					if (info.name == null && info.version == null && info.os == null)
						out.info('$target: no software information');
					else
						out.print('$target: '
							+ [info.name, info.version].filter(v -> v != null).join(" ") + (info.os != null ? Term.style(' (${info.os})', 2) : ''));
				});
			});

	/**
		`/lastactivity`: depending on the entity, the uptime of a server, the time since an account was online,
		or the idle time of a client.
	**/
	function lastActivity(jid:String, out:Output)
		request(out, jid, handler -> LastActivity.getLastActivity(stream, jid, handler), payload -> {
			final last = (payload == null) ? null : LastActivity.parse(payload);
			if (last == null) {
				out.info('$jid: no last activity');
				return;
			}
			// what the seconds mean depends on the entity
			final kind = if (Jid.parseNode(jid) == null) "uptime" else if (Jid.parseResource(jid) == null) "offline" else "idle";
			out.data({
				jid: jid,
				kind: kind,
				seconds: last.seconds,
				status: last.status
			}, () -> {
				final time = formatDuration(last.seconds);
				final text = switch kind {
					case "uptime": 'up for $time';
					case "offline": (last.seconds == 0) ? 'online' : 'last seen $time ago';
					case _: 'idle for $time';
				}
				out.print('$jid: $text' + (last.status != null ? ' (${last.status})' : ''));
			});
		});

	/** e.g. `2d 3h`, `5h 12m`, `3m 20s`, `45s` **/
	static function formatDuration(seconds:Int):String {
		final d = Std.int(seconds / 86400);
		final h = Std.int(seconds % 86400 / 3600);
		final m = Std.int(seconds % 3600 / 60);
		final s = seconds % 60;
		return if (d > 0) '${d}d ${h}h' else if (h > 0) '${h}h ${m}m' else if (m > 0) '${m}m ${s}s' else '${s}s';
	}

	static function describe(jid:String, node:Null<String>):String
		return jid + (node != null ? ' (node $node)' : '');
}
