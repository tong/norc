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
import xmpp.XML;
import xmpp.client.Stream;

/**
	Information about other entities: service discovery (XEP-0030, `/disco info`, `/disco items`),
	software version (XEP-0092, `/software`) and last activity (XEP-0012, `/lastactivity`).
	Answers software version requests, and last activity requests if enabled (`last_activity`).
**/
class Discovery implements Module {
	var stream:Null<Stream>;

	/** A contact name to its jid, other input unchanged **/
	final resolve:String->String;

	/** The available full jids of a bare jid **/
	final resources:String->Array<String>;

	/** Seconds since the last input of the user, to answer last activity requests; `null` to not answer them **/
	final idle:Null<() -> Int>;

	public function new(resolve:String->String, resources:String->Array<String>, ?idle:() -> Int) {
		this.resolve = resolve;
		this.resources = resources;
		this.idle = idle;
	}

	public function commands():Array<Commands.Command>
		return [
			{
				name: "lastactivity",
				args: "[jid]",
				description: "uptime of a server (default: yours), when an account was last online, idle time of a client",
				online: true,
				run: (args, out) -> lastActivity(args[0] != null ? resolve(args[0]) : null, out)
			},
			{
				name: "software",
				args: "<jid>",
				description: "software and version of a client or server (of each online client of a contact)",
				online: true,
				run: (args, out) -> software(args[0], out)
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
						run: (args, out) -> info(args[0] != null ? resolve(args[0]) : null, args[1], out)
					},
					{
						name: "items",
						args: "[jid] [node]",
						description: "items of an entity, e.g. the services of the server (default: the server)",
						online: true,
						run: (args, out) -> items(args[0] != null ? resolve(args[0]) : null, args[1], out)
					}
				]
			}
		];

	public function features():Array<String>
		return [];

	public function attach(stream:Stream) {
		this.stream = stream;
		// answer software version requests
		SoftwareVersion.handleRequests(stream, {name: "norc", version: norc.Version.VERSION, os: Sys.systemName()});
		// reveals when the user was last active: only if enabled (last_activity)
		if (idle != null)
			LastActivity.handleRequests(stream, idle);
	}

	public function online() {}

	public function detach()
		stream = null;

	function info(?jid:String, ?node:String, out:Output) {
		final target = describe(jid, node);
		final done = out.wait();
		ServiceDiscovery.discoInfo(stream, jid, node, res -> {
			switch res {
				case Result(payload):
					final info = (payload == null) ? null : ServiceDiscovery.parseInfo(payload);
					final features = (info == null) ? [] : info.features.copy();
					features.sort(Reflect.compare);
					final data = {
						jid: jid ?? stream.domain,
						node: node,
						identities: (info == null) ? [] : [
							for (i in info.identities)
								{category: i.category, type: i.type, name: i.name, lang: i.lang}
						],
						features: features,
						forms: (info == null) ? [] : [
							for (form in info.forms)
								{
									type: form.formType,
									fields: [
										for (f in form.fields)
											if (f.variable != null && f.variable != xmpp.DataForm.FORM_TYPE)
												{name: f.variable, label: f.label, values: f.values ?? []}
									]
								}
						]
					};
					out.data(data, () -> {
						if (info == null) {
							out.info('$target: no information');
							return;
						}
						out.print(Term.style(target, 1));
						if (data.identities.length > 0) {
							out.print("  identities:");
							for (i in data.identities)
								out.print('    ${i.category}/${i.type}' + (i.name != null ? '  ${i.name}' : '')
									+ (i.lang != null ? Term.style(' [${i.lang}]', 2) : ''));
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
				case Error(e):
					out.error('$target: ${errorText(e)}');
			}
			done();
		});
	}

	function items(?jid:String, ?node:String, out:Output) {
		final target = describe(jid, node);
		final done = out.wait();
		ServiceDiscovery.discoItems(stream, jid, node, res -> {
			switch res {
				case Result(payload):
					final items = (payload == null) ? [] : [
						for (item in ServiceDiscovery.parseItems(payload))
							{jid: item.jid, node: item.node, name: item.name}
					];
					out.data({jid: jid ?? stream.domain, node: node, items: items}, () -> {
						if (items.length == 0) {
							out.info('$target: no items');
							return;
						}
						out.print(Term.style(target, 1));
						for (item in items)
							out.print('  ${item.jid}' + (item.node != null ? Term.style(' node=${item.node}', 2) : '')
								+ (item.name != null ? '  ${item.name}' : ''));
					});
				case Error(e):
					out.error('$target: ${errorText(e)}');
			}
			done();
		});
	}

	/**
		`/software`: the software (name, version, operating system) of an entity.
		For a contact without resource, of each of its available clients.
	**/
	function software(input:String, out:Output) {
		final jid = resolve(input);
		final online = (Jid.parseResource(jid) == null) ? resources(jid) : [];
		final targets = (online.length > 0) ? online : [jid];
		for (target in targets) {
			final done = out.wait();
			SoftwareVersion.getSoftwareVersion(stream, target, res -> {
				switch res {
					case Result(payload):
						final info = SoftwareVersion.parse(payload);
						out.data({jid: target, name: info.name, version: info.version, os: info.os}, () -> {
							if (info.name == null && info.version == null && info.os == null)
								out.info('$target: no software information');
							else
								out.print('$target: ' + [info.name, info.version].filter(v -> v != null).join(" ")
									+ (info.os != null ? Term.style(' (${info.os})', 2) : ''));
						});
					case Error(e):
						out.error('$target: ${errorText(e)}');
				}
				done();
			});
		}
	}

	/**
		`/lastactivity`: depending on the entity, the uptime of a server, the time since an account was online,
		or the idle time of a client.
	**/
	function lastActivity(jid:Null<String>, out:Output) {
		final target = jid ?? stream.domain;
		final done = out.wait();
		LastActivity.getLastActivity(stream, target, res -> {
			switch res {
				case Result(payload):
					final last = (payload == null) ? null : LastActivity.parse(payload);
					if (last == null) {
						out.info('$target: no last activity');
					} else {
						// what the seconds mean depends on the entity
						final kind = if (Jid.parseNode(target) == null) "uptime" else if (Jid.parseResource(target) == null) "offline" else "idle";
						out.data({jid: target, kind: kind, seconds: last.seconds, status: last.status}, () -> {
							final time = formatDuration(last.seconds);
							final text = switch kind {
								case "uptime": 'up for $time';
								case "offline": last.seconds == 0 ? 'online' : 'last seen $time ago';
								case _: 'idle for $time';
							}
							out.print('$target: $text' + (last.status != null ? ' (${last.status})' : ''));
						});
					}
				case Error(e):
					out.error('$target: ${errorText(e)}');
			}
			done();
		});
	}

	/** e.g. `2d 3h`, `5h 12m`, `3m 20s`, `45s` **/
	static function formatDuration(seconds:Int):String {
		final d = Std.int(seconds / 86400);
		final h = Std.int(seconds % 86400 / 3600);
		final m = Std.int(seconds % 3600 / 60);
		final s = seconds % 60;
		return if (d > 0) '${d}d ${h}h' else if (h > 0) '${h}h ${m}m' else if (m > 0) '${m}m ${s}s' else '${s}s';
	}

	function describe(?jid:String, ?node:String):String
		return (jid ?? stream.domain) + (node != null ? ' (node $node)' : '');

	static function errorText(e:xmpp.Stanza.Error):String
		return e.condition + (e.text != null ? ': ${e.text}' : '');
}
