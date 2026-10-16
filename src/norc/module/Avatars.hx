package norc.module;

import haxe.crypto.Base64;
import haxe.io.Bytes;
import norc.Commands;
import norc.Images;
import norc.Module;
import norc.Output;
import norc.Term;
import sys.FileSystem;
import sys.io.File;
import xmpp.Jid;
import xmpp.Presence;
import xmpp.Response;
import xmpp.UserAvatar;
import xmpp.VCard;
import xmpp.VCardAvatar;
import xmpp.XML;
import xmpp.client.Stream;

/** An avatar image in the cache **/
private typedef Avatar = {
	/** The SHA-1 hash of the image (hex) **/
	var id:String;

	var path:String;
	var type:String;
	var bytes:Int;
	var ?width:Int;
	var ?height:Int;
}

/**
	Avatars: PEP (XEP-0084), and vCard photos announced in presences (XEP-0153). `/avatar` saves the avatar of a contact
	(or the own) and shows where, `/avatar set` publishes the own (both ways), `/avatar remove` removes it.

	The avatars of contacts are loaded when they change, into the cache (`$XDG_CACHE_HOME/norc/avatars/<hash>.<ext>`,
	shared by all accounts, each image once); the `avatar` event has the file, and so do `message` events (`avatar`),
	e.g. for the icon of a notification. PEP avatars win over vCard photos. Images are checked against their hash.
**/
class Avatars extends Module {
	/** The height of an avatar shown in the terminal, in lines **/
	static inline var IMAGE_ROWS = 4;

	/** The largest image loaded **/
	static inline var MAX_LOAD = 1024 * 1024;

	/** The largest image published (base64 in one stanza: servers limit the size of stanzas, e.g. Prosody 256 KB) **/
	static inline var MAX_SET = 160 * 1024;

	final contacts:Contacts;
	final rooms:Rooms;

	/** The id of the PEP avatar of each contact (bare jid, lowercase), `""`: none **/
	final pep = new Map<String, String>();

	/** The hash of the vCard photo each contact announced last (bare jid, lowercase) **/
	final vcard = new Map<String, String>();

	/** Images being loaded (hashes), each once **/
	final loading = new Map<String, Bool>();

	public function new(context:Context, messages:Messages, contacts:Contacts, rooms:Rooms) {
		super(context);
		this.contacts = contacts;
		this.rooms = rooms;
		messages.incoming.push(i -> Messages.pep(i, UserAvatar.XMLNS_METADATA, metadata));
	}

	override public function commands():Array<Commands.Command>
		return [
			{
				name: "avatar",
				args: "[jid]",
				description: "save the avatar of a contact (or your own) in the cache and show the file",
				online: true,
				run: (args, out) -> show(args[0], out),
				subcommands: [
					{
						name: "set",
						requires: "pep",
						args: "<path...>",
						description: 'publish your avatar: an image (PNG recommended, at most ${Term.size(MAX_SET)}), for PEP and in your vCard',
						online: true,
						target: false,
						run: (args, out) -> set(args[0], out)
					},
					{
						name: "remove",
						requires: "pep",
						description: "remove your avatar (PEP and vCard)",
						online: true,
						target: false,
						run: (args, out) -> remove(out)
					}
				]
			}
		];

	override public function features():Array<String>
		return [UserAvatar.XMLNS_METADATA + "+notify"];

	override public function attach(stream:Stream) {
		super.attach(stream);
		final presence = stream.onPresence;
		stream.onPresence = p -> {
			announced(p);
			presence(p);
		}
	}

	override public function detach() {
		super.detach();
		loading.clear();
	}

	/** The cache directory of avatars **/
	static function dir():String
		return Config.cacheDir() + "/avatars";

	/** The cached image with hash `id`, `null` if not cached **/
	static function cached(id:String):Null<Avatar> {
		if (!~/^[0-9a-f]{40}$/.match(id))
			return null;
		for (ext in ["png", "jpg", "gif", "webp", "img"]) {
			final path = '${dir()}/$id.$ext';
			if (FileSystem.exists(path)) {
				final data = try File.getBytes(path) catch (_) null;
				if (data == null)
					return null;
				final info = Images.info(data);
				return {
					id: id,
					path: path,
					type: info?.type ?? "application/octet-stream",
					bytes: data.length,
					width: info?.width,
					height: info?.height
				};
			}
		}
		return null;
	}

