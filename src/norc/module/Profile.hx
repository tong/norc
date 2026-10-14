package norc.module;

import haxe.crypto.Base64;
import haxe.io.Path;
import norc.Commands;
import norc.Config;
import norc.Module;
import norc.Output;
import norc.Term;
import norc.module.Messages;
import sys.FileSystem;
import sys.io.File;
import xmpp.Jid;
import xmpp.PubSub;
import xmpp.Response;
import xmpp.VCard;
import xmpp.XML;
import xmpp.client.Nickname;
import xmpp.client.Stream;

using StringTools;

/**
	User profiles: vCards (XEP-0054, `/vcard`) and nicknames (XEP-0172, `/nick`).
	Nicknames of contacts are received via PEP (`nickname` event) and used as their names if the roster has none.
**/
class Profile implements Module {
	/** Editable vCard fields: element, and child element for nested fields **/
	static final FIELDS:Map<String, Array<String>> = [
		"name" => ["FN"], "nickname" => ["NICKNAME"], "given" => ["N", "GIVEN"], "family" => ["N", "FAMILY"],
		"email" => ["EMAIL", "USERID"], "tel" => ["TEL", "NUMBER"], "url" => ["URL"], "birthday" => ["BDAY"],
		"org" => ["ORG", "ORGNAME"], "title" => ["TITLE"], "role" => ["ROLE"], "desc" => ["DESC"]
	];

	static final FIELD_NAMES = ["name", "nickname", "given", "family", "email", "tel", "url", "birthday", "org", "title", "role", "desc", "photo"];

	/** Largest photo (bytes) **/
	static inline var MAX_PHOTO = 256 * 1024;

	static final PHOTO_TYPES = ["png" => "image/png", "jpg" => "image/jpeg", "jpeg" => "image/jpeg", "gif" => "image/gif", "webp" => "image/webp"];

	final emit:Emit;

	/** A contact name to its jid, other input unchanged **/
	final resolve:String->String;

	/** The name of a contact (bare jid), or the jid **/
	final name:String->String;

	/** Nicknames of contacts by bare jid, used as names **/
	final nicknames:Map<String, String>;

	var stream:Null<Stream>;

	/** The own nickname, as last published **/
	var nickname:Null<String>;

	public function new(messages:Messages, emit:Emit, resolve:String->String, name:String->String, nicknames:Map<String, String>) {
		this.emit = emit;
		this.resolve = resolve;
		this.name = name;
		this.nicknames = nicknames;
		messages.incoming.push(receive);
	}

	public function commands():Array<Commands.Command>
		return [
			{
				name: "vcard",
				args: "[jid]",
				description: "show the vCard (profile) of a jid or contact, or your own",
				online: true,
				run: (args, out) -> show(args[0] != null ? resolve(args[0]) : null, out),
				subcommands: [
					{
						name: "set",
						args: "<field> [value...]",
						description: 'set a field of your vCard, without value: clear it; fields: ${FIELD_NAMES.join(", ")} (photo: path of an image)',
						online: true,
						run: (args, out) -> set(args[0], args[1], out),
						complete: ["field" => _ -> FIELD_NAMES]
					}
				]
			},
			{
				name: "nick",
				args: "[name...]",
				description: "show or publish your nickname (- stops publishing it)",
				online: true,
				run: (args, out) -> nick(args[0], out)
			}
		];

	public function features():Array<String>
		return [Nickname.XMLNS + "+notify"];

	public function attach(stream:Stream)
		this.stream = stream;

	public function online() {}

	public function detach()
		stream = null;

	function show(jid:Null<String>, out:Output) {
		final target = jid ?? Jid.parseBare(stream.jid);
		final done = out.wait();
		VCard.getVCard(stream, jid, res -> {
			if (VCard.isEmpty(res)) {
				out.info('$target has no vCard');
				return done();
			}
			switch res {
				case Result(payload):
					final v = VCard.parse(payload);
					final org = [v.orgName, v.orgUnit].filter(s -> s != null && s.length > 0).join(", ");
					final photo = (v.photo == null) ? null : {type: v.photo.type, size: v.photo.data?.length, url: v.photo.url};
					final data = {
						jid: target,
						name: v.fn,
						nickname: v.nickname,
						given: v.given,
						family: v.family,
						birthday: v.bday,
						email: [for (e in v.email ?? []) e.userid],
						tel: [for (t in v.tel ?? []) t.number],
						url: v.url,
						org: (org.length > 0) ? org : null,
						title: v.title,
						role: v.role,
						desc: v.desc,
						photo: photo
					};
					out.data(data, () -> {
						out.print(target);
						function line(label:String, value:Null<String>)
							if (value != null && value.length > 0)
								out.print('  ${label.rpad(" ", 10)}${value.replace("\n", "\n            ")}');
						line("name", v.fn);
						line("nickname", v.nickname);
						line("given", v.given);
						line("family", v.family);
						line("birthday", v.bday);
						for (e in data.email)
							line("email", e);
						for (t in data.tel)
							line("tel", t);
						line("url", v.url);
						line("org", data.org);
						line("title", v.title);
						line("role", v.role);
						line("desc", v.desc);
						if (photo != null)
							line("photo", [photo.type, photo.size != null ? FileTransfers.formatSize(photo.size) : null, photo.url].filter(s -> s != null).join(", "));
					});
				case Error(e):
					out.error('$target: ${e.condition}' + (e.text != null ? ': ${e.text}' : ''));
			}
			done();
		});
	}

