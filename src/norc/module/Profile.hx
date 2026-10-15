package norc.module;

import haxe.crypto.Base64;
import norc.Commands;
import norc.Module;
import norc.Output;
import norc.Term;
import norc.module.Messages;
import sys.io.File;
import xmpp.Jid;
import xmpp.Response;
import xmpp.VCard;
import xmpp.XML;
import xmpp.client.Nickname;

using StringTools;

/**
	User profiles: vCards (XEP-0054, `/vcard`) and nicknames (XEP-0172, `/nick`).
	Nicknames of contacts are received via PEP (`nickname` event) and used as their names if the roster has none.
**/
class Profile extends Module {
	/** Editable vCard fields: element, and child element for nested fields **/
	static final FIELDS:Map<String, Array<String>> = [
		"name" => ["FN"],
		"nickname" => ["NICKNAME"],
		"given" => ["N", "GIVEN"],
		"family" => ["N", "FAMILY"],
		"email" => ["EMAIL", "USERID"],
		"tel" => ["TEL", "NUMBER"],
		"url" => ["URL"],
		"birthday" => ["BDAY"],
		"org" => ["ORG", "ORGNAME"],
		"title" => ["TITLE"],
		"role" => ["ROLE"],
		"desc" => ["DESC"]
	];

	static final FIELD_NAMES = [
		"name",
		"nickname",
		"given",
		"family",
		"email",
		"tel",
		"url",
		"birthday",
		"org",
		"title",
		"role",
		"desc",
		"photo"
	];

	/** Largest photo (bytes) **/
	static inline var MAX_PHOTO = 256 * 1024;

	final contacts:Contacts;

	/** The own nickname, as last published **/
	var nickname:Null<String>;

	public function new(context:Context, messages:Messages, contacts:Contacts) {
		super(context);
		this.contacts = contacts;
		messages.incoming.push(i -> Messages.pep(i, Nickname.XMLNS, receive));
	}

	override public function commands():Array<Commands.Command>
		return [
			{
				name: "vcard",
				args: "[jid]",
				description: "show the vCard (profile) of a jid or contact, or your own",
				online: true,
				run: (args, out) -> show(args[0] != null ? contacts.jid(args[0]) : null, out),
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

	override public function features():Array<String>
		return [Nickname.XMLNS + "+notify"];

	/** Requests a vCard (`null`: the own one); the payload is `null` if there is none **/
	function vcard(jid:Null<String>, handler:Response<XML>->Void)
		VCard.getVCard(stream, jid, res -> handler(VCard.isEmpty(res) ? Result(null) : res));

	function show(jid:Null<String>, out:Output) {
		final target = jid ?? Jid.parseBare(stream.jid);
		request(out, target, handler -> vcard(jid, handler), payload -> {
			if (payload == null) {
				out.info('$target has no vCard');
				return;
			}
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
					line("photo", [photo.type, photo.size != null ? Term.size(photo.size) : null, photo.url].filter(s -> s != null).join(", "));
			});
		});
	}

	/** Sets a field of the own vCard (other fields are kept as they are), `null` clears it **/
	function set(field:String, value:Null<String>, out:Output) {
		if (!FIELD_NAMES.contains(field)) {
			out.error('unknown field: $field (${FIELD_NAMES.join(", ")})');
			return;
		}
		// the photo is read before anything changes
		final photo = (field == "photo" && value != null) ? readPhoto(value, out) : null;
		if (field == "photo" && value != null && photo == null)
			return;
		request(out, "cannot read your vCard", handler -> vcard(null, handler), payload -> {
			final vcard = payload ?? XML.create("vCard").set("xmlns", VCard.XMLNS);
			if (field == "photo") {
				remove(vcard, vcard.elements.findElement("PHOTO"));
				if (photo != null)
					vcard.append(photo);
			} else
				setField(vcard, FIELDS.get(field), value);
			request(out, "cannot save your vCard", handler -> VCard.setVCard(stream, vcard, handler),
				_ -> out.info('vCard: $field ' + (value != null ? 'set' : 'cleared')));
		});
	}

	/** The `PHOTO` element of the image at `path`, `null` with an error if it is none **/
	static function readPhoto(path:String, out:Output):Null<XML> {
		final file = Files.find(path, MAX_PHOTO, out);
		if (file == null)
			return null;
		final type = Files.type(file.path);
		if (type == null || !type.startsWith("image/")) {
			out.error('not an image: ${file.path}');
			return null;
		}
		return XML.create("PHOTO").append(XML.create("TYPE", type)).append(XML.create("BINVAL", Base64.encode(File.getBytes(file.path))));
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
		request(out, "cannot publish the nickname", handler -> Nickname.publishNickname(stream, nick, handler), _ -> {
			nickname = nick;
			out.info('nickname: ${nick ?? "-"}');
		});
	}

	/** Nicknames published by contacts (and the own one) **/
	function receive(from:String, payload:Null<XML>) {
		final nick = (payload == null) ? null : Nickname.parseNickname(payload);
		if (isOwn(from)) {
			nickname = nick;
			return;
		}
		final previous = contacts.nicknames.get(from);
		if (!change(contacts.nicknames, from, nick))
			return;
		if (previous != null)
			Term.notice('$previous is now known as ${nick ?? from}');
		emit("nickname", [from, nick ?? ""], {from: from, name: contacts.name(from), nickname: nick});
	}
}