	/** Saves an image in the cache (by its hash); `null` if it is too large or no image **/
	static function save(data:Bytes):Null<Avatar> {
		if (data.length > MAX_LOAD)
			return null;
		final info = Images.info(data);
		if (info == null)
			return null;
		final id = UserAvatar.hash(data);
		final existing = cached(id);
		if (existing != null)
			return existing;
		final path = '${dir()}/$id.${Images.extension(info.type)}';
		try {
			FileSystem.createDirectory(dir());
			// complete or not at all: other programs may read the cache
			File.saveBytes('$path.part', data);
			FileSystem.rename('$path.part', path);
		} catch (e) {
			Term.error('cannot save the avatar in ${dir()}: $e');
			return null;
		}
		return {
			id: id,
			path: path,
			type: info.type,
			bytes: data.length,
			width: info.width,
			height: info.height
		};
	}

	/** The avatar of `jid` (bare jid) changed: `null` none; the `avatar` event if it is another **/
	function changed(jid:String, avatar:Null<Avatar>, source:String) {
		final key = jid.toLowerCase();
		if (contacts.avatars.get(key) == avatar?.path)
			return;
		if (avatar == null)
			contacts.avatars.remove(key);
		else
			contacts.avatars.set(key, avatar.path);
		emit("avatar", [jid, avatar?.path ?? ""], {
			jid: jid,
			name: contacts.name(jid),
			path: avatar?.path,
			id: avatar?.id,
			type: avatar?.type,
			bytes: avatar?.bytes,
			width: avatar?.width,
			height: avatar?.height,
			source: source,
			own: isOwn(jid)
		});
	}

	/** The PEP avatar of a contact (or the own) changed: loads the image if it is not cached **/
	function metadata(from:String, payload:Null<XML>) {
		final infos = UserAvatar.parseMetadata(payload);
		final key = from.toLowerCase();
		// the image in the data node, PNG if listed
		final info = Lambda.find(infos, i -> i.url == null && i.type == "image/png") ?? Lambda.find(infos, i -> i.url == null);
		if (info == null) {
			pep.set(key, "");
			// a vCard photo of the contact, if any, is announced again with its presence
			changed(from, null, "pep");
			return;
		}
		pep.set(key, info.id);
		load(from, info.id, info.bytes, (id, done) -> UserAvatar.loadData(stream, from, id, res -> done(switch res {
			case Result(p): UserAvatar.parseData(p);
			case Error(_): null;
		})), avatar -> if (pep.get(key) == info.id) changed(from, avatar, "pep"));
	}

	/** The hash of a vCard photo in a presence of a contact (or the own): loads the vCard if the image is not cached **/
	function announced(p:Presence) {
		if (p.from == null || rooms.joined(p.from) || p.type == error)
			return;
		final hash = VCardAvatar.getPhotoHash(p);
		if (hash == null)
			return;
		final from = Jid.parseBare(p.from);
		final key = from.toLowerCase();
		if (vcard.get(key) == hash)
			return;
		vcard.set(key, hash);
		// a PEP avatar wins
		if ((pep.get(key) ?? "") != "")
			return;
		if (hash == "") {
			changed(from, null, "vcard");
			return;
		}
		load(from, hash, MAX_LOAD, (id, done) -> VCard.getVCard(stream, from, res -> done(switch res {
			case Result(p) if (p != null): VCard.parse(p).photo?.data;
			case _: null;
		})), avatar -> if (vcard.get(key) == hash && (pep.get(key) ?? "") == "") changed(from, avatar, "vcard"));
	}

	/**
		Gets the image with hash `id` of `jid`: from the cache, else with `request` (once at a time per image); `done`
		gets it, `null` if it couldn't be loaded, has another hash, or is too large.
	**/
	function load(jid:String, id:String, bytes:Int, request:(id:String, done:Null<Bytes>->Void)->Void, done:Null<Avatar>->Void) {
		final c = cached(id);
		if (c != null) {
			done(c);
			return;
		}
		if (bytes > MAX_LOAD || loading.exists(id))
			return;
		loading.set(id, true);
		request(id, data -> {
			loading.remove(id);
			done((data != null && UserAvatar.hash(data) == id) ? save(data) : null);
		});
	}