	/** Sets a field of the own vCard (other fields are kept as they are), `null` clears it **/
	function set(field:String, value:Null<String>, out:Output) {
		if (!FIELD_NAMES.contains(field)) {
			out.error('unknown field: $field (${FIELD_NAMES.join(", ")})');
			return;
		}
		// read the photo before changing anything
		final photo = if (field == "photo" && value != null) {
			final path = Config.expandHome(value);
			final type = PHOTO_TYPES.get((Path.extension(path) ?? "").toLowerCase());
			if (type == null || !FileSystem.exists(path)) {
				out.error(type == null ? 'not an image (png, jpeg, gif, webp): $path' : 'no such file: $path');
				return;
			}
			if (FileSystem.stat(path).size > MAX_PHOTO) {
				out.error('photo too large (max ${FileTransfers.formatSize(MAX_PHOTO)})');
				return;
			}
			{type: type, data: Base64.encode(File.getBytes(path))};
		} else null;
		final done = out.wait();
		VCard.getVCard(stream, null, res -> {
			final vcard:XML = switch res {
				case Result(payload) if (payload != null): payload;
				case _ if (VCard.isEmpty(res)): XML.create("vCard").set("xmlns", VCard.XMLNS);
				case Error(e):
					out.error('cannot read your vCard: ${e.condition}');
					return done();
				case _: XML.create("vCard").set("xmlns", VCard.XMLNS);
			}
			if (field == "photo") {
				remove(vcard, vcard.elements.findElement("PHOTO"));
				if (photo != null)
					vcard.append(XML.create("PHOTO").append(XML.create("TYPE", photo.type)).append(XML.create("BINVAL", photo.data)));
			} else
				setField(vcard, FIELDS.get(field), value);
			VCard.setVCard(stream, vcard, res -> {
				switch res {
					case Result(_): out.info((value != null) ? 'vCard: $field set' : 'vCard: $field cleared');
					case Error(e): out.error('cannot save your vCard: ${e.condition}' + (e.text != null ? ': ${e.text}' : ''));
				}
				done();
			});
		});
	}

	static function setField(vcard:XML, path:Array<String>, value:Null<String>) {
		var top = vcard.elements.findElement(path[0]);
		if (path.length == 1) {
			remove(vcard, top);
			if (value != null)
				vcard.append(XML.create(path[0], value));
			return;
		}
		if (top == null) {
			if (value == null)
				return;
			top = XML.create(path[0]);
			vcard.append(top);
		}
		remove(top, top.elements.findElement(path[1]));
		if (value != null)
			top.append(XML.create(path[1], value));
		else if ([for (e in top.elements) if (e.text != null) e].length == 0)
			// only type markers left (e.g. INTERNET of an email)
			remove(vcard, top);
	}

	static function remove(parent:XML, e:Null<XML>)
		if (e != null)
			(parent : Xml).removeChild(e);

	function nick(value:Null<String>, out:Output) {
		if (value == null) {
			out.data({nickname: nickname}, () -> out.info('nickname: ${nickname ?? "-"}'));
			return;
		}
		final nick = (value == "-") ? null : value;
		final done = out.wait();
		Nickname.publishNickname(stream, nick, res -> {
			switch res {
				case Result(_):
					nickname = nick;
					out.info('nickname: ${nick ?? "-"}');
				case Error(e):
					out.error('cannot publish the nickname: ${e.condition}');
			}
			done();
		});
	}

	/** Nicknames published by contacts (and the own one) **/
	function receive(i:Incoming):Bool {
		final m = i.message;
		if (m.from == null)
			return false;
		final event = PubSub.getEvent(m);
		if (event == null)
			return false;
		switch event {
			case Items(node, items, _) if (node == Nickname.XMLNS):
				final from = Jid.parseBare(m.from);
				for (item in items) {
					final e = item.firstElement;
					final nick = (e == null) ? null : Nickname.parseNickname(e);
					if (stream != null && stream.jid != null && from == Jid.parseBare(stream.jid)) {
						nickname = nick;
						continue;
					}
					final previous = nicknames.get(from);
					if (previous == nick)
						continue;
					if (nick == null)
						nicknames.remove(from);
					else
						nicknames.set(from, nick);
					if (previous != null)
						Term.println(Term.timestamp(Date.now()) + ' ' + Term.style('$previous is now known as ${nick ?? from}', 2));
					emit("nickname", [from, nick ?? ""], {from: from, name: name(from), nickname: nick});
				}
				return true;
			case _:
				return false;
		}
	}
}
