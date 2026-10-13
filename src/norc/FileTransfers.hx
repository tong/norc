package norc;

import haxe.io.Bytes;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import xmpp.Jid;
import xmpp.Jingle;
import xmpp.Response;
import xmpp.ServiceDiscovery;
import xmpp.client.Stream;

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
	var file:JingleFile;
	var incoming:Bool;
	var state:TransferState;

	/** Bytes transferred **/
	var done:Int;
}

/**
	Sends and receives files with Jingle file transfer (XEP-0234) over SOCKS5 bytestreams (direct, or through the
	proxy of the server), falling back to in-band bytestreams if no connection can be established.

	Direct connections offer the local address to the peer: only to contacts files are sent to or accepted from.

	Files are kept in memory while they are transferred, so their size is limited (`MAX_SIZE`).
**/
class FileTransfers implements Module {
	/** Features to advertise for service discovery **/
	public static final FEATURES = [
		JingleFileTransfer.XMLNS,
		JingleS5B.XMLNS,
		JingleIBB.XMLNS,
		JingleFileTransfer.XMLNS_HASHES,
		"urn:xmpp:hash-function-text-names:sha-1",
		"urn:xmpp:hash-function-text-names:sha-256"
	];

	/** Largest file sent or accepted (bytes) **/
	public static inline var MAX_SIZE = 100 * 1024 * 1024;

	final downloadDir:String;

	/** The stream and its session manager while attached **/
	var stream:Null<Stream>;
	var jingle:Null<Jingle>;

	/** Returns the available full jids of a bare jid **/
	final resources:String->Array<String>;

	final transfers = new Array<Transfer>();
	var nextId = 1;

	/** SOCKS5 bytestreams: network access and the proxies found (`discoverProxies`) **/
	final s5b:JingleS5BConfig;

	/**
		`post` runs a callback on the main thread (callbacks of the sockets of transfers).
	**/
	public function new(downloadDir:String, post:(() -> Void)->Void, resources:String->Array<String>) {
		this.downloadDir = downloadDir;
		this.resources = resources;
		s5b = {network: new JingleS5BSysNetwork(post), proxies: []};
	}

	public function commands():Array<Commands.Command>
		return [
			{
				name: "send",
				args: "<jid> <path...>",
				description: "send a file (without resource: to a client of the contact supporting file transfer)",
				online: true,
				run: args -> send(args[0], args[1])
			},
			{
				name: "accept",
				args: "[#id] [path...]",
				description: "accept a file offer, save it to path (a file or directory) or the download directory",
				online: true,
				run: args -> accept(args[0] != null ? Std.parseInt(args[0]) : null, args[1])
			},
			{
				name: "decline",
				args: "[#id]",
				description: "decline a file offer",
				online: true,
				run: args -> decline(args[0] != null ? Std.parseInt(args[0]) : null)
			},
			{
				name: "files",
				description: "list file offers and transfers",
				run: args -> list()
			}
		];

	public function features():Array<String>
		return FEATURES;

	public function attach(stream:Stream) {
		this.stream = stream;
		jingle = new Jingle(stream);
		jingle.onSessionInitiate = onOffer;
	}

	public function online()
		discoverProxies();

	public function detach() {
		clear();
		s5b.proxies.resize(0);
		stream = null;
		jingle = null;
	}

