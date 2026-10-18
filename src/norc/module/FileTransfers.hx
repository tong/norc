package norc.module;

import haxe.io.Path;
import norc.Commands;
import norc.Files;
import norc.Module;
import norc.Output;
import norc.Term;
import sys.FileSystem;
import sys.io.File;
import sys.thread.Thread;
import xmpp.FileSharing;
import xmpp.Jid;
import xmpp.Jingle;
import xmpp.JingleFileTransfer;
import xmpp.JingleIBB;
import xmpp.JingleS5B;
import xmpp.JingleS5BNetwork;
import xmpp.ServiceDiscovery;
import xmpp.client.Stream;

using StringTools;

private enum TransferState {
	/** Own file being read for its size and hash, offered then **/
	Preparing;

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

	/** Bytes transferred (preparing: read for the hash) **/
	var done:Float;

	/** Where status messages go: of the command which started or accepted the transfer **/
	var out:Output;

	/** Ended with `/file abort` **/
	var ?aborted:Bool;
}

/**
	Sends and receives files with Jingle file transfer (XEP-0234) over SOCKS5 bytestreams (direct, or through the
	proxy of the server), falling back to in-band bytestreams if no connection can be established.

	Direct connections offer the local address to the peer: only to contacts files are sent to or accepted from.

	Files of any size: they are read and written as they are transferred, never kept in memory. A file sent is read
	once before (in a thread) for its size and hash; a file received is written to `<file>.part`, renamed once verified.
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

	/** The shared directories (`share.<name>`), `null` without **/
	final shares:Null<Shares>;

	public function new(context:Context, contacts:Contacts, sessions:JingleSessions, downloadDir:String, ?shares:Shares) {
		super(context);
		this.contacts = contacts;
		this.sessions = sessions;
		this.downloadDir = downloadDir;
		this.shares = (shares != null && shares.enabled()) ? shares : null;
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
						description: "abort a file transfer (sending, receiving, your file being read or your offer not accepted yet); an offer to you is declined",
						online: true,
						run: (args, out) -> abort(args[0] != null ? Std.parseInt(args[0]) : null, out),
						complete: ["id" => _ -> [for (t in transfers) '${t.id}']]
					},
					{
						name: "shared",
						description: "your shared directories (share.<name> in the config), their files, who may download them (share_access)",
						run: (args, out) -> listShares(out)
					},
					{
						name: "browse",
						args: "<jid> [path...]",
						description: "the files a contact shares: its directories, or those of path (e.g. music/album)",
						online: true,
						run: (args, out) -> browse(args[0], args[1], out)
					},
					{
						name: "get",
						args: "<jid> <path> [target...]",
						description: "download a file a contact shares (path as /file browse lists it), to target (a file or directory) or the download directory",
						online: true,
						run: (args, out) -> get(args[0], args[1], args[2], out)
					},
					{
						name: "transfers",
						description: "list pending file offers, your files being read before they are offered (with progress), and active transfers",
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

	override public function attach(stream:Stream) {
		super.attach(stream);
		// listings of the shared directories, for the contacts allowed
		if (shares != null)
			FileSharing.handleRequests(stream, (from, node) -> shares.listing(node), from -> allowedToShare(from));
	}

	override public function online() {
		discoverProxies();
		// the hashes of new and changed files, for listings and requests
		if (shares != null)
			shares.index(context.post);
	}

	function allowedToShare(jid:String):Bool
		return shares != null && shares.allowed(Jid.parseBare(jid), contacts.seesPresence, contacts.groups);

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
		final file = (jid != null) ? Files.find(path, null, out) : null;
		if (file == null)
			return;
		// done once offered (or failed): a receiver is looked for first
		final done = out.wait();
		findReceiver(jid, out, peer -> {
			if (peer != null)
				offerFile(peer, file.path, out, done);
			else
				done();
		});
	}

	/**
		Offers the file at `path` to `peer` (a full jid): reads it first in a thread for its size and hash (seconds for
		large files), then sends it as it is read. `done` once offered, or failed.
	**/
	function offerFile(peer:String, path:String, out:Output, done:() -> Void) {
		// listed (and can be aborted) while it is read: the size of stat only for the progress (32-bit on HashLink)
		final size = try FileSystem.stat(path).size catch (_) 0;
		final t:Transfer = {
			id: nextId++,
			session: null,
			file: {name: Path.withoutDirectory(path), size: (size > 0) ? size : null},
			incoming: false,
			peer: peer,
			state: Preparing,
			done: 0,
			out: out
		};
		transfers.push(t);
		out.info('#${t.id} reading ${describe(t.file)} for its hash, then offering it to $peer (/file transfers, /file abort ${t.id})');
		Thread.create(() -> {
			var error:Null<String> = null;
			var size = 0.0;
			var hash = "";
			try {
				final r = Files.hashFile(path, () -> t.aborted == true, n -> t.done = n);
				if (r != null) {
					size = r.size;
					hash = r.hash;
				}
			} catch (e)
				error = Std.string(e);
			context.post(() -> {
				// aborted (reported by /file abort), or the session ended meanwhile
				if (t.aborted == true || !transfers.contains(t)) {
					done();
					return;
				}
				if (error != null) {
					transfers.remove(t);
					out.error('#${t.id} cannot read $path: $error');
					failed(t, 'cannot read $path: $error');
				} else
					offerData(t, path, size, hash, out);
				done();
			});
		});
	}

	/** Offers the file of `t` at `path` with its `size` and sha-256 `hash` (base64) **/
	function offerData(t:Transfer, path:String, size:Float, hash:String, out:Output) {
		final peer = t.peer;
		final file:JingleFile = {
			name: Path.withoutDirectory(path),
			size: size,
			date: try xmpp.DelayedDelivery.formatStamp(FileSystem.stat(path).mtime) catch (_) null,
			hashes: [{algo: "sha-256", value: hash}]
		};
		// read as it is sent (again after a fallback to in-band bytestreams)
		final data:JingleFileSource = {size: size, open: () -> File.read(path, true)};
		t.file = file;
		t.state = Active;
		t.done = 0;
		out.data({
			id: t.id,
			to: peer,
			file: file.name,
			size: file.size
		}, () -> out.info('#${t.id} offering ${describe(file)} to $peer'));
		t.session = JingleFileTransfer.sendFile(jingle, peer, file, data, {s5b: s5b, onProgress: sent -> progress(t, sent)},
			reason -> sent(t, reason, path, size));
		// sendFile starts sending once accepted
		final startSending = t.session.onAccept;
		t.session.onAccept = contents -> {
			out.info('#${t.id} $peer accepted ${file.name}');
			startSending(contents);
		}
	}

	/** A file sent (or not): the session ended with `reason` **/
	function sent(t:Transfer, reason:JingleReasonInfo, path:String, size:Float) {
		transfers.remove(t);
		if (t.aborted == true) {
			aborted(t);
			return;
		}
		final name = t.file.name ?? "file";
		switch reason.condition {
			case JingleReason.success:
				t.out.info('#${t.id} sent $name to ${t.peer}');
				emit("file-sent", [Jid.parseBare(t.peer), path], {
					to: t.peer,
					path: path,
					file: t.file.name,
					size: size
				});
			case JingleReason.decline:
				t.out.info('#${t.id} ${t.peer} declined $name');
				failed(t, "decline");
			case JingleReason.cancel:
				// e.g. /file abort of the receiver
				t.out.info('#${t.id} ${t.peer} cancelled $name');
				failed(t, "cancel");
			case _:
				t.out.error('#${t.id} sending $name failed: ${formatReason(reason)}');
				failed(t, formatReason(reason));
		}
	}

	/** The file `<target>.part` received into (renamed once verified), `null` with an error if it can't be written **/
	function openPart(t:Transfer, target:String, out:Output):Null<{part:String, output:haxe.io.Output}> {
		final part = '$target.part';
		final output = try File.write(part, true) catch (e) {
			out.error('#${t.id} cannot write $part: $e');
			return null;
		}
		return {part: part, output: output};
	}

	/** A file received (or not) into `part`: the session ended with `reason`; renamed to `target` if received **/
	function received(t:Transfer, reason:JingleReasonInfo, target:String, part:String, output:haxe.io.Output) {
		function discard() {
			try
				output.close()
			catch (_) {}
			try
				FileSystem.deleteFile(part)
			catch (_) {}
		}
		transfers.remove(t);
		if (reason.condition != JingleReason.success)
			discard();
		if (t.aborted == true) {
			aborted(t);
			return;
		}
		final name = t.file.name ?? "file";
		if (reason.condition == JingleReason.cancel) {
			t.out.info('#${t.id} ${t.peer} cancelled $name');
			failed(t, "cancel");
			return;
		}
		if (reason.condition != JingleReason.success) {
			t.out.error('#${t.id} receiving $name failed: ${formatReason(reason)}');
			failed(t, formatReason(reason));
			return;
		}
		try {
			output.close();
			FileSystem.rename(part, target);
			t.out.info('#${t.id} saved $target');
			emit("file-received", [Jid.parseBare(t.peer), target], {from: t.peer, path: target});
		} catch (e) {
			discard();
			t.out.error('#${t.id} cannot write $target: $e');
			failed(t, 'cannot write $target: $e');
		}
	}

	/**
		`/file accept [id] [path]`: accepts a file offer (the only one, if `id` is not given) and saves the file
		to `path` (a file or directory), or the download directory.
	**/
	function accept(?id:Int, ?path:String, out:Output) {
		final t = offer(id, out);
		if (t == null)
			return;
		final target = try destination(t.file, path) catch (e) {
			out.error(Std.string(e));
			return;
		}
		// written as it arrives, renamed once verified
		final p = openPart(t, target, out);
		if (p == null)
			return;
		t.state = Active;
		t.out = out;
		out.data({id: t.id, path: target}, () -> out.info('#${t.id} receiving ${t.file.name ?? "file"} → $target'));
		JingleFileTransfer.receiveFile(t.session, {s5b: s5b, onProgress: n -> progress(t, n), output: p.output},
			(reason, _) -> received(t, reason, target, p.part, p.output));
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
		if (t.state == Preparing) {
			// the thread reading it stops; a contact downloading a shared file is told
			transfers.remove(t);
			if (t.session != null)
				t.session.terminate(JingleReason.cancel);
			out.info('#${t.id} aborted offering ${t.file.name ?? "file"}');
			failed(t, "aborted");
			return;
		}
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

	/** `/file transfers`: lists offers, own files being prepared and running transfers **/
	function list(out:Output) {
		final data = [
			for (t in transfers)
				{
					id: t.id,
					file: t.file.name,
					size: t.file.size,
					peer: t.peer,
					direction: t.incoming ? "receive" : "send",
					state: switch t.state {
						case Preparing: "preparing";
						case Offered: "offered";
						case Active: "active";
					},
					bytes: t.done
				}
		];
		out.data({transfers: data}, () -> {
			if (transfers.length == 0)
				out.info("no file transfers");
			for (t in transfers) {
				final state = switch t.state {
					case Preparing: "reading for its hash, then offering to";
					case Offered: "offered by";
					case Active: (t.incoming ? "receiving from" : "sending to");
				}
				final percent = (t.state != Offered && t.file.size != null && t.file.size > 0) ? ' ${Std.int(t.done / t.file.size * 100)}%' : '';
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
			if (t.state == Preparing) {
				// its thread stops, nothing is offered
				t.aborted = true;
				t.out.error('#${t.id} ${t.file.name ?? "file"}: not offered, disconnected');
				failed(t, "aborted");
			} else if (t.state == Active) {
				t.out.error('#${t.id} ${t.file.name ?? "file"}: transfer aborted');
				failed(t, "aborted");
			}
		transfers.resize(0);
	}

	function onOffer(session:JingleSession) {
		if (JingleFileTransfer.getFileRequest(session) != null) {
			answerRequest(session);
			return;
		}
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

	/** `/file shared`: the shared directories, their files (hashed), who may download them **/
	function listShares(out:Output) {
		if (shares == null) {
			out.info("no shared directories (share.<name> = <directory> in the config, share_access: who may download)");
			return;
		}
		final counts = shares.counts();
		final list = [for (s in shares.list()) {name: s.name, dir: s.dir, count: counts.get(s.name)}];
		out.data({shares: [for (s in list) {name: s.name, dir: s.dir, files: s.count.files, hashed: s.count.hashed}], access: shares.describeAccess()}, () -> {
			for (s in list)
				out.print('  ${s.name}  ${Config.contractHome(s.dir)}  ${s.count.files} files'
					+ (s.count.hashed < s.count.files ? Term.style(' (${s.count.files - s.count.hashed} not hashed yet)', 2) : ''));
			out.info('who may list and download: ${shares.describeAccess()} (share_access); contacts: /file browse ${Jid.parseBare(stream?.jid ?? "you")}');
		});
	}

	/** The client of `input` (a jid or contact) sharing files: the full jid given, or a client of the contact with XEP-0329 **/
	function findSharer(input:String, out:Output, callback:Null<String>->Void) {
		final jid = contacts.resolve(input, out);
		if (jid == null)
			return callback(null);
		if (Jid.parseResource(jid) != null)
			return callback(jid);
		final candidates = contacts.resources(Jid.parseBare(jid));
		if (candidates.length == 0) {
			out.error('$jid is not online');
			return callback(null);
		}
		Discovery.findFeature(stream, candidates, FileSharing.XMLNS, peer -> {
			if (peer == null)
				out.error('no client of $jid shares files (${candidates.join(", ")})');
			callback(peer);
		});
	}

	/** A shared path as given: without `/` at the start and end, `null` for the root **/
	static function sharedPath(path:Null<String>):Null<String> {
		final p = (path ?? "").trim();
		final stripped = ~/^\/+|\/+$/g.replace(p, "");
		return (stripped.length == 0) ? null : stripped;
	}

	/** `/file browse <jid> [path]`: the shared directories of a contact, or the directories and files of `path` **/
	function browse(input:String, path:Null<String>, out:Output) {
		final node = sharedPath(path);
		final done = out.wait();
		findSharer(input, out, peer -> {
			if (peer == null)
				return done();
			request(out, 'cannot list ${node ?? "the files"} of $peer', h -> FileSharing.list(stream, peer, node, h), payload -> {
				final listing = FileSharing.parseListing(payload) ?? {directories: [], files: []};
				out.data({
					jid: peer,
					path: node,
					directories: listing.directories,
					files: [for (f in listing.files) {name: f.name, size: f.size, date: f.date, hash: (f.hashes != null && f.hashes.length > 0) ? f.hashes[0].value : null}]
				}, () -> {
					if (listing.directories.length == 0 && listing.files.length == 0)
						out.info('$peer shares nothing' + (node != null ? ' in $node' : ''));
					final prefix = (node != null) ? '$node/' : '';
					for (d in listing.directories)
						out.print('  ' + Term.style('$prefix$d/', 36));
					for (f in listing.files)
						out.print('  $prefix${f.name}' + Term.style((f.size != null ? '  ${Term.size(f.size)}' : '') + (f.date != null ? '  ${f.date.substr(0, 10)}' : ''), 2));
					if (listing.files.length > 0)
						out.info('download: /file get ${Jid.parseBare(peer)} $prefix${listing.files[0].name}');
					else if (listing.directories.length > 0)
						out.info('a directory: /file browse ${Jid.parseBare(peer)} $prefix${listing.directories[0]}');
				});
			});
			done();
		});
	}

	/**
		`/file get <jid> <path> [target]`: requests a shared file of a contact: its details first (size, hash: the data
		is verified with them), then the file with Jingle, saved like accepted offers.
	**/
	function get(input:String, path:String, target:Null<String>, out:Output) {
		final node = sharedPath(path);
		if (node == null) {
			out.error('give the path of a file, as /file browse lists it');
			return;
		}
		final done = out.wait();
		findSharer(input, out, peer -> {
			if (peer == null)
				return done();
			request(out, 'cannot get $node of $peer', h -> FileSharing.list(stream, peer, node, h), payload -> {
				final details = FileSharing.parseListing(payload)?.files[0];
				final file:JingleFile = {name: node, size: details?.size, hashes: details?.hashes};
				final t:Transfer = {
					id: nextId++,
					session: null,
					file: {name: Path.withoutDirectory(node), size: details?.size, hashes: details?.hashes},
					incoming: true,
					peer: peer,
					state: Active,
					done: 0,
					out: out
				};
				final dest = try destination(t.file, target) catch (e) {
					out.error(Std.string(e));
					return;
				}
				final p = openPart(t, dest, out);
				if (p == null)
					return;
				transfers.push(t);
				out.data({id: t.id, path: dest}, () -> out.info('#${t.id} downloading ${describe(t.file)} from $peer → $dest'));
				t.session = JingleFileTransfer.requestFile(jingle, peer, file, {s5b: s5b, onProgress: n -> progress(t, n), output: p.output},
					(reason, _) -> received(t, reason, dest, p.part, p.output));
			});
			done();
		});
	}

	/**
		A contact requests a shared file: only those allowed (`share_access`), only files inside the shares. Sent with
		its hash: cached, else read first (listed while it is read, can be aborted).
	**/
	function answerRequest(session:JingleSession) {
		final request = JingleFileTransfer.getFileRequest(session);
		final path = request.name ?? "";
		final allowed = shares != null && allowedToShare(session.peer);
		final local = allowed ? shares.resolve(path) : null;
		if (local == null || FileSystem.isDirectory(local)) {
			// not shared with this contact (declined), or no such file: the same text, nothing revealed
			session.terminate(allowed ? failed_application : JingleReason.decline, (local == null) ? 'no such file' : 'a directory');
			return;
		}
		final t:Transfer = {
			id: nextId++,
			session: session,
			file: shares.describe(local, path),
			incoming: false,
			peer: session.peer,
			state: Preparing,
			done: 0,
			out: TermOutput.instance
		};
		transfers.push(t);
		Term.info('#${t.id} ${session.peer} downloads $path (/file abort ${t.id})');
		// the requester may end it while the file is read
		session.onTerminate = reason -> if (transfers.remove(t)) failed(t, "cancel");
		function answer(size:Float, hash:String) {
			if (!transfers.contains(t) || t.aborted == true)
				return;
			t.state = Active;
			t.done = 0;
			final file:JingleFile = {name: path, size: size, date: t.file.date, hashes: [{algo: "sha-256", value: hash}]};
			JingleFileTransfer.answerFileRequest(session, file, {size: size, open: () -> File.read(local, true)},
				{s5b: s5b, onProgress: n -> progress(t, n)}, reason -> sent(t, reason, local, size));
		}
		final cached = shares.hashed(local);
		if (cached != null)
			return answer(cached.size, cached.hash);
		Thread.create(() -> {
			final r = try Files.hashFile(local, () -> t.aborted == true || !transfers.contains(t), n -> t.done = n) catch (_) null;
			context.post(() -> {
				if (r == null) {
					if (transfers.remove(t)) {
						failed(t, "cannot read");
						session.terminate(failed_application, 'cannot read the file');
					}
					return;
				}
				shares.remember(local, r.size, r.hash);
				answer(r.size, r.hash);
			});
		});
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

	function progress(t:Transfer, bytes:Float) {
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
