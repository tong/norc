package norc.module;

import norc.Commands;
import norc.Module;
import norc.Output;
import norc.Term;
import xmpp.Jid;
import xmpp.Response;
import xmpp.ServiceDiscovery;
import xmpp.SoftwareVersion;
import xmpp.XML;
import xmpp.client.Stream;

/**
	Service discovery (XEP-0030): `/disco info` and `/disco items`.
**/
class Discovery implements Module {
	var stream:Null<Stream>;

	/** A contact name to its jid, other input unchanged **/
	final resolve:String->String;

	/** The available full jids of a bare jid **/
	final resources:String->Array<String>;

	public function new(resolve:String->String, resources:String->Array<String>) {
		this.resolve = resolve;
		this.resources = resources;
	}

	public function commands():Array<Commands.Command>
		return [
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
	}

	public function online() {}

	public function detach()
		stream = null;

	function info(?jid:String, ?node:String, out:Output) {
		final target = describe(jid, node);
		ServiceDiscovery.discoInfo(stream, jid, node, res -> switch res {
			case Result(payload):
				if (payload == null) {
					out.info('$target: no information');
					return;
				}
				final info = ServiceDiscovery.parseInfo(payload);
				out.print(Term.style(target, 1));
				if (info.identities.length > 0) {
					out.print("  identities:");
					for (i in info.identities)
						out.print('    ${i.category}/${i.type}' + (i.name != null ? '  ${i.name}' : '') + (i.lang != null ? Term.style(' [${i.lang}]', 2) : ''));
				}
				if (info.features.length > 0) {
					out.print("  features:");
					final features = info.features.copy();
					features.sort(Reflect.compare);
					for (f in features)
						out.print('    $f');
				}
				for (form in info.forms) {
					out.print('  ${form.formType ?? "form"}:');
					for (field in form.fields)
						if (field.variable != null && field.variable != xmpp.DataForm.FORM_TYPE)
							out.print('    ${field.label ?? field.variable}: ${(field.values ?? []).join(", ")}');
				}
			case Error(e):
				out.error('$target: ${errorText(e)}');
		});
	}

	function items(?jid:String, ?node:String, out:Output) {
		final target = describe(jid, node);
		ServiceDiscovery.discoItems(stream, jid, node, res -> switch res {
			case Result(payload):
				final items = (payload == null) ? [] : ServiceDiscovery.parseItems(payload);
				if (items.length == 0) {
					out.info('$target: no items');
					return;
				}
				out.print(Term.style(target, 1));
				for (item in items)
					out.print('  ${item.jid}' + (item.node != null ? Term.style(' node=${item.node}', 2) : '') + (item.name != null ? '  ${item.name}' : ''));
			case Error(e):
				out.error('$target: ${errorText(e)}');
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
		for (target in targets)
			SoftwareVersion.getSoftwareVersion(stream, target, res -> switch res {
				case Result(payload):
					final info = SoftwareVersion.parse(payload);
					if (info.name == null && info.version == null && info.os == null)
						out.info('$target: no software information');
					else
						out.print('$target: ' + [info.name, info.version].filter(v -> v != null).join(" ")
							+ (info.os != null ? Term.style(' (${info.os})', 2) : ''));
				case Error(e):
					out.error('$target: ${errorText(e)}');
			});
	}

	function describe(?jid:String, ?node:String):String
		return (jid ?? stream.domain) + (node != null ? ' (node $node)' : '');

	static function errorText(e:xmpp.Stanza.Error):String
		return e.condition + (e.text != null ? ': ${e.text}' : '');
}
