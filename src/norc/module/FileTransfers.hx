package norc.module;

import haxe.io.Path;
import norc.Commands;
import norc.Config;
import norc.Files;
import norc.Module;
import norc.Output;
import norc.Term;
import sys.FileSystem;
import sys.io.File;
import xmpp.Jid;
import xmpp.Jingle;
import xmpp.JingleFileTransfer;
import xmpp.JingleIBB;
import xmpp.JingleS5B;
import xmpp.JingleS5BNetwork;
import xmpp.ServiceDiscovery;

using StringTools;

private enum TransferState {
	/** Offered by the peer, not yet accepted **/
	Offered;

	/** Sending or receiving **/
	Active;
}

private typedef Transfer = {
	var id:Int;
	var session:JingleSession;

	/** Full jid of the other side **/
	var peer:String;

	var file:JingleFile;
	var incoming:Bool;
	var state:TransferState;

	/** Bytes transferred **/
	var done:Int;

	/** Where status messages go: of the command which started or accepted the transfer **/
	var out:Output;

	/** Ended with `/file abort` **/
	var ?aborted:Bool;
}

/**
	Sends and receives files with Jingle file transfer (XEP-0234) over SOCKS5 bytestreams (direct, or through the
	proxy of the server), falling back to in-band bytestreams if no connection can be established.

	Direct connections offer the local address to the peer: only to contacts files are sent to or accepted from.

	Files are kept in memory while they are transferred, so their size is limited (`MAX_SIZE`).
**/
class FileTransfers extends Module {
	static final FEATURES = [
		JingleFileTransfer.XMLNS,
		JingleS5B.XMLNS,
		JingleIBB.XMLNS,
		JingleFileTransfer.XMLNS_HASHES,
		"urn:xmpp:hash-function-text-names:sha-1",
		"urn:xmpp:hash-function-text-names:sha-256"
	];

	/** Largest file sent or accepted (bytes) **/
	public static inline var MAX_SIZE = 100 * 1024 * 1024;

	final contacts:Contacts;
	final sessions:JingleSessions;
	final downloadDir:String;

	/** The session manager while attached **/
	var jingle(get, never):Null<Jingle>;

	inline function get_jingle()
		return sessions.jingle;

	final transfers = new Array<Transfer>();
	var nextId = 1;

	/** SOCKS5 bytestreams: network access (its sockets call back on the main thread) and the proxies found **/
	final s5b:JingleS5BConfig;

	public function new(context:Context, contacts:Contacts, sessions:JingleSessions, downloadDir:String) {
		super(context);
		this.contacts = contacts;
		this.sessions = sessions;
		this.downloadDir = downloadDir;
		sessions.handle(JingleFileTransfer.XMLNS, onOffer);
		s5b = {network: new JingleS5BSysNetwork(context.post), proxies: []};
	}

	override public function commands():Array<Commands.Command>
		return [
			{
				name: "file",
				description: "send and receive files",
				subcommands: [
					{
						name: "send",
						args: "<jid> <path...>",
						description: "send a file to a jid or contact name (without resource: to a client supporting file transfer)",
						online: true,
						run: (args, out) -> send(args[0], args[1], out)
					},
					{
						name: "accept",
						args: "[#id] [path...]",
						description: "accept a file offer, save it to path (a file or directory) or the download directory",
						online: true,
						run: (args, out) -> accept(args[0] != null ? Std.parseInt(args[0]) : null, args[1], out),
						complete: ["id" => _ -> offerIds()]
					},
					{
						name: "decline",
						args: "[#id]",
						description: "decline a file offer",
						online: true,
						run: (args, out) -> decline(args[0] != null ? Std.parseInt(args[0]) : null, out),
						complete: ["id" => _ -> offerIds()]
					},
					{
						name: "abort",
						args: "[#id]",
						description: "abort a file transfer (sending, receiving, or your offer not accepted yet); an offer to you is declined",
						online: true,
						run: (args, out) -> abort(args[0] != null ? Std.parseInt(args[0]) : null, out),
						complete: ["id" => _ -> [for (t in transfers) '${t.id}']]
					},
					{
						name: "transfers",
						description: "list pending file offers and active transfers",
						run: (args, out) -> list(out)
					}
				]
			}
		];