	/**
		`/send <jid> <path>`: offers the file at `path` to `jid`.
		Without a resource, the first available resource of the contact supporting file transfer is used.
	**/
	public function send(jid:String, path:String) {
		path = expandHome(path);
		if (!FileSystem.exists(path) || FileSystem.isDirectory(path)) {
			Term.error('no such file: $path');
			return;
		}
		final stat = FileSystem.stat(path);
		if (stat.size > MAX_SIZE) {
			Term.error('file too large: ${formatSize(stat.size)} (max ${formatSize(MAX_SIZE)})');
			return;
		}
		findReceiver(jid, peer -> {
			if (peer == null)
				return;
			final data = try File.getBytes(path) catch (e) {
				Term.error('cannot read $path: $e');
				return;
			}
			final file:JingleFile = {
				name: Path.withoutDirectory(path),
				size: data.length,
				date: xmpp.DelayedDelivery.formatStamp(stat.mtime)
			};
			final t:Transfer = {
				id: nextId++,
				session: null,
				file: file,
				incoming: false,
				state: Active,
				done: 0
			};
			info('#${t.id} offering ${describe(file)} to $peer');
			t.session = JingleFileTransfer.sendFile(jingle, peer, file, data, {s5b: s5b, onProgress: sent -> progress(t, sent)}, reason -> {
				transfers.remove(t);
				switch reason.condition {
					case JingleReason.success: info('#${t.id} sent ${file.name} to $peer');
					case JingleReason.decline: info('#${t.id} $peer declined ${file.name}');
					case _: Term.error('#${t.id} sending ${file.name} failed: ${formatReason(reason)}');
				}
			});
			// sendFile starts sending once accepted
			final startSending = t.session.onAccept;
			t.session.onAccept = contents -> {
				info('#${t.id} $peer accepted ${file.name}');
				startSending(contents);
			}
			transfers.push(t);
		});
	}

	/**
		`/accept [id] [path]`: accepts a file offer (the only one, if `id` is not given) and saves the file
		to `path` (a file or directory), or the download directory.
	**/
	public function accept(?id:Int, ?path:String) {
		final t = offer(id);
		if (t == null)
			return;
		if (t.file.size != null && t.file.size > MAX_SIZE) {
			Term.error('#${t.id} file too large: ${formatSize(t.file.size)} (max ${formatSize(MAX_SIZE)})');
			return;
		}
		final target = try destination(t.file, path) catch (e) {
			Term.error(Std.string(e));
			return;
		}
		t.state = Active;
		info('#${t.id} receiving ${t.file.name ?? "file"} → $target');
		JingleFileTransfer.receiveFile(t.session, {s5b: s5b, onProgress: received -> progress(t, received)}, (reason, data) -> {
			transfers.remove(t);
			if (reason.condition != JingleReason.success || data == null) {
				Term.error('#${t.id} receiving ${t.file.name ?? "file"} failed: ${formatReason(reason)}');
				return;
			}
			try {
				File.saveBytes(target, data);
				info('#${t.id} saved $target');
			} catch (e)
				Term.error('#${t.id} cannot write $target: $e');
		});
	}

	/** `/decline [id]`: declines a file offer **/
	public function decline(?id:Int) {
		final t = offer(id);
		if (t == null)
			return;
		transfers.remove(t);
		t.session.terminate(JingleReason.decline);
		info('#${t.id} declined ${t.file.name ?? "file"}');
	}

	/** `/files`: lists offers and running transfers **/
	public function list() {
		if (transfers.length == 0)
			info("no file transfers");
		for (t in transfers) {
			final state = switch t.state {
				case Offered: "offered by";
				case Active: (t.incoming ? "receiving from" : "sending to");
			}
			final percent = (t.state == Active && t.file.size != null && t.file.size > 0) ? ' ${Std.int(t.done / t.file.size * 100)}%' : '';
			Sys.println('  #${t.id} ${describe(t.file)} $state ${t.session.peer}$percent');
		}
	}

	/**
		Looks for SOCKS5 bytestreams proxies of the server (e.g. `proxy.example.org`), offered in addition to
		direct connections: these work if the peers can't connect to each other directly (e.g. behind NAT).
	**/
	public function discoverProxies() {
		ServiceDiscovery.discoItems(stream, null, res -> switch res {
			case Result(payload) if (payload != null):
				for (item in ServiceDiscovery.parseItems(payload))
					ServiceDiscovery.discoInfo(stream, item.jid, res -> switch res {
						case Result(payload) if (payload != null):
							final info = ServiceDiscovery.parseInfo(payload);
							if (info.identities.filter(i -> i.category == "proxy" && i.type == "bytestreams")
								.length > 0) JingleS5B.requestStreamhost(stream, item.jid, res -> {
									final host = JingleS5B.parseStreamhost(res.payload);
									if (host != null && s5b.proxies.filter(p -> p.jid == host.jid).length == 0)
										s5b.proxies.push(host);
								});
						case _:
					});
			case _:
		});
	}

