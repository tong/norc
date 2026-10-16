package norc.module;

import norc.Commands;
import norc.Module;
import norc.Output;
import xmpp.Block;
import xmpp.HttpFileUpload;
import xmpp.Jid;
import xmpp.MessageArchiveManagement;
import xmpp.ServiceDiscovery;

/**
	What the server of the account offers, asked once after the login (service discovery of the server, of the own
	account and of the services of the server): commands needing it (`Command.requires`) are marked in `/help` and
	refused with a clear error. `/server` shows it, the `server` event has it.

	Until the answers arrive (and while disconnected) everything counts as supported.
**/
class Server extends Module {
	/** The features commands can require, with what they are for **/
	public static final FEATURES:Map<String, String> = [
		"mam" => "message archive (MAM)",
		"pep" => "personal eventing (PEP)",
		"blocking" => "blocking command",
		"upload" => "HTTP file upload",
		"carbons" => "message carbons"
	];

	/** The supported features (keys of `FEATURES`), `null` until known **/
	var supported:Null<Array<String>>;

	/** The upload service, if there is one **/
	public var uploadService(default, null):Null<String>;

	public function new(context:Context)
		super(context);

	override public function commands():Array<Commands.Command>
		return [
			{
				name: "server",
				description: "what your server offers (message archive, PEP, blocking, file upload, carbons)",
				online: true,
				run: (args, out) -> show(out)
			}
		];

	override public function online() {
		supported = null;
		uploadService = null;
		final found = new Array<String>();
		var pending = 3;
		function done() {
			if (--pending > 0)
				return;
			found.sort(Reflect.compare);
			supported = found;
			emit("server", [stream.domain, found.join(" ")], {
				server: stream.domain,
				features: found.join(" "),
				missing: [for (k in FEATURES.keys()) if (!found.contains(k)) k].join(" "),
				upload: uploadService
			});
		}
		ServiceDiscovery.discoInfo(stream, stream.domain, null, res -> {
			final info = (res.payload != null) ? ServiceDiscovery.parseInfo(res.payload) : null;
			if (info != null) {
				if (info.features.contains(Block.XMLNS))
					found.push("blocking");
				if (info.features.contains(xmpp.Carbons.XMLNS))
					found.push("carbons");
			}
			done();
		});
		// the account: its archive and PEP
		ServiceDiscovery.discoInfo(stream, Jid.parseBare(stream.jid), null, res -> {
			final info = (res.payload != null) ? ServiceDiscovery.parseInfo(res.payload) : null;
			if (info != null) {
				if (info.features.contains(MessageArchiveManagement.XMLNS))
					found.push("mam");
				if (Lambda.exists(info.identities, i -> i.category == "pubsub" && i.type == "pep"))
					found.push("pep");
			}
			done();
		});
		Discovery.findService(stream, HttpFileUpload.XMLNS, jid -> {
			if (jid != null) {
				uploadService = jid;
				found.push("upload");
			}
			done();
		});
	}

	override public function detach() {
		super.detach();
		supported = null;
	}

	/** `true` if the server offers `feature` (a key of `FEATURES`), `false` if not, `null` if not known (yet) **/
	public function supports(feature:String):Null<Bool>
		return (supported == null) ? null : supported.contains(feature);

	function show(out:Output) {
		final s = supported;
		if (s == null) {
			out.info("not known yet (asked after the login)");
			return;
		}
		final keys = [for (k in FEATURES.keys()) k];
		keys.sort(Reflect.compare);
		out.data({
			server: stream.domain,
			features: s.copy(),
			missing: [for (k in keys) if (!s.contains(k)) k],
			upload: uploadService
		}, () -> {
			out.print(stream.domain);
			for (k in keys)
				out.print('  ${s.contains(k) ? Term.style("✓", 32) : Term.style("✗", 31)} ${FEATURES.get(k)}'
					+ ((k == "upload" && uploadService != null) ? Term.style(' ($uploadService)', 2) : ''));
		});
	}
}