	/** The transfers sending or receiving (`active`), and offers not accepted yet (`pending`), e.g. for the prompt **/
	public function counts():{active:Int, pending:Int} {
		final pending = transfers.filter(t -> t.state == Offered).length;
		return {active: transfers.length - pending, pending: pending};
	}

	override public function features():Array<String>
		return FEATURES;

	override public function online()
		discoverProxies();

	override public function detach() {
		clear();
		s5b.proxies.resize(0);
		super.detach();
	}

	/**
		`/file send <jid> <path>`: offers the file at `path` to `jid`.
		Without a resource, the first available resource of the contact supporting file transfer is used.
	**/
	function send(input:String, path:String, out:Output) {
		final jid = contacts.resolve(input, out);
		final file = (jid != null) ? Files.find(path, MAX_SIZE, out) : null;
		if (file == null)
			return;
		// done once offered (or failed): a receiver is looked for first
		final done = out.wait();
		findReceiver(jid, out, peer -> {
			if (peer != null)
				offerFile(peer, file.path, out);
			done();
		});
	}

	/** Offers the file at `path` to `peer` (a full jid) **/
	function offerFile(peer:String, path:String, out:Output) {
		final data = try File.getBytes(path) catch (e) {
			out.error('cannot read $path: $e');
			return;
		}
		final file:JingleFile = {
			name: Path.withoutDirectory(path),
			size: data.length,
			date: xmpp.DelayedDelivery.formatStamp(FileSystem.stat(path).mtime)
		};
		final t:Transfer = {
			id: nextId++,
			session: null,
			file: file,
			incoming: false,
			peer: peer,
			state: Active,
			done: 0,
			out: out
		};
		out.data({
			id: t.id,
			to: peer,
			file: file.name,
			size: file.size
		}, () -> out.info('#${t.id} offering ${describe(file)} to $peer'));
		t.session = JingleFileTransfer.sendFile(jingle, peer, file, data, {s5b: s5b, onProgress: sent -> progress(t, sent)}, reason -> {
			transfers.remove(t);
			if (t.aborted == true) {
				aborted(t);
				return;
			}
			switch reason.condition {
				case JingleReason.success:
					out.info('#${t.id} sent ${file.name} to $peer');
					emit("file-sent", [Jid.parseBare(peer), path], {
						to: peer,
						path: path,
						file: file.name,
						size: data.length
					});
				case JingleReason.decline:
					out.info('#${t.id} $peer declined ${file.name}');
					failed(t, "decline");
				case JingleReason.cancel:
					// e.g. /file abort of the receiver
					out.info('#${t.id} $peer cancelled ${file.name}');
					failed(t, "cancel");
				case _:
					out.error('#${t.id} sending ${file.name} failed: ${formatReason(reason)}');
					failed(t, formatReason(reason));
			}
		});
		// sendFile starts sending once accepted
		final startSending = t.session.onAccept;
		t.session.onAccept = contents -> {
			out.info('#${t.id} $peer accepted ${file.name}');
			startSending(contents);
		}
		transfers.push(t);
	}

	/**
		`/file accept [id] [path]`: accepts a file offer (the only one, if `id` is not given) and saves the file
		to `path` (a file or directory), or the download directory.
	**/
	function accept(?id:Int, ?path:String, out:Output) {
		final t = offer(id, out);
		if (t == null)
			return;
		if (t.file.size != null && t.file.size > MAX_SIZE) {
			out.error('#${t.id} file too large: ${Term.size(t.file.size)} (max ${Term.size(MAX_SIZE)})');
			return;
		}
		final target = try destination(t.file, path) catch (e) {
			out.error(Std.string(e));
			return;
		}
		t.state = Active;
		t.out = out;
		out.data({id: t.id, path: target}, () -> out.info('#${t.id} receiving ${t.file.name ?? "file"} → $target'));
		JingleFileTransfer.receiveFile(t.session, {s5b: s5b, onProgress: received -> progress(t, received)}, (reason, data) -> {
			transfers.remove(t);
			if (t.aborted == true) {
				aborted(t);
				return;
			}
			if (reason.condition == JingleReason.cancel) {
				out.info('#${t.id} ${t.peer} cancelled ${t.file.name ?? "file"}');
				failed(t, "cancel");
				return;
			}
			if (reason.condition != JingleReason.success || data == null) {
				out.error('#${t.id} receiving ${t.file.name ?? "file"} failed: ${formatReason(reason)}');
				failed(t, formatReason(reason));
				return;
			}
			try {
				File.saveBytes(target, data);
				out.info('#${t.id} saved $target');
				emit("file-received", [Jid.parseBare(t.peer), target], {from: t.peer, path: target});
			} catch (e) {
				out.error('#${t.id} cannot write $target: $e');
				failed(t, 'cannot write $target: $e');
			}
		});
	}

