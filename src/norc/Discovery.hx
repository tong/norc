package norc;

import xmpp.Response;
import xmpp.ServiceDiscovery;
import xmpp.XML;
import xmpp.client.Stream;

/**
	Service discovery (XEP-0030): `/disco info` and `/disco items`.
**/
class Discovery implements Module {
	var stream:Null<Stream>;

	public function new() {}

	public function commands():Array<Commands.Command>
		return [
			{
				name: "disco",
				description: "service discovery",
				subcommands: [
					{
						name: "info",
						args: "[jid] [node]",
						description: "identities and features of an entity (default: the server)",
						online: true,
						run: args -> info(args[0], args[1])
					},
					{
						name: "items",
						args: "[jid] [node]",
						description: "items of an entity, e.g. the services of the server (default: the server)",
						online: true,
						run: args -> items(args[0], args[1])
					}
				]
			}
		];

	public function features():Array<String>
		return [];

	public function attach(stream:Stream)
		this.stream = stream;

	public function online() {}

	public function detach()
		stream = null;

	function info(?jid:String, ?node:String) {
		final target = describe(jid, node);
		ServiceDiscovery.discoInfo(stream, jid, node, res -> switch res {
			case Result(payload):
				if (payload == null) {
					Term.info('$target: no information');
					return;
				}
				final info = ServiceDiscovery.parseInfo(payload);
				Sys.println(Term.style(target, 1));
				if (info.identities.length > 0) {
					Sys.println("  identities:");
					for (i in info.identities)
						Sys.println('    ${i.category}/${i.type}' + (i.name != null ? '  ${i.name}' : '') + (i.lang != null ? Term.style(' [${i.lang}]', 2) : ''));
				}
				if (info.features.length > 0) {
					Sys.println("  features:");
					final features = info.features.copy();
					features.sort(Reflect.compare);
					for (f in features)
						Sys.println('    $f');
				}
				for (form in info.forms) {
					Sys.println('  ${form.formType ?? "form"}:');
					for (field in form.fields)
						if (field.variable != null && field.variable != xmpp.DataForm.FORM_TYPE)
							Sys.println('    ${field.label ?? field.variable}: ${(field.values ?? []).join(", ")}');
				}
			case Error(e):
				Term.error('$target: ${errorText(e)}');
		});
	}

	function items(?jid:String, ?node:String) {
		final target = describe(jid, node);
		ServiceDiscovery.discoItems(stream, jid, node, res -> switch res {
			case Result(payload):
				final items = (payload == null) ? [] : ServiceDiscovery.parseItems(payload);
				if (items.length == 0) {
					Term.info('$target: no items');
					return;
				}
				Sys.println(Term.style(target, 1));
				for (item in items)
					Sys.println('  ${item.jid}' + (item.node != null ? Term.style(' node=${item.node}', 2) : '') + (item.name != null ? '  ${item.name}' : ''));
			case Error(e):
				Term.error('$target: ${errorText(e)}');
		});
	}

	function describe(?jid:String, ?node:String):String
		return (jid ?? stream.domain) + (node != null ? ' (node $node)' : '');

	static function errorText(e:xmpp.Stanza.Error):String
		return e.condition + (e.text != null ? ': ${e.text}' : '');
}