	/** Ends all transfers (the session ended) **/
	public function clear() {
		for (t in transfers)
			Term.error('#${t.id} ${t.file.name ?? "file"}: transfer aborted');
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
			incoming: true,
			state: Offered,
			done: 0
		};
		transfers.push(t);
		session.onTerminate = reason -> {
			if (transfers.remove(t))
				info('#${t.id} ${session.peer} cancelled the offer of ${file.name ?? "a file"}'
					+ (reason.condition != JingleReason.cancel ? ' (${formatReason(reason)})' : ''));
		}
		info('#${t.id} ${session.peer} offers ${describe(file)}: /accept ${t.id} or /decline ${t.id}');
	}

	function offer(id:Null<Int>):Null<Transfer> {
		final offers = transfers.filter(t -> t.state == Offered);
		if (id == null) {
			if (offers.length == 1)
				return offers[0];
			Term.error(offers.length == 0 ? "no file offers" : 'several file offers, give the number: ${[for (t in offers) '#${t.id}'].join(", ")}');
			return null;
		}
		for (t in offers)
			if (t.id == id)
				return t;
		Term.error('no file offer #$id');
		return null;
	}

	/** Picks the full jid to send a file to: `jid` itself, or a resource supporting file transfer **/
	function findReceiver(jid:String, callback:Null<String>->Void) {
		if (Jid.parseResource(jid) != null) {
			callback(jid);
			return;
		}
		final candidates = resources(Jid.parseBare(jid));
		if (candidates.length == 0) {
			Term.error('$jid is not online');
			callback(null);
			return;
		}
		function next(i:Int) {
			if (i >= candidates.length) {
				Term.error('no client of $jid supports file transfer (${candidates.join(", ")})');
				callback(null);
				return;
			}
			ServiceDiscovery.discoInfo(stream, candidates[i], res -> switch res {
				case Result(payload) if (payload != null
					&& ServiceDiscovery.parseInfo(payload).features.contains(JingleFileTransfer.XMLNS)):
					callback(candidates[i]);
				case _:
					next(i + 1);
			});
		}
		next(0);
	}

	/** Path to save a received file: in `path` (a directory or file) or the download directory, never overwriting a file **/
	function destination(file:JingleFile, ?path:String):String {
		// The name is chosen by the peer: no directories
		var name = Path.withoutDirectory((file.name ?? "").replace("\\", "/")).trim();
		name = ~/[\x00-\x1f]/g.replace(name, "");
		if (name == "" || name == "." || name == "..")
			name = "file";
		if (path != null) {
			path = expandHome(path);
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
			info('#${t.id} ${now * 25}%');
	}

	static function info(msg:String)
		Term.info(msg);

	static function describe(file:JingleFile):String
		return (file.name ?? "a file") + (file.size != null ? ' (${formatSize(file.size)})' : '');

	static function formatReason(reason:JingleReasonInfo):String
		return reason.condition + (reason.text != null ? ': ${reason.text}' : '');

	public static function formatSize(bytes:Float):String {
		if (bytes < 1024)
			return '${Std.int(bytes)} B';
		final units = ["KB", "MB", "GB"];
		var v = bytes / 1024;
		var i = 0;
		while (v >= 1024 && i < units.length - 1) {
			v /= 1024;
			i++;
		}
		return '${Math.round(v * 10) / 10} ${units[i]}';
	}

	static inline function expandHome(path:String):String
		return Config.expandHome(path);
}