	/** `/file decline [id]`: declines a file offer **/
	function decline(?id:Int, out:Output) {
		final t = offer(id, out);
		if (t == null)
			return;
		transfers.remove(t);
		t.session.terminate(JingleReason.decline);
		out.info('#${t.id} declined ${t.file.name ?? "file"}');
	}

	/**
		`/file abort [id]`: ends a transfer (the only one, if `id` is not given): sending, receiving, or an own offer not
		accepted yet; an offer of the peer is declined. Nothing received is saved.
	**/
	function abort(?id:Int, out:Output) {
		final t = if (id != null) Lambda.find(transfers, t -> t.id == id) else (transfers.length == 1) ? transfers[0] : null;
		if (t == null) {
			out.error((id != null) ? 'no file transfer #$id' : (transfers.length == 0) ? "no file transfers" :
				'several file transfers, give the number: ${[for (t in transfers) '#${t.id}'].join(", ")}');
			return;
		}
		if (t.incoming && t.state == Offered) {
			decline(t.id, out);
			return;
		}
		t.aborted = true;
		t.out = out;
		// the callback of the transfer reports it (closing its connections)
		t.session.terminate(JingleReason.cancel);
	}

	/** A transfer ended with `/file abort` **/
	function aborted(t:Transfer) {
		final percent = (t.file.size != null && t.file.size > 0) ? ' at ${Std.int(t.done / t.file.size * 100)}%' : '';
		t.out.info('#${t.id} aborted ${t.incoming ? "receiving" : "sending"} ${t.file.name ?? "file"}$percent');
		failed(t, "aborted");
	}

	/** Numbers of the file offers, to complete input **/
	function offerIds():Array<String>
		return [for (t in transfers) if (t.state == Offered) '${t.id}'];

	/** `/file transfers`: lists offers and running transfers **/
	function list(out:Output) {
		final data = [
			for (t in transfers)
				{
					id: t.id,
					file: t.file.name,
					size: t.file.size,
					peer: t.peer,
					direction: t.incoming ? "receive" : "send",
					state: (t.state == Offered) ? "offered" : "active",
					bytes: t.done
				}
		];
		out.data({transfers: data}, () -> {
			if (transfers.length == 0)
				out.info("no file transfers");
			for (t in transfers) {
				final state = switch t.state {
					case Offered: "offered by";
					case Active: (t.incoming ? "receiving from" : "sending to");
				}
				final percent = (t.state == Active && t.file.size != null && t.file.size > 0) ? ' ${Std.int(t.done / t.file.size * 100)}%' : '';
				out.print('  #${t.id} ${describe(t.file)} $state ${t.peer}$percent');
			}
		});
	}

	/**
		Looks for SOCKS5 bytestreams proxies of the server (e.g. `proxy.example.org`), offered in addition to
		direct connections: these work if the peers can't connect to each other directly (e.g. behind NAT).
	**/
	function discoverProxies()
		ServiceDiscovery.discoItems(stream, null, res -> {
			for (item in ((res.payload != null) ? ServiceDiscovery.parseItems(res.payload) : []))
				ServiceDiscovery.discoInfo(stream, item.jid, res -> {
					final info = (res.payload != null) ? ServiceDiscovery.parseInfo(res.payload) : null;
					if (info != null && Lambda.exists(info.identities, i -> i.category == "proxy" && i.type == "bytestreams"))
						JingleS5B.requestStreamhost(stream, item.jid, res -> {
							final host = JingleS5B.parseStreamhost(res.payload);
							if (host != null && !Lambda.exists(s5b.proxies, p -> p.jid == host.jid))
								s5b.proxies.push(host);
						});
				});
		});

	/** Ends all transfers (the session ended) **/
	function clear() {
		for (t in transfers)
			if (t.state == Active) {
				t.out.error('#${t.id} ${t.file.name ?? "file"}: transfer aborted');
				failed(t, "aborted");
			}
		transfers.resize(0);
	}

	function onOffer(session:JingleSession) {
		final file = JingleFileTransfer.getFileOffer(session);
		if (file == null) {
			session.terminate(unsupported_applications);
			return;
		}
		final t:Transfer = {
			id: nextId++,
			session: session,
			file: file,
			peer: session.peer,
			incoming: true,
			state: Offered,
			done: 0,
			out: TermOutput.instance
		};
		transfers.push(t);
		session.onTerminate = reason -> {
			if (transfers.remove(t))
				t.out.info('#${t.id} ${session.peer} cancelled the offer of ${file.name ?? "a file"}'
					+ (reason.condition != JingleReason.cancel ? ' (${formatReason(reason)})' : ''));
		}
		Term.info('#${t.id} ${session.peer} offers ${describe(file)}: /file accept ${t.id} or /file decline ${t.id}');
		emit("file-offer", [
			Jid.parseBare(session.peer),
			file.name ?? "",
			file.size != null ? Std.string(Std.int(file.size)) : ""
		], {
			from: session.peer,
			file: file.name,
			size: file.size,
			id: t.id
		});
	}

	/** The file-failed event **/
	function failed(t:Transfer, reason:String)
		emit("file-failed", [Jid.parseBare(t.peer), t.file.name ?? "", reason], {
			peer: t.peer,
			file: t.file.name,
			reason: reason,
			direction: t.incoming ? "receive" : "send"
		});

	function offer(id:Null<Int>, out:Output):Null<Transfer> {
		final offers = transfers.filter(t -> t.state == Offered);
		if (id == null) {
			if (offers.length == 1)
				return offers[0];
			out.error(offers.length == 0 ? "no file offers" : 'several file offers, give the number: ${[for (t in offers) '#${t.id}'].join(", ")}');
			return null;
		}
		for (t in offers)
			if (t.id == id)
				return t;
		out.error('no file offer #$id');
		return null;
	}

	/** Picks the full jid to send a file to: `jid` itself, or a resource supporting file transfer **/
	function findReceiver(jid:String, out:Output, callback:Null<String>->Void) {
		if (Jid.parseResource(jid) != null) {
			callback(jid);
			return;
		}
		final candidates = contacts.resources(Jid.parseBare(jid));
		if (candidates.length == 0) {
			out.error('$jid is not online');
			callback(null);
			return;
		}
		Discovery.findFeature(stream, candidates, JingleFileTransfer.XMLNS, peer -> {
			if (peer == null)
				out.error('no client of $jid supports file transfer (${candidates.join(", ")})');
			callback(peer);
		});
	}

	/** Path to save a received file: in `path` (a directory or file) or the download directory, never overwriting a file **/
	function destination(file:JingleFile, ?path:String):String {
		// The name is chosen by the peer: no directories
		var name = Path.withoutDirectory((file.name ?? "").replace("\\", "/")).trim();
		name = ~/[\x00-\x1f]/g.replace(name, "");
		if (name == "" || name == "." || name == "..")
			name = "file";
		if (path != null) {
			path = Files.resolve(path);
			if (!FileSystem.exists(path) || !FileSystem.isDirectory(path))
				return unique(path);
		}
		final dir = path ?? downloadDir;
		if (!FileSystem.exists(dir))
			FileSystem.createDirectory(dir);
		return unique('$dir/$name');
	}

	static function unique(path:String):String {
		if (!FileSystem.exists(path))
			return path;
		final p = new Path(path);
		var i = 1;
		while (true) {
			final candidate = Path.join([p.dir ?? ".", '${p.file} ($i)' + (p.ext != null ? '.${p.ext}' : '')]);
			if (!FileSystem.exists(candidate))
				return candidate;
			i++;
		}
	}

	function progress(t:Transfer, bytes:Int) {
		final size = t.file.size;
		if (size == null || size <= 0)
			return;
		// print every 25%
		final before = Std.int(t.done / size * 4);
		t.done = bytes;
		final now = Std.int(bytes / size * 4);
		if (now > before && bytes < size)
			t.out.info('#${t.id} ${now * 25}%');
	}

	static function describe(file:JingleFile):String
		return (file.name ?? "a file") + (file.size != null ? ' (${Term.size(file.size)})' : '');

	static function formatReason(reason:JingleReasonInfo):String
		return reason.condition + (reason.text != null ? ': ${reason.text}' : '');
}