	/** `/avatar [jid]`: loads the current avatar (PEP, else the vCard photo) and shows the file **/
	function show(input:Null<String>, out:Output) {
		final jid = (input != null) ? contacts.resolve(input, out) : Jid.parseBare(stream.jid);
		if (jid == null)
			return;
		final bare = Jid.parseBare(jid);
		final done = out.wait();
		function result(avatar:Null<Avatar>, source:Null<String>) {
			if (avatar == null)
				out.info('${contacts.name(bare)} has no avatar');
			else {
				changed(bare, avatar, source);
				out.data({
					jid: bare,
					path: avatar.path,
					id: avatar.id,
					type: avatar.type,
					bytes: avatar.bytes,
					width: avatar.width,
					height: avatar.height,
					source: source
				}, () -> {
					// the image itself, in terminals showing images (PNG)
					if (avatar.type == "image/png")
						try Term.image(File.getBytes(avatar.path), IMAGE_ROWS) catch (_) false;
					out.info('${contacts.name(bare)}: ${avatar.path} (${describe(avatar)})');
				});
			}
			done();
		}
		function fromVCard() {
			VCard.getVCard(stream, isOwn(bare) ? null : bare, res -> {
				final data = switch res {
					case Result(p) if (p != null): VCard.parse(p).photo?.data;
					case _: null;
				}
				result((data != null) ? save(data) : null, "vcard");
			});
		}
		UserAvatar.loadMetadata(stream, isOwn(bare) ? null : bare, res -> {
			final infos = switch res {
				case Result(p): UserAvatar.parseMetadata(p);
				case Error(_): [];
			}
			final info = Lambda.find(infos, i -> i.url == null && i.type == "image/png") ?? Lambda.find(infos, i -> i.url == null);
			if (info == null) {
				fromVCard();
				return;
			}
			final c = cached(info.id);
			if (c != null) {
				result(c, "pep");
				return;
			}
			UserAvatar.loadData(stream, isOwn(bare) ? null : bare, info.id, res -> {
				final data = switch res {
					case Result(p): UserAvatar.parseData(p);
					case Error(_): null;
				}
				if (data == null || UserAvatar.hash(data) != info.id) {
					fromVCard();
					return;
				}
				result(save(data), "pep");
			});
		});
	}

	/** `image/png, 12 KB, 96×96` **/
	static function describe(a:Avatar):String
		return [a.type, Term.size(a.bytes), (a.width != null && a.height != null) ? '${a.width}×${a.height}' : null].filter(s -> s != null).join(", ");

	/** `/avatar set`: publishes the data, then the metadata (PEP), then the vCard photo **/
	function set(path:String, out:Output) {
		final file = Files.find(path, MAX_SET, out);
		if (file == null)
			return;
		final data = try File.getBytes(file.path) catch (e) {
			out.error('cannot read ${file.path}: $e');
			return;
		}
		final info = Images.info(data);
		if (info == null) {
			out.error('not an image (PNG, JPEG, GIF, WebP): ${file.path}');
			return;
		}
		final id = UserAvatar.hash(data);
		request(out, "cannot publish your avatar", handler -> UserAvatar.publishData(stream, data, handler), _ -> {
			final meta = {
				id: id,
				bytes: data.length,
				type: info.type,
				width: info.width,
				height: info.height
			};
			request(out, "cannot publish your avatar", handler -> UserAvatar.publishMetadata(stream, [meta], handler), _ -> {
				final avatar = save(data);
				if (avatar != null)
					changed(Jid.parseBare(stream.jid), avatar, "pep");
				setPhoto(XML.create("PHOTO").append(XML.create("TYPE", info.type)).append(XML.create("BINVAL", Base64.encode(data))), out,
					() -> out.info('avatar set: ${file.path} (${info.type}, ${Term.size(data.length)}'
						+ (info.width != null ? ', ${info.width}×${info.height}' : '') + ')'));
			});
		});
	}

	/** `/avatar remove`: empty metadata (PEP), no vCard photo **/
	function remove(out:Output) {
		request(out, "cannot remove your avatar", handler -> UserAvatar.publishMetadata(stream, null, handler), _ -> {
			changed(Jid.parseBare(stream.jid), null, "pep");
			setPhoto(null, out, () -> out.info("avatar removed"));
		});
	}

	/** Replaces the photo of the own vCard (`null`: removes it), keeping the other fields **/
	function setPhoto(photo:Null<XML>, out:Output, done:() -> Void) {
		request(out, "cannot read your vCard", handler -> VCard.getVCard(stream, null, res -> handler(VCard.isEmpty(res) ? Result(null) : res)),
			payload -> {
				final vcard = payload ?? XML.create("vCard").set("xmlns", VCard.XMLNS);
				final old = vcard.elements.findElement("PHOTO");
				if (old != null)
					(vcard : Xml).removeChild(old);
				if (photo != null)
					vcard.append(photo);
				request(out, "cannot save your vCard", handler -> VCard.setVCard(stream, vcard, handler), _ -> done());
			});
	}
}
